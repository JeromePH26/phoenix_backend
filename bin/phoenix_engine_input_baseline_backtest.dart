import 'dart:convert';
import 'dart:io';

import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/engine_replica.dart';
import 'package:phoenix_backend/src/model_lab/learning_dataset_builder.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/metrics.dart';
import 'package:phoenix_backend/src/model_lab/walk_forward_evaluator.dart';
import 'package:phoenix_backend/src/services/football_engine_input_service.dart';

/// Sicherheits-Gate für PHÖNIX Engine-Umbau Phase 1 Spur B (Plan
/// "wild-cuddling-hoare"): vergleicht auf historischen, bereits
/// abgerechneten Spielen die aktuelle, feste globale Torerwartungs-Baseline
/// (1.35 Heim / 1.10 Auswärts) gegen die neue liga-bewusste Baseline
/// (`FootballEngineInputService.leagueAwareBaseline`) - BEVOR Letztere live
/// geschaltet wird. Nur lesende DB-Zugriffe (identisch zu
/// `phoenix_model_lab_dry_run.dart`), keine Schreiboperation außer dem
/// additiven `database.migrate()`.
///
/// WICHTIGE, bewusste Vereinfachung: `LearningSample`s whitelisted Features
/// (`FeatureWhitelist`) enthalten keine Spielanzahlen (`homePlayed`/
/// `awayPlayed`), nur die vier rohen Torquoten - die exakte Team-Ebene-
/// Stichprobengröße (v12, bereits live verifiziert) kann dieser Backtest
/// deshalb nicht rekonstruieren. Er isoliert stattdessen genau die eine
/// Variable, die Spur B ändert - fester globaler Wert vs. liga-eigener Wert
/// als GLÄTTUNGSZIEL - und wendet dieselbe Shrinkage-Formel wie Produktion
/// (`shrinkGoalRateTowardsBaseline`) mit einer repräsentativen, aus dem
/// Code selbst stammenden Team-Stichprobengröße
/// (`sampleSizeShrinkageK`, "Halbwertspunkt") auf JEDES Holdout-Sample mit
/// leakage-sicherem Liga-Kontext an - nicht nur auf die seltenen Fälle mit
/// komplett fehlender Team-Torquote (erste Version dieses Skripts fand so
/// nur 2 vergleichbare Fälle in 89 Ligen - statistisch bedeutungslos).
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

  try {
    stdout.writeln(
        '== Migration (additiv, identisch zum produktiven Boot-Pfad) ==');
    await database.migrate();
    stdout.writeln('OK\n');

    final datasetBuilder =
        LearningDatasetBuilder(database: database, config: config);
    final leagues = await database.modelLabWhitelistedLeagues();

    // Section 89-Muster (wie phoenix_model_lab_dry_run.dart): die Whitelist
    // hat 1200+ Einträge, die meisten davon `data_pool`-Ligen mit faktisch 0
    // eigenen Spielen - eine Abfrage pro Liga für alle davon wäre bei über
    // die öffentliche Railway-Proxy-Verbindung schon allein durch die
    // schiere Anzahl unnötig langsam. `auditEligibility()` liefert die
    // Zählung in EINER Abfrage vorab; nur Ligen mit tatsächlich
    // abgerechneten Spielen werden einzeln geladen.
    final audit = await datasetBuilder.auditEligibility();
    final eligibleLeagueIds = audit.perLeague
        .where((c) => c.settled > 0)
        .map((c) => c.leagueId)
        .toSet();
    final leaguesToCheck =
        leagues.where((l) => eligibleLeagueIds.contains(l['league_id']?.toString())).toList();
    stdout.writeln(
        '${leaguesToCheck.length} von ${leagues.length} Whitelist-Ligen haben '
        'abgerechnete Spiele - nur diese werden geladen.\n');

    final fixedAggregate = _AggregateScore();
    final leagueAwareAggregate = _AggregateScore();
    var leaguesWithComparableHoldout = 0;
    final perLeagueReport = <Map<String, Object?>>[];

    for (final league in leaguesToCheck) {
      final leagueId = league['league_id']?.toString();
      if (leagueId == null) continue;
      stdout.writeln('-> ${league['league_name']} ($leagueId)');

      final samples = await datasetBuilder.buildSamples(leagueId: leagueId);
      if (samples.isEmpty) continue;

      final split = ChronologicalSplit.split(samples, config);
      if (split.holdout.isEmpty) continue;

      final fixedForLeague = _AggregateScore();
      final leagueAwareForLeague = _AggregateScore();

      for (final sample in split.holdout) {
        // Einzige Voraussetzung: ein leakage-sicherer Liga-Kontext ist für
        // dieses historische Sample vorhanden (`hasGlobalMarketData`, siehe
        // learning_sample.dart) - ohne den sind fixed/liga-bewusst per
        // Definition identisch und liefern keine Information.
        if (!sample.hasGlobalMarketData) continue;
        final leagueAvgHome = sample.globalMarketLeagueAvgHomeGoals;
        final leagueAvgAway = sample.globalMarketLeagueAvgAwayGoals;
        if (leagueAvgHome == null || leagueAvgAway == null) continue;

        final homeFor = _num(sample.features['raw.homeGoalsForAverageHome']);
        final homeAgainst =
            _num(sample.features['raw.homeGoalsAgainstAverageHome']);
        final awayFor = _num(sample.features['raw.awayGoalsForAverageAway']);
        final awayAgainst =
            _num(sample.features['raw.awayGoalsAgainstAverageAway']);
        final calculatedHome = _averageAvailable(homeFor, awayAgainst);
        final calculatedAway = _averageAvailable(awayFor, homeAgainst);

        // Repräsentative Team-Stichprobengröße (siehe Doc-Kommentar oben) -
        // dieselbe echte Produktionsformel, angewendet auf JEDES Sample mit
        // Liga-Kontext, nicht nur die seltenen komplett-fehlend-Fälle.
        const assumedTeamSampleSize =
            FootballEngineInputService.sampleSizeShrinkageK;
        const assumedLeagueSampleSize =
            FootballEngineInputService.leagueBaselineShrinkageK;

        final fixedHome = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
          calculatedHome ?? 1.35,
          baseline: 1.35,
          sampleSize: assumedTeamSampleSize,
        );
        final fixedAway = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
          calculatedAway ?? 1.10,
          baseline: 1.10,
          sampleSize: assumedTeamSampleSize,
        );

        final leagueBaselineHome = FootballEngineInputService.leagueAwareBaseline(
          globalBaseline: 1.35,
          leagueAvg: leagueAvgHome,
          leagueContextSampleSize: assumedLeagueSampleSize,
        );
        final leagueBaselineAway = FootballEngineInputService.leagueAwareBaseline(
          globalBaseline: 1.10,
          leagueAvg: leagueAvgAway,
          leagueContextSampleSize: assumedLeagueSampleSize,
        );
        final leagueAwareHome = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
          calculatedHome ?? leagueBaselineHome,
          baseline: leagueBaselineHome,
          sampleSize: assumedTeamSampleSize,
        );
        final leagueAwareAway = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
          calculatedAway ?? leagueBaselineAway,
          baseline: leagueBaselineAway,
          sampleSize: assumedTeamSampleSize,
        );

        final outcomeIndex = sample.outcomeIndexFor(LearningMarket.oneXTwo);

        final fixedOutput = EngineReplica.evaluateGoals(
          market: LearningMarket.oneXTwo,
          goals: (home: fixedHome, away: fixedAway, usedFallback: false),
        );
        final leagueAwareOutput = EngineReplica.evaluateGoals(
          market: LearningMarket.oneXTwo,
          goals: (
            home: leagueAwareHome,
            away: leagueAwareAway,
            usedFallback: false,
          ),
        );

        final fixedScore = _Score(
          brier: Metrics.brierMultiClass(
            probabilities: fixedOutput.classProbabilities,
            outcomeIndex: outcomeIndex,
          ),
          logLoss: Metrics.logLossMultiClass(
            probabilities: fixedOutput.classProbabilities,
            outcomeIndex: outcomeIndex,
          ),
        );
        final leagueAwareScore = _Score(
          brier: Metrics.brierMultiClass(
            probabilities: leagueAwareOutput.classProbabilities,
            outcomeIndex: outcomeIndex,
          ),
          logLoss: Metrics.logLossMultiClass(
            probabilities: leagueAwareOutput.classProbabilities,
            outcomeIndex: outcomeIndex,
          ),
        );

        fixedAggregate.add(fixedScore);
        leagueAwareAggregate.add(leagueAwareScore);
        fixedForLeague.add(fixedScore);
        leagueAwareForLeague.add(leagueAwareScore);
      }

      if (fixedForLeague.count > 0) {
        leaguesWithComparableHoldout += 1;
        perLeagueReport.add({
          'leagueId': leagueId,
          'leagueName': league['league_name'],
          'comparableHoldoutSamples': fixedForLeague.count,
          'fixedBaselineBrier': fixedForLeague.averageBrier,
          'leagueAwareBaselineBrier': leagueAwareForLeague.averageBrier,
          'brierDelta':
              leagueAwareForLeague.averageBrier - fixedForLeague.averageBrier,
        });
      }
    }

    stdout.writeln('== ERGEBNIS (Markt: 1X2, alle Holdout-Fälle mit '
        'leakage-sicherem Liga-Kontext, repräsentative Team-Stichprobe '
        'sampleSize=${FootballEngineInputService.sampleSizeShrinkageK}) ==');
    stdout.writeln('Ligen mit vergleichbaren Holdout-Fällen: '
        '$leaguesWithComparableHoldout');
    stdout.writeln('Vergleichbare Holdout-Spiele gesamt: '
        '${fixedAggregate.count}\n');

    if (fixedAggregate.count == 0) {
      stdout.writeln('KEINE vergleichbaren Fälle gefunden - Backtest liefert '
          'keine Entscheidungsgrundlage. Vermutlich zu wenig historische '
          'Phase-2-Snapshots mit Liga-Kontext (siehe Doc-Kommentar oben).');
      return;
    }

    stdout.writeln('Fester globaler Normalwert   - Ø Brier: '
        '${fixedAggregate.averageBrier.toStringAsFixed(5)}, Ø Log Loss: '
        '${fixedAggregate.averageLogLoss.toStringAsFixed(5)}');
    stdout.writeln('Liga-bewusster Normalwert    - Ø Brier: '
        '${leagueAwareAggregate.averageBrier.toStringAsFixed(5)}, Ø Log Loss: '
        '${leagueAwareAggregate.averageLogLoss.toStringAsFixed(5)}');

    final brierDelta =
        leagueAwareAggregate.averageBrier - fixedAggregate.averageBrier;
    final logLossDelta =
        leagueAwareAggregate.averageLogLoss - fixedAggregate.averageLogLoss;
    stdout.writeln('\nDelta Brier (negativ = liga-bewusst besser): '
        '${brierDelta.toStringAsFixed(5)}');
    stdout.writeln('Delta Log Loss (negativ = liga-bewusst besser): '
        '${logLossDelta.toStringAsFixed(5)}');

    stdout.writeln(
      brierDelta <= 0 && logLossDelta <= 0
          ? '\n=> ENTSCHEIDUNGS-GATE: liga-bewusster Normalwert ist auf dem '
              'Holdout NICHT schlechter - Live-Schaltung vertretbar.'
          : '\n=> ENTSCHEIDUNGS-GATE: liga-bewusster Normalwert ist auf dem '
              'Holdout SCHLECHTER - NICHT live schalten, Ursache klären.',
    );

    stdout.writeln('\n== PRO LIGA (sortiert: größte Verschlechterung zuerst) ==');
    perLeagueReport
        .sort((a, b) => (b['brierDelta'] as double).compareTo(a['brierDelta'] as double));
    for (final entry in perLeagueReport) {
      stdout.writeln(jsonEncode(entry));
    }
  } finally {
    await database.close();
  }
}

double? _num(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

double? _averageAvailable(double? a, double? b) {
  if (a == null && b == null) return null;
  if (a == null) return b;
  if (b == null) return a;
  return (a + b) / 2;
}

class _Score {
  const _Score({required this.brier, required this.logLoss});
  final double brier;
  final double logLoss;
}

class _AggregateScore {
  int count = 0;
  double _brierSum = 0.0;
  double _logLossSum = 0.0;

  void add(_Score score) {
    count += 1;
    _brierSum += score.brier;
    _logLossSum += score.logLoss;
  }

  double get averageBrier => count == 0 ? 0.0 : _brierSum / count;
  double get averageLogLoss => count == 0 ? 0.0 : _logLossSum / count;
}
