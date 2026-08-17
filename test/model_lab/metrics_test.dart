import 'package:phoenix_backend/src/model_lab/metrics.dart';
import 'package:test/test.dart';

void main() {
  group('Metrics.brierMultiClass', () {
    // Test 20 (Section 86): 1X2 Brier Test.
    test('is 0 for a perfect prediction', () {
      final brier = Metrics.brierMultiClass(
        probabilities: [1.0, 0.0, 0.0],
        outcomeIndex: 0,
      );
      expect(brier, closeTo(0.0, 1e-9));
    });

    test('matches hand-computed value for a realistic 1X2 prediction', () {
      // (0.6-1)^2 + (0.25-0)^2 + (0.15-0)^2 = 0.16 + 0.0625 + 0.0225 = 0.245
      final brier = Metrics.brierMultiClass(
        probabilities: [0.6, 0.25, 0.15],
        outcomeIndex: 0,
      );
      expect(brier, closeTo(0.245, 1e-9));
    });

    test('is worse (higher) the further probability mass is from the outcome', () {
      final confidentWrong = Metrics.brierMultiClass(
        probabilities: [0.05, 0.05, 0.90],
        outcomeIndex: 0,
      );
      final uncertain = Metrics.brierMultiClass(
        probabilities: [0.33, 0.34, 0.33],
        outcomeIndex: 0,
      );
      expect(confidentWrong, greaterThan(uncertain));
    });
  });

  group('Metrics.brierBinary', () {
    // Test 22 (Section 86): Binary Brier Test.
    test('is 0 for a perfect prediction', () {
      expect(
        Metrics.brierBinary(probability: 1.0, outcomePositive: true),
        closeTo(0.0, 1e-9),
      );
      expect(
        Metrics.brierBinary(probability: 0.0, outcomePositive: false),
        closeTo(0.0, 1e-9),
      );
    });

    test('is 1 for a maximally wrong prediction', () {
      expect(
        Metrics.brierBinary(probability: 0.0, outcomePositive: true),
        closeTo(1.0, 1e-9),
      );
    });

    test('is 0.25 at maximum uncertainty (p=0.5)', () {
      expect(
        Metrics.brierBinary(probability: 0.5, outcomePositive: true),
        closeTo(0.25, 1e-9),
      );
    });
  });

  group('Metrics.logLossMultiClass', () {
    // Test 21 (Section 86): 1X2 Log Loss Test.
    test('equals -ln(p) of the true outcome class', () {
      final logLoss = Metrics.logLossMultiClass(
        probabilities: [0.7, 0.2, 0.1],
        outcomeIndex: 0,
      );
      expect(logLoss, closeTo(0.35667494393873245, 1e-9));
    });

    test('is heavily penalized for a confident wrong prediction', () {
      final logLoss = Metrics.logLossMultiClass(
        probabilities: [0.001, 0.001, 0.998],
        outcomeIndex: 0,
      );
      expect(logLoss, greaterThan(5.0));
    });
  });

  group('Metrics.logLossBinary', () {
    // Test 23 (Section 86): Binary Log Loss Test.
    test('matches multi-class log loss framing for a positive outcome', () {
      final binary = Metrics.logLossBinary(
        probability: 0.7,
        outcomePositive: true,
      );
      expect(binary, closeTo(0.35667494393873245, 1e-9));
    });

    test('uses (1-p) for a negative outcome', () {
      final binary = Metrics.logLossBinary(
        probability: 0.7,
        outcomePositive: false,
      );
      expect(binary, closeTo(1.203972804325936, 1e-9));
    });
  });

  group('Metrics.calibrationBuckets', () {
    // Test 24 (Section 86): Calibration Test.
    test('suppresses buckets below the minimum sample size', () {
      final samples = List.generate(
        5,
        (i) => (predicted: 0.72, actual: i.isEven),
      );
      final buckets = Metrics.calibrationBuckets(
        samples: samples,
        minSample: 20,
      );
      expect(buckets, isEmpty);
    });

    test('reports accurate average predicted vs actual rate per bucket', () {
      final samples = [
        for (var i = 0; i < 30; i++) (predicted: 0.70, actual: i < 21),
      ];
      final buckets = Metrics.calibrationBuckets(
        samples: samples,
        minSample: 20,
      );
      expect(buckets, hasLength(1));
      expect(buckets.first.sampleCount, 30);
      expect(buckets.first.averagePredicted, closeTo(0.70, 1e-9));
      expect(buckets.first.actualRate, closeTo(0.70, 1e-9));
    });
  });

  group('Metrics.pairedBootstrap', () {
    // Test 25 (Section 86): Paired Evaluation Test.
    test('returns notEnoughData below the configured minimum sample size', () {
      final result = Metrics.pairedBootstrap(
        lossDifferences: [-0.05, -0.03],
        resamples: 500,
        confidenceLevel: 0.95,
        minSampleSize: 40,
      );
      expect(result.status, ComparisonStatus.notEnoughData);
      expect(result.sampleSize, 0);
    });

    test('detects a challenger that is clearly and consistently better', () {
      final differences = List.generate(200, (_) => -0.05);
      final result = Metrics.pairedBootstrap(
        lossDifferences: differences,
        resamples: 500,
        confidenceLevel: 0.95,
        minSampleSize: 40,
        randomSeed: 1,
      );
      expect(result.status, ComparisonStatus.challengerClearlyBetter);
    });

    test('detects a champion that is clearly better', () {
      final differences = List.generate(200, (_) => 0.05);
      final result = Metrics.pairedBootstrap(
        lossDifferences: differences,
        resamples: 500,
        confidenceLevel: 0.95,
        minSampleSize: 40,
        randomSeed: 1,
      );
      expect(result.status, ComparisonStatus.championBetter);
    });

    test('is approximately equal when differences hover around zero', () {
      final differences = List.generate(
        200,
        (i) => i.isEven ? 0.001 : -0.001,
      );
      final result = Metrics.pairedBootstrap(
        lossDifferences: differences,
        resamples: 500,
        confidenceLevel: 0.95,
        minSampleSize: 40,
        randomSeed: 1,
      );
      expect(result.status, ComparisonStatus.approximatelyEqual);
    });

    test('never confuses a tiny nominal difference for a real signal', () {
      // Section 43: Brier 0.181 vs 0.182 darf nicht sofort "besser" bedeuten.
      final differences = [
        for (var i = 0; i < 60; i++) (i % 3 == 0 ? -0.01 : 0.009),
      ];
      final result = Metrics.pairedBootstrap(
        lossDifferences: differences,
        resamples: 1000,
        confidenceLevel: 0.95,
        minSampleSize: 40,
        randomSeed: 7,
      );
      expect(result.status, isNot(ComparisonStatus.challengerClearlyBetter));
    });
  });
}
