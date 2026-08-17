import 'dart:math';

import '../config/model_lab_config.dart';
import 'engine_replica.dart';
import 'learning_market.dart';
import 'learning_sample.dart';
import 'metrics.dart';
import 'weight_config.dart';

/// Section 30-32: chronologische Walk-Forward-Aufteilung. Da V0-Challenger
/// feste, vorab begrenzte Gewichtskandidaten sind (kein gradientenbasiertes
/// Fitting je Fenster, siehe `weight_config.dart`), gibt es kein Risiko, dass
/// ein Fenster zukünftige Daten "lernt" - die Aufteilung existiert dennoch
/// explizit, um (a) Training/Validation/Holdout sauber zeitlich zu trennen
/// (Section 32), und (b) die chronologische Integrität automatisiert testbar
/// zu machen (Section 31, siehe `walk_forward_evaluator_test.dart`).
class ChronologicalSplit {
  const ChronologicalSplit({
    required this.training,
    required this.validation,
    required this.holdout,
    required this.steps,
  });

  final List<LearningSample> training;
  final List<LearningSample> validation;
  final List<LearningSample> holdout;
  final List<WalkForwardStep> steps;

  static ChronologicalSplit split(
    List<LearningSample> chronologicalSamples,
    ModelLabConfig config,
  ) {
    final n = chronologicalSamples.length;
    if (n == 0) {
      return const ChronologicalSplit(
        training: [],
        validation: [],
        holdout: [],
        steps: [],
      );
    }

    // Section 32: Final Holdout ist immer der chronologisch JÜNGSTE Teil und
    // fließt nie in Candidate Search/Training ein.
    final holdoutCount = (n * config.holdoutFraction).ceil().clamp(0, n);
    final development = chronologicalSamples.sublist(0, n - holdoutCount);
    final holdout = chronologicalSamples.sublist(n - holdoutCount);

    final trainingWindow = min(
      config.walkForwardMinTrainingWindow,
      development.length,
    );
    final training = development.sublist(0, trainingWindow);
    final validation = development.sublist(trainingWindow);

    final steps = <WalkForwardStep>[];
    var cursor = trainingWindow;
    while (cursor < development.length) {
      final end = min(
        cursor + config.walkForwardStepSize,
        development.length,
      );
      steps.add(
        WalkForwardStep(
          trainEndExclusive: cursor,
          testStartInclusive: cursor,
          testEndExclusive: end,
        ),
      );
      cursor = end;
    }

    return ChronologicalSplit(
      training: training,
      validation: validation,
      holdout: holdout,
      steps: steps,
    );
  }
}

class WalkForwardStep {
  const WalkForwardStep({
    required this.trainEndExclusive,
    required this.testStartInclusive,
    required this.testEndExclusive,
  });

  final int trainEndExclusive;
  final int testStartInclusive;
  final int testEndExclusive;

  /// Section 31: ein Testfenster darf niemals vor dem Ende seines eigenen
  /// Trainingsfensters beginnen.
  bool get isChronologicallyValid => testStartInclusive >= trainEndExclusive;
}

/// Aggregierte Metriken EINER Engine-Konfiguration über eine Sample-Menge.
class MarketEvaluationResult {
  const MarketEvaluationResult({
    required this.sampleSize,
    required this.meanBrier,
    required this.meanLogLoss,
    required this.accuracy,
    required this.avgTopProbability,
    required this.calibration,
    required this.perSampleBrier,
  });

  final int sampleSize;
  final double meanBrier;
  final double meanLogLoss;
  final double accuracy;
  final double avgTopProbability;
  final List<CalibrationBucket> calibration;

  /// Match-Loss-Reihe (Brier je Sample, gleiche Reihenfolge wie die
  /// zugrunde liegenden Samples) - wird für paired bootstrap benötigt.
  final List<double> perSampleBrier;

  static MarketEvaluationResult compute({
    required List<LearningSample> samples,
    required LearningMarket market,
    required EngineWeightConfig weights,
    required ModelLabConfig config,
  }) {
    if (samples.isEmpty) {
      return const MarketEvaluationResult(
        sampleSize: 0,
        meanBrier: 0,
        meanLogLoss: 0,
        accuracy: 0,
        avgTopProbability: 0,
        calibration: [],
        perSampleBrier: [],
      );
    }

    final brierValues = <double>[];
    final logLossValues = <double>[];
    var correct = 0;
    var topProbabilitySum = 0.0;
    final calibrationSamples = <({double predicted, bool actual})>[];

    for (final sample in samples) {
      final output = EngineReplica.evaluate(
        market: market,
        features: sample.features,
        weights: weights,
      );
      final outcomeIndex = sample.outcomeIndexFor(market);

      final brier = market.isMultiClass
          ? Metrics.brierMultiClass(
              probabilities: output.classProbabilities,
              outcomeIndex: outcomeIndex,
            )
          : Metrics.brierBinary(
              probability: output.classProbabilities[0],
              outcomePositive: outcomeIndex == 0,
            );
      final logLoss = market.isMultiClass
          ? Metrics.logLossMultiClass(
              probabilities: output.classProbabilities,
              outcomeIndex: outcomeIndex,
            )
          : Metrics.logLossBinary(
              probability: output.classProbabilities[0],
              outcomePositive: outcomeIndex == 0,
            );

      brierValues.add(brier);
      logLossValues.add(logLoss);

      var topIndex = 0;
      for (var i = 1; i < output.classProbabilities.length; i++) {
        if (output.classProbabilities[i] > output.classProbabilities[topIndex]) {
          topIndex = i;
        }
      }
      if (topIndex == outcomeIndex) correct += 1;
      topProbabilitySum += output.classProbabilities[topIndex];

      calibrationSamples.add((
        predicted: output.classProbabilities[topIndex],
        actual: topIndex == outcomeIndex,
      ));
    }

    final n = samples.length;
    return MarketEvaluationResult(
      sampleSize: n,
      meanBrier: brierValues.reduce((a, b) => a + b) / n,
      meanLogLoss: logLossValues.reduce((a, b) => a + b) / n,
      accuracy: correct / n,
      avgTopProbability: topProbabilitySum / n,
      calibration: Metrics.calibrationBuckets(
        samples: calibrationSamples,
        minSample: config.calibrationMinBucketSample,
      ),
      perSampleBrier: brierValues,
    );
  }

  Map<String, Object?> toJson() => {
    'sampleSize': sampleSize,
    'meanBrier': double.parse(meanBrier.toStringAsFixed(6)),
    'meanLogLoss': double.parse(meanLogLoss.toStringAsFixed(6)),
    'accuracy': double.parse(accuracy.toStringAsFixed(4)),
    'avgTopProbability': double.parse(avgTopProbability.toStringAsFixed(4)),
    'calibration': calibration.map((c) => c.toJson()).toList(),
  };
}

/// Section 42/43: Champion-vs-Challenger-Vergleich, IMMER paired (identische
/// Match-Menge für beide Seiten) und mit statistischer Unsicherheit.
class ChampionChallengerComparison {
  const ChampionChallengerComparison({
    required this.market,
    required this.leagueId,
    required this.championAll,
    required this.challengerAll,
    required this.championClean,
    required this.challengerClean,
    required this.brierUncertainty,
  });

  final LearningMarket market;
  final String? leagueId;
  final MarketEvaluationResult championAll;
  final MarketEvaluationResult challengerAll;
  final MarketEvaluationResult championClean;
  final MarketEvaluationResult challengerClean;
  final PairedUncertaintyResult brierUncertainty;

  static ChampionChallengerComparison compare({
    required LearningMarket market,
    String? leagueId,
    required List<LearningSample> scopeSamples,
    required EngineWeightConfig championWeights,
    required EngineWeightConfig challengerWeights,
    required ModelLabConfig config,
  }) {
    final cleanSamples = scopeSamples
        .where((s) => s.isClean(config))
        .toList(growable: false);

    final championAll = MarketEvaluationResult.compute(
      samples: scopeSamples,
      market: market,
      weights: championWeights,
      config: config,
    );
    final challengerAll = MarketEvaluationResult.compute(
      samples: scopeSamples,
      market: market,
      weights: challengerWeights,
      config: config,
    );
    final championClean = MarketEvaluationResult.compute(
      samples: cleanSamples,
      market: market,
      weights: championWeights,
      config: config,
    );
    final challengerClean = MarketEvaluationResult.compute(
      samples: cleanSamples,
      market: market,
      weights: challengerWeights,
      config: config,
    );

    final diffs = <double>[
      for (var i = 0; i < scopeSamples.length; i++)
        challengerAll.perSampleBrier[i] - championAll.perSampleBrier[i],
    ];

    final uncertainty = Metrics.pairedBootstrap(
      lossDifferences: diffs,
      resamples: config.bootstrapResamples,
      confidenceLevel: config.bootstrapConfidenceLevel,
      minSampleSize: config.minValidationSample,
    );

    return ChampionChallengerComparison(
      market: market,
      leagueId: leagueId,
      championAll: championAll,
      challengerAll: challengerAll,
      championClean: championClean,
      challengerClean: challengerClean,
      brierUncertainty: uncertainty,
    );
  }

  Map<String, Object?> toJson() => {
    'market': market.key,
    'leagueId': leagueId,
    'championAll': championAll.toJson(),
    'challengerAll': challengerAll.toJson(),
    'championClean': championClean.toJson(),
    'challengerClean': challengerClean.toJson(),
    'brierUncertainty': brierUncertainty.toJson(),
  };
}
