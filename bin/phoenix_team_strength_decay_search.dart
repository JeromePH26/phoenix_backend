import 'dart:convert';
import 'dart:io';

import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/engine_replica.dart';
import 'package:phoenix_backend/src/model_lab/learning_dataset_builder.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/metrics.dart';
import 'package:phoenix_backend/src/model_lab/team_strength_engine.dart';

/// PHÖNIX Engine-Umbau, Phase 3 (Plan "wild-cuddling-hoare"): findet die
/// empirisch beste Zeitverfall-Halbwertszeit für `TeamStrengthEngine.fit`
/// auf echten, bereits abgerechneten PHÖNIX-Ligen - statt eine Halbwertszeit
/// zu raten. Vergleicht "kein Zeitverfall" (Kontrollwert, identisch zum
/// Phase-2-Backtest) gegen ein Gitter von Halbwertszeiten.
///
/// Gleiches Aufbau-/Sicherheits-Muster wie
/// `phoenix_team_strength_backtest.dart`/`phoenix_dixon_coles_rho_search.
/// dart`: nur lesende DB-Zugriffe, zeitliche Trennung Training/Holdout
/// (config.holdoutFraction, keine Zukunftsdaten im Training).
Future<void> main() async {
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  if (databaseUrl.isEmpty) {
    stderr.writeln('DATABASE_URL/DATABASE_PUBLIC_URL fehlt.');
    exitCode = 1;
    return;
  }

  final database = PhoenixDatabase(databaseUrl);
  final config = ModelLabConfig.fromEnvironment();

  const minimumTrainingMatches = 25;
  const minimumHoldoutMatches = 5;

  // `null` = kein Zeitverfall (Kontrollwert). Gitter deckt "kurzes
  // Gedächtnis" (30 Tage) bis "fast kein Verfall über die verfügbare
  // Historie" (400 Tage, siehe auch footballLeagueGoalContext's 400-Tage-
  // Fenster an anderer Stelle) ab.
  const halfLifeCandidates = <double?>[null, 30, 60, 120, 240, 400];

  try {
    stdout.writeln(
        '== Migration (additiv, identisch zum produktiven Boot-Pfad) ==');
    await database.migrate();
    stdout.writeln('OK\n');

    final datasetBuilder =
        LearningDatasetBuilder(database: database, config: config);
    final leagues = await database.modelLabWhitelistedLeagues();

    final audit = await datasetBuilder.auditEligibility();
    final eligibleLeagueIds = audit.perLeague
        .where((c) => c.settled >= minimumTrainingMatches)
        .map((c) => c.leagueId)
        .toSet();
    final leaguesToCheck = leagues
        .where((l) => eligibleLeagueIds.contains(l['league_id']?.toString()))
        .toList();
    stdout.writeln(
        '${leaguesToCheck.length} von ${leagues.length} Whitelist-Ligen haben '
        'mindestens $minimumTrainingMatches abgerechnete Spiele - nur diese '
        'werden geladen.\n');

    final aggregates = {
      for (final h in halfLifeCandidates) h: _AggregateScore(),
    };
    var leaguesUsed = 0;
    var totalHoldoutMatches = 0;

    for (final league in leaguesToCheck) {
      final leagueId = league['league_id']?.toString();
      if (leagueId == null) continue;

      final rawMatches =
          await database.footballSettledMatchesForLeague(leagueId: leagueId);
      if (rawMatches.length < minimumTrainingMatches) continue;

      final holdoutCount =
          (rawMatches.length * config.holdoutFraction).ceil().clamp(0, rawMatches.length);
      final training = rawMatches.sublist(0, rawMatches.length - holdoutCount);
      final holdout = rawMatches.sublist(rawMatches.length - holdoutCount);
      if (training.length < minimumTrainingMatches ||
          holdout.length < minimumHoldoutMatches) {
        continue;
      }

      stdout.writeln('-> ${league['league_name']} ($leagueId): '
          '${training.length} Training, ${holdout.length} Holdout');

      final matchResults = training
          .map((row) => MatchResult(
                homeTeamId: row['home_team_id']?.toString() ?? '',
                awayTeamId: row['away_team_id']?.toString() ?? '',
                homeGoals: _int(row['home_goals']),
                awayGoals: _int(row['away_goals']),
                kickoff: row['kickoff_utc'] is DateTime
                    ? row['kickoff_utc'] as DateTime
                    : null,
              ))
          .where((m) => m.homeTeamId.isNotEmpty && m.awayTeamId.isNotEmpty)
          .toList();

      // "Heute" für den Zeitverfall ist der Beginn des Holdout-Zeitraums,
      // nicht das echte Jetzt - konsistent mit der Leakage-sicheren
      // Trainings-/Holdout-Trennung.
      final asOf = holdout.first['kickoff_utc'] is DateTime
          ? holdout.first['kickoff_utc'] as DateTime
          : DateTime.now();

      var usedThisLeague = false;
      for (final halfLife in halfLifeCandidates) {
        final fit = TeamStrengthEngine.fit(
          matchResults,
          halfLifeDays: halfLife,
          asOf: asOf,
        );
        if (!fit.converged) continue;

        for (final row in holdout) {
          final homeTeamId = row['home_team_id']?.toString() ?? '';
          final awayTeamId = row['away_team_id']?.toString() ?? '';
          final homeGoals = _int(row['home_goals']);
          final awayGoals = _int(row['away_goals']);
          if (homeTeamId.isEmpty || awayTeamId.isEmpty) continue;

          final goals = TeamStrengthEngine.expectedGoals(
            fit: fit,
            homeTeamId: homeTeamId,
            awayTeamId: awayTeamId,
          );
          final outcomeIndex =
              homeGoals > awayGoals ? 0 : (homeGoals == awayGoals ? 1 : 2);
          final output = EngineReplica.evaluateGoals(
            market: LearningMarket.oneXTwo,
            goals: (home: goals.home, away: goals.away, usedFallback: false),
          );
          final score = Metrics.brierMultiClass(
            probabilities: output.classProbabilities,
            outcomeIndex: outcomeIndex,
          );
          aggregates[halfLife]!.add(score);
          if (halfLife == null) {
            usedThisLeague = true;
            totalHoldoutMatches += 1;
          }
        }
      }
      if (usedThisLeague) leaguesUsed += 1;
    }

    stdout.writeln('\n== ERGEBNIS (Markt: 1X2) ==');
    stdout.writeln('Ligen mit vergleichbaren Holdout-Spielen: $leaguesUsed');
    stdout.writeln('Holdout-Spiele gesamt: $totalHoldoutMatches\n');

    if (totalHoldoutMatches == 0) {
      stdout.writeln('KEINE vergleichbaren Fälle gefunden.');
      return;
    }

    final ranked = halfLifeCandidates.toList()
      ..sort((a, b) => aggregates[a]!.average.compareTo(aggregates[b]!.average));

    stdout.writeln('Halbwertszeit | Ø Brier | Holdout-Spiele bewertet');
    for (final h in ranked) {
      final label = h == null ? 'kein Verfall' : '$h Tage'.padLeft(12);
      stdout.writeln(
        '$label | ${aggregates[h]!.average.toStringAsFixed(5)} | ${aggregates[h]!.count}',
      );
    }

    final best = ranked.first;
    final control = aggregates[null]!.average;
    stdout.writeln(
      best == null
          ? '\n=> Kein Zeitverfall ist selbst am besten - auf diesen Daten '
              'kein Hinweis auf einen Nutzen der Zeitverfall-Gewichtung.'
          : '\n=> Empfehlung: Halbwertszeit ${best.toStringAsFixed(0)} Tage '
              '(Ø Brier ${aggregates[best]!.average.toStringAsFixed(6)} vs. '
              '${control.toStringAsFixed(6)} ohne Verfall, Differenz '
              '${(aggregates[best]!.average - control).toStringAsFixed(6)}).',
    );

    stdout.writeln('\n== ROH-JSON ==');
    stdout.writeln(jsonEncode({
      for (final h in halfLifeCandidates)
        (h == null ? 'none' : h.toStringAsFixed(0)): {
          'averageBrier': aggregates[h]!.average,
          'count': aggregates[h]!.count,
        },
    }));
  } finally {
    await database.close();
  }
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

class _AggregateScore {
  int count = 0;
  double _sum = 0.0;

  void add(double value) {
    count += 1;
    _sum += value;
  }

  double get average => count == 0 ? 0.0 : _sum / count;
}
