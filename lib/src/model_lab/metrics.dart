import 'dart:math';

/// Statistische Bewertungsfunktionen für das Self-Learning-System
/// (Section 37-43). Alle Funktionen sind pure/deterministisch und
/// DB-unabhängig, um sie mit reinen Unit-Tests abzudecken.
class Metrics {
  const Metrics._();

  static const double _epsilon = 1e-9;

  /// Multi-Class Brier Score für EIN Match (Section 39): Summe der
  /// quadrierten Abweichungen zwischen vorhergesagter Wahrscheinlichkeit und
  /// One-Hot-Ergebnis über alle Klassen. Kleiner ist besser (0 = perfekt).
  static double brierMultiClass({
    required List<double> probabilities,
    required int outcomeIndex,
  }) {
    var sum = 0.0;
    for (var i = 0; i < probabilities.length; i++) {
      final target = i == outcomeIndex ? 1.0 : 0.0;
      final diff = probabilities[i] - target;
      sum += diff * diff;
    }
    return sum;
  }

  /// Binärer Brier Score (Section 40): (p - y)^2 für die positive Klasse.
  static double brierBinary({
    required double probability,
    required bool outcomePositive,
  }) {
    final target = outcomePositive ? 1.0 : 0.0;
    final diff = probability - target;
    return diff * diff;
  }

  /// Multi-Class Log Loss (Section 39): -ln(p der eingetretenen Klasse).
  static double logLossMultiClass({
    required List<double> probabilities,
    required int outcomeIndex,
  }) {
    final p = probabilities[outcomeIndex].clamp(_epsilon, 1 - _epsilon);
    return -log(p);
  }

  /// Binärer Log Loss (Section 40).
  static double logLossBinary({
    required double probability,
    required bool outcomePositive,
  }) {
    final p = probability.clamp(_epsilon, 1 - _epsilon);
    return outcomePositive ? -log(p) : -log(1 - p);
  }

  /// Section 41: Calibration-Buckets. `samples` sind Paare aus vorhergesagter
  /// Wahrscheinlichkeit der eingetretenen/betrachteten Klasse und ob sie
  /// tatsächlich eingetreten ist. Buckets mit weniger als [minSample]
  /// Vorhersagen werden ausgeblendet (Section 76: keine irreführenden
  /// Mini-Sample-Buckets).
  static List<CalibrationBucket> calibrationBuckets({
    required List<({double predicted, bool actual})> samples,
    required int minSample,
    List<double> edges = const [0.50, 0.55, 0.60, 0.65, 0.70, 0.80, 1.0001],
  }) {
    final buckets = <CalibrationBucket>[];
    for (var i = 0; i < edges.length - 1; i++) {
      final lower = edges[i];
      final upper = edges[i + 1];
      final inBucket = samples.where(
        (s) => s.predicted >= lower && s.predicted < upper,
      );
      final count = inBucket.length;
      if (count < minSample) continue;
      final avgPredicted =
          inBucket.map((s) => s.predicted).reduce((a, b) => a + b) / count;
      final actualRate =
          inBucket.where((s) => s.actual).length / count;
      buckets.add(
        CalibrationBucket(
          lowerBound: lower,
          upperBound: upper,
          sampleCount: count,
          averagePredicted: avgPredicted,
          actualRate: actualRate,
        ),
      );
    }
    return buckets;
  }

  /// Section 43: Paired-Bootstrap über Match-Loss-Differenzen
  /// (challenger_loss - champion_loss). Negative Differenz = Challenger
  /// besser (niedrigerer Loss) für dieses Match.
  static PairedUncertaintyResult pairedBootstrap({
    required List<double> lossDifferences,
    required int resamples,
    required double confidenceLevel,
    required int minSampleSize,
    int? randomSeed,
  }) {
    final n = lossDifferences.length;
    if (n < minSampleSize) {
      return const PairedUncertaintyResult(
        sampleSize: 0,
        meanDifference: 0,
        lowerBound: 0,
        upperBound: 0,
        status: ComparisonStatus.notEnoughData,
      );
    }

    final random = Random(randomSeed ?? 42);
    final resampledMeans = <double>[];
    for (var b = 0; b < resamples; b++) {
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        sum += lossDifferences[random.nextInt(n)];
      }
      resampledMeans.add(sum / n);
    }
    resampledMeans.sort();

    final alpha = 1 - confidenceLevel;
    final lowerIndex = ((alpha / 2) * resamples).floor().clamp(
      0,
      resamples - 1,
    );
    final upperIndex = ((1 - alpha / 2) * resamples).floor().clamp(
      0,
      resamples - 1,
    );

    final meanDifference =
        lossDifferences.reduce((a, b) => a + b) / n;
    final lower = resampledMeans[lowerIndex];
    final upper = resampledMeans[upperIndex];

    final ComparisonStatus status;
    if (upper < 0) {
      status = ComparisonStatus.challengerClearlyBetter;
    } else if (lower > 0) {
      status = ComparisonStatus.championBetter;
    } else {
      status = ComparisonStatus.approximatelyEqual;
    }

    return PairedUncertaintyResult(
      sampleSize: n,
      meanDifference: meanDifference,
      lowerBound: lower,
      upperBound: upper,
      status: status,
    );
  }
}

class CalibrationBucket {
  const CalibrationBucket({
    required this.lowerBound,
    required this.upperBound,
    required this.sampleCount,
    required this.averagePredicted,
    required this.actualRate,
  });

  final double lowerBound;
  final double upperBound;
  final int sampleCount;
  final double averagePredicted;
  final double actualRate;

  Map<String, Object?> toJson() => {
    'lowerBound': lowerBound,
    'upperBound': upperBound,
    'sampleCount': sampleCount,
    'averagePredicted': double.parse(averagePredicted.toStringAsFixed(4)),
    'actualRate': double.parse(actualRate.toStringAsFixed(4)),
  };
}

enum ComparisonStatus {
  challengerClearlyBetter,
  approximatelyEqual,
  championBetter,
  notEnoughData,
}

class PairedUncertaintyResult {
  const PairedUncertaintyResult({
    required this.sampleSize,
    required this.meanDifference,
    required this.lowerBound,
    required this.upperBound,
    required this.status,
  });

  final int sampleSize;
  final double meanDifference;
  final double lowerBound;
  final double upperBound;
  final ComparisonStatus status;

  Map<String, Object?> toJson() => {
    'sampleSize': sampleSize,
    'meanDifference': double.parse(meanDifference.toStringAsFixed(6)),
    'lowerBound': double.parse(lowerBound.toStringAsFixed(6)),
    'upperBound': double.parse(upperBound.toStringAsFixed(6)),
    'status': status.name,
  };
}
