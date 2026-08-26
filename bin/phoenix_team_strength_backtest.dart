import 'dart:convert';
import 'dart:io';

import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/engine_replica.dart';
import 'package:phoenix_backend/src/model_lab/learning_dataset_builder.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/metrics.dart';
import 'package:phoenix_backend/src/model_lab/team_strength_engine.dart';

/// PHÖNIX Engine-Umbau, Phase 2 (Plan "wild-cuddling-hoare"): testet, ob
/// IPF-gefittete Team-Stärke-Ratings (`TeamStrengthEngine`) bessere
/// Torerwartungen liefern als die heutige "einfacher Durchschnitt der
/// letzten Spiele"-Methode (`football_engine_input_service.dart`) - auf
/// echten, bereits abgerechneten PHÖNIX-Ligen.
///
/// Bewusst UNABHÄNGIG von `LearningSample`/Phase-2-Snapshots: beide
/// verglichenen Modelle werden hier direkt aus denselben rohen
/// abgerechneten Ergebnissen (`database.footballSettledMatchesForLeague`)
/// berechnet - "einfacher Durchschnitt" und "IPF-Fit" bekommen exakt
/// dieselben Trainingsdaten, nur unterschiedlich verarbeitet. Das ist ein
/// fairer, direkter Vergleich der beiden Methoden selbst, unabhängig von
/// der Phase-2-Snapshot-Abdeckungslücke, die Phase 1 Spur B's Backtest auf
/// wenige hundert Spiele beschränkt hat.
///
/// Zeitliche Aufteilung: die letzten [holdoutFraction] Spiele jeder Liga
/// (chronologisch) sind Holdout, der Rest ist Training - keine
/// Zukunftsdaten fließen in die Trainingsseite ein.
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

  // Live gegen PHÖNIX-Daten getestet: bei 40 hatten nur 4 von 1233 Ligen
  // genug Historie. 25 ist ein bewusster Kompromiss - noch genug Spiele für
  // ein paar Iterationen des Fits, aber deutlich mehr Ligen im Sample.
  const minimumTrainingMatches = 25;
  const minimumHoldoutMatches = 5;

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

    final averageAggregate = _AggregateScore();
    final strengthAggregate = _AggregateScore();
    var leaguesUsed = 0;
    var totalHoldoutMatches = 0;
    final perLeagueReport = <Map<String, Object?>>[];

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
              ))
          .where((m) => m.homeTeamId.isNotEmpty && m.awayTeamId.isNotEmpty)
          .toList();

      final fit = TeamStrengthEngine.fit(matchResults);
      final teamAverages = _TeamAverages.fromMatches(matchResults);

      var leagueSampleCount = 0;
      final leagueAverageForLeague = _AggregateScore();
      final leagueStrengthForLeague = _AggregateScore();

      for (final row in holdout) {
        final homeTeamId = row['home_team_id']?.toString() ?? '';
        final awayTeamId = row['away_team_id']?.toString() ?? '';
        final homeGoals = _int(row['home_goals']);
        final awayGoals = _int(row['away_goals']);
        if (homeTeamId.isEmpty || awayTeamId.isEmpty) continue;

        final averageGoals = teamAverages.expectedGoals(
          homeTeamId: homeTeamId,
          awayTeamId: awayTeamId,
        );
        final strengthGoals = TeamStrengthEngine.expectedGoals(
          fit: fit,
          homeTeamId: homeTeamId,
          awayTeamId: awayTeamId,
        );

        final outcomeIndex =
            homeGoals > awayGoals ? 0 : (homeGoals == awayGoals ? 1 : 2);

        final averageOutput = EngineReplica.evaluateGoals(
          market: LearningMarket.oneXTwo,
          goals: (home: averageGoals.home, away: averageGoals.away, usedFallback: false),
        );
        final strengthOutput = EngineReplica.evaluateGoals(
          market: LearningMarket.oneXTwo,
          goals: (home: strengthGoals.home, away: strengthGoals.away, usedFallback: false),
        );

        final averageScore = Metrics.brierMultiClass(
          probabilities: averageOutput.classProbabilities,
          outcomeIndex: outcomeIndex,
        );
        final strengthScore = Metrics.brierMultiClass(
          probabilities: strengthOutput.classProbabilities,
          outcomeIndex: outcomeIndex,
        );

        averageAggregate.add(averageScore);
        strengthAggregate.add(strengthScore);
        leagueAverageForLeague.add(averageScore);
        leagueStrengthForLeague.add(strengthScore);
        leagueSampleCount += 1;
        totalHoldoutMatches += 1;
      }

      if (leagueSampleCount > 0) {
        leaguesUsed += 1;
        perLeagueReport.add({
          'leagueId': leagueId,
          'leagueName': league['league_name'],
          'holdoutMatches': leagueSampleCount,
          'fitConverged': fit.converged,
          'fitIterations': fit.iterations,
          'averageBaselineBrier': leagueAverageForLeague.average,
          'teamStrengthBrier': leagueStrengthForLeague.average,
          'brierDelta':
              leagueStrengthForLeague.average - leagueAverageForLeague.average,
        });
      }
    }

    stdout.writeln('\n== ERGEBNIS (Markt: 1X2) ==');
    stdout.writeln('Ligen mit vergleichbaren Holdout-Spielen: $leaguesUsed');
    stdout.writeln('Holdout-Spiele gesamt: $totalHoldoutMatches\n');

    if (totalHoldoutMatches == 0) {
      stdout.writeln('KEINE vergleichbaren Fälle gefunden.');
      return;
    }

    stdout.writeln('Einfacher Durchschnitt (heutige Methode) - Ø Brier: '
        '${averageAggregate.average.toStringAsFixed(5)}');
    stdout.writeln('IPF-Team-Stärke (neu)                    - Ø Brier: '
        '${strengthAggregate.average.toStringAsFixed(5)}');

    final delta = strengthAggregate.average - averageAggregate.average;
    stdout.writeln('\nDelta (negativ = Team-Stärke besser): '
        '${delta.toStringAsFixed(5)}');
    stdout.writeln(
      delta < 0
          ? '\n=> Team-Stärke-Ratings sind auf diesen Daten BESSER als der '
              'einfache Durchschnitt.'
          : '\n=> Team-Stärke-Ratings sind auf diesen Daten NICHT besser - '
              'kein Beleg für einen Umstieg.',
    );

    stdout.writeln('\n== PRO LIGA (sortiert: größter Vorteil zuerst) ==');
    perLeagueReport.sort(
        (a, b) => (a['brierDelta'] as double).compareTo(b['brierDelta'] as double));
    for (final entry in perLeagueReport) {
      stdout.writeln(jsonEncode(entry));
    }
  } finally {
    await database.close();
  }
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

/// Reproduziert den Kern der heutigen produktiven Formel
/// (`football_engine_input_service.dart._normalize`, ohne die Sample-Size-
/// und Liga-Baseline-Glättung - reiner Rohdurchschnitt, derselbe
/// Ausgangspunkt, den auch die produktive Formel glättet) - fair
/// vergleichbar, weil aus denselben Trainingsdaten wie der Team-Stärke-Fit
/// berechnet.
class _TeamAverages {
  _TeamAverages();

  final Map<String, double> _homeFor = {};
  final Map<String, double> _homeAgainst = {};
  final Map<String, double> _awayFor = {};
  final Map<String, double> _awayAgainst = {};
  double _leagueAverageHome = 1.35;
  double _leagueAverageAway = 1.10;

  static _TeamAverages fromMatches(List<MatchResult> matches) {
    final result = _TeamAverages();
    final homeForSum = <String, double>{};
    final homeForCount = <String, int>{};
    final homeAgainstSum = <String, double>{};
    final awayForSum = <String, double>{};
    final awayForCount = <String, int>{};
    final awayAgainstSum = <String, double>{};
    var totalHome = 0.0;
    var totalAway = 0.0;

    for (final match in matches) {
      homeForSum[match.homeTeamId] =
          (homeForSum[match.homeTeamId] ?? 0) + match.homeGoals;
      homeForCount[match.homeTeamId] = (homeForCount[match.homeTeamId] ?? 0) + 1;
      homeAgainstSum[match.homeTeamId] =
          (homeAgainstSum[match.homeTeamId] ?? 0) + match.awayGoals;

      awayForSum[match.awayTeamId] =
          (awayForSum[match.awayTeamId] ?? 0) + match.awayGoals;
      awayForCount[match.awayTeamId] = (awayForCount[match.awayTeamId] ?? 0) + 1;
      awayAgainstSum[match.awayTeamId] =
          (awayAgainstSum[match.awayTeamId] ?? 0) + match.homeGoals;

      totalHome += match.homeGoals;
      totalAway += match.awayGoals;
    }

    for (final id in homeForSum.keys) {
      final count = homeForCount[id]!;
      result._homeFor[id] = homeForSum[id]! / count;
      result._homeAgainst[id] = homeAgainstSum[id]! / count;
    }
    for (final id in awayForSum.keys) {
      final count = awayForCount[id]!;
      result._awayFor[id] = awayForSum[id]! / count;
      result._awayAgainst[id] = awayAgainstSum[id]! / count;
    }
    if (matches.isNotEmpty) {
      result._leagueAverageHome = totalHome / matches.length;
      result._leagueAverageAway = totalAway / matches.length;
    }
    return result;
  }

  double? _average(double? a, double? b) {
    if (a == null && b == null) return null;
    if (a == null) return b;
    if (b == null) return a;
    return (a + b) / 2;
  }

  ({double home, double away}) expectedGoals({
    required String homeTeamId,
    required String awayTeamId,
  }) {
    final home = _average(_homeFor[homeTeamId], _awayAgainst[awayTeamId]) ??
        _leagueAverageHome;
    final away = _average(_awayFor[awayTeamId], _homeAgainst[homeTeamId]) ??
        _leagueAverageAway;
    return (home: home, away: away);
  }
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
