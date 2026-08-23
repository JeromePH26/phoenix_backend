import 'dart:io';

import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/engine_replica.dart';
import 'package:phoenix_backend/src/model_lab/learning_dataset_builder.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/learning_sample.dart';
import 'package:phoenix_backend/src/model_lab/metrics.dart';
import 'package:phoenix_backend/src/model_lab/walk_forward_evaluator.dart';
import 'package:phoenix_backend/src/model_lab/weight_config.dart';

/// READ-ONLY Offline-Analyse: für jeden Markt, über ALLE Ligen (inkl.
/// Datenpool) gepoolt, welcher attackWeight-Wert die Vorhersagen tatsächlich
/// am genauesten macht, und wie GLOBAL_GOALS_V1 im Vergleich dazu abschneidet.
///
/// Kein INSERT/UPDATE/DELETE in irgendeine Model-Lab- oder Produktionstabelle
/// (außer dem additiven `database.migrate()`, identisch sicher wie jeder
/// andere Boot-Pfad) - reine Analyse, komplett getrennt von der echten
/// Learning-Run-Pipeline (`learning_run_service.dart`), die weiterhin nur
/// Fokus+Beobachtungsliga nutzt und ausschließlich das feste, sichere
/// Produktions-Gitter durchprobiert.
///
/// Methodik (um kein Rauschen als Verbesserung zu verkaufen):
/// 1. Für jeden Markt werden ALLE Samples (aller Ligen, aller Tiers) gepoolt
///    und chronologisch in Training/Validation/Holdout geteilt (identisch
///    zur echten Pipeline, `ChronologicalSplit`).
/// 2. Ein feines Gitter (0.00 bis 1.00 in 0.025-Schritten, 41 Punkte) wird
///    NUR auf der Validation-Menge gegen den heutigen 0.5-Champion verglichen
///    - das ist die Such-/Auswahlphase.
/// 3. Der beste Validation-Kandidat wird ZUSÄTZLICH separat auf der
///    Holdout-Menge geprüft (die beim Suchen nie angefasst wurde) - das ist
///    die ehrliche, unabhängige Bestätigung. Nur wenn beide Mengen densel*ben
///    Kandidaten als besser bestätigen, ist das Ergebnis belastbar.
/// 4. GLOBAL_GOALS_V1 wird auf derselben gepoolten Menge genauso geprüft.
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
    stdout.writeln('== Migration (additiv, identisch zum produktiven Boot-Pfad) ==');
    await database.migrate();
    stdout.writeln('OK\n');

    final datasetBuilder = LearningDatasetBuilder(database: database, config: config);

    stdout.writeln('== Lade gepoolten Datensatz (ALLE Tiers, inkl. Datenpool) ==');
    final samplesByLeague = await datasetBuilder.buildSamplesByLeague(includeAllTiers: true);
    final pooled = <LearningSample>[
      for (final samples in samplesByLeague.values) ...samples,
    ]..sort((a, b) => a.kickoff.compareTo(b.kickoff));
    stdout.writeln('Gesamt: ${pooled.length} Samples über ${samplesByLeague.length} Ligen.\n');

    // Feines Gitter für die Exploration - bewusst NICHT auf die
    // produktions-sicheren Grenzen [0.20, 0.80] beschränkt, weil hier
    // gezielt der tatsächliche Optimalwert gesucht wird, nicht nur ein
    // sicherer Kandidat innerhalb bereits akzeptierter Grenzen.
    final grid = [for (var i = 0; i <= 40; i++) i * 0.025];

    // Die Sample-Auswahl (welche Spiele überhaupt eligible sind) hängt nicht
    // vom Markt ab - nur die Auswertung eines Samples tut das
    // (`outcomeIndexFor(market)`). Der chronologische Split ist deshalb für
    // alle 17 Märkte identisch und wird nur einmal berechnet.
    final split = ChronologicalSplit.split(pooled, config);

    final results = <_MarketResult>[];

    for (final market in LearningMarket.values) {
      if (split.validation.length < config.minValidationSample) {
        results.add(_MarketResult.notEnoughData(market, split.validation.length));
        continue;
      }

      final championEngine = const ModelEngine.attackWeightBlend(EngineWeightConfig.global);

      _GridPoint? best;
      for (final weight in grid) {
        if (weight == 0.5) continue; // identisch zum Champion, uninteressant
        final challengerEngine = ModelEngine.attackWeightBlend(EngineWeightConfig(attackWeight: weight));
        final comparison = ChampionChallengerComparison.compare(
          market: market,
          leagueId: null,
          scopeSamples: split.validation,
          championEngine: championEngine,
          challengerEngine: challengerEngine,
          config: config,
        );
        final point = _GridPoint(
          weight: weight,
          meanBrierDiff: comparison.brierUncertainty.meanDifference,
          challengerBrier: comparison.challengerAll.meanBrier,
        );
        if (best == null || point.meanBrierDiff < best.meanBrierDiff) {
          best = point;
        }
      }

      if (best == null) {
        results.add(_MarketResult.notEnoughData(market, split.validation.length));
        continue;
      }

      // Bestätigung auf der beim Suchen nie angefassten Holdout-Menge.
      final holdoutComparison = split.holdout.isEmpty
          ? null
          : ChampionChallengerComparison.compare(
              market: market,
              leagueId: null,
              scopeSamples: split.holdout,
              championEngine: championEngine,
              challengerEngine: ModelEngine.attackWeightBlend(EngineWeightConfig(attackWeight: best.weight)),
              config: config,
            );

      // GLOBAL_GOALS_V1 auf derselben Validation-Menge, gleiche Methodik.
      final ggv1Validation = split.validation.where((s) => s.hasGlobalGoalsV1Data).toList();
      final ggv1Holdout = split.holdout.where((s) => s.hasGlobalGoalsV1Data).toList();
      ChampionChallengerComparison? ggv1ValidationComparison;
      ChampionChallengerComparison? ggv1HoldoutComparison;
      if (ggv1Validation.length >= config.minValidationSample) {
        ggv1ValidationComparison = ChampionChallengerComparison.compare(
          market: market,
          leagueId: null,
          scopeSamples: ggv1Validation,
          championEngine: championEngine,
          challengerEngine: const ModelEngine.globalGoalsV1(),
          config: config,
        );
        if (ggv1Holdout.isNotEmpty) {
          ggv1HoldoutComparison = ChampionChallengerComparison.compare(
            market: market,
            leagueId: null,
            scopeSamples: ggv1Holdout,
            championEngine: championEngine,
            challengerEngine: const ModelEngine.globalGoalsV1(),
            config: config,
          );
        }
      }

      results.add(_MarketResult(
        market: market,
        validationSampleSize: split.validation.length,
        holdoutSampleSize: split.holdout.length,
        bestWeight: best.weight,
        validationMeanBrierDiff: best.meanBrierDiff,
        holdoutMeanBrierDiff: holdoutComparison?.brierUncertainty.meanDifference,
        holdoutStatus: holdoutComparison?.brierUncertainty.status,
        ggv1SampleSize: ggv1Validation.length,
        ggv1ValidationMeanBrierDiff: ggv1ValidationComparison?.brierUncertainty.meanDifference,
        ggv1HoldoutSampleSize: ggv1Holdout.length,
        ggv1HoldoutMeanBrierDiff: ggv1HoldoutComparison?.brierUncertainty.meanDifference,
        ggv1HoldoutStatus: ggv1HoldoutComparison?.brierUncertainty.status,
      ));
    }

    stdout.writeln('== Ergebnisse pro Markt (gepoolt über alle Ligen/Tiers) ==\n');
    for (final r in results) {
      stdout.writeln(r.describe(config));
      stdout.writeln('');
    }
  } finally {
    await database.close();
  }
}

class _GridPoint {
  const _GridPoint({
    required this.weight,
    required this.meanBrierDiff,
    required this.challengerBrier,
  });
  final double weight;
  final double meanBrierDiff;
  final double challengerBrier;
}

class _MarketResult {
  const _MarketResult({
    required this.market,
    required this.validationSampleSize,
    required this.holdoutSampleSize,
    this.bestWeight,
    this.validationMeanBrierDiff,
    this.holdoutMeanBrierDiff,
    this.holdoutStatus,
    this.ggv1SampleSize = 0,
    this.ggv1ValidationMeanBrierDiff,
    this.ggv1HoldoutSampleSize = 0,
    this.ggv1HoldoutMeanBrierDiff,
    this.ggv1HoldoutStatus,
  });

  factory _MarketResult.notEnoughData(LearningMarket market, int validationSampleSize) =>
      _MarketResult(market: market, validationSampleSize: validationSampleSize, holdoutSampleSize: 0);

  final LearningMarket market;
  final int validationSampleSize;
  final int holdoutSampleSize;
  final double? bestWeight;
  final double? validationMeanBrierDiff;
  final double? holdoutMeanBrierDiff;
  final ComparisonStatus? holdoutStatus;
  final int ggv1SampleSize;
  final double? ggv1ValidationMeanBrierDiff;
  final int ggv1HoldoutSampleSize;
  final double? ggv1HoldoutMeanBrierDiff;
  final ComparisonStatus? ggv1HoldoutStatus;

  String describe(ModelLabConfig config) {
    final buffer = StringBuffer();
    buffer.writeln('${market.label} (${market.key})');
    if (bestWeight == null) {
      buffer.write('  Zu wenig Daten (Validation: $validationSampleSize, '
          'benötigt: ${config.minValidationSample})');
      return buffer.toString();
    }
    buffer.writeln('  Validation: $validationSampleSize Spiele, Holdout: $holdoutSampleSize Spiele');
    buffer.writeln('  Bester attackWeight-Kandidat: ${bestWeight!.toStringAsFixed(3)} '
        '(Champion = 0.5)');
    buffer.writeln('  Brier-Differenz auf Validation: ${validationMeanBrierDiff!.toStringAsFixed(5)} '
        '(negativ = besser als Champion)');
    if (holdoutMeanBrierDiff != null) {
      buffer.writeln('  Bestätigung auf Holdout: ${holdoutMeanBrierDiff!.toStringAsFixed(5)} '
          '(${holdoutStatus?.name ?? "unbekannt"})');
    } else {
      buffer.writeln('  Keine Holdout-Bestätigung möglich (zu wenig Holdout-Daten).');
    }
    if (ggv1ValidationMeanBrierDiff != null) {
      buffer.writeln('  GLOBAL_GOALS_V1 vs. Champion (Validation, $ggv1SampleSize Spiele): '
          '${ggv1ValidationMeanBrierDiff!.toStringAsFixed(5)}');
      if (ggv1HoldoutMeanBrierDiff != null) {
        buffer.writeln('  GLOBAL_GOALS_V1 vs. Champion (Holdout, $ggv1HoldoutSampleSize Spiele): '
            '${ggv1HoldoutMeanBrierDiff!.toStringAsFixed(5)} '
            '(${ggv1HoldoutStatus?.name ?? "unbekannt"})');
      }
    } else {
      buffer.writeln('  GLOBAL_GOALS_V1: zu wenig Phase-2-Daten für diesen Markt.');
    }
    return buffer.toString();
  }
}
