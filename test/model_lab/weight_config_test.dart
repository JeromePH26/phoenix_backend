import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/model_lab/weight_config.dart';
import 'package:test/test.dart';

ModelLabConfig _config({int shrinkageK = 150}) => ModelLabConfig(
  promotionEnabled: false,
  minDataQuality: 50,
  minLearningEligibleSamples: 50,
  leagueAdaptationSampleThreshold: 100,
  strongerAdaptationSampleThreshold: 300,
  fullLeagueEngineSampleThreshold: 600,
  shrinkageK: shrinkageK,
  attackWeightMin: 0.30,
  attackWeightMax: 0.70,
  attackWeightGrid: const [0.40, 0.45, 0.55, 0.60],
  holdoutFraction: 0.20,
  walkForwardMinTrainingWindow: 60,
  walkForwardStepSize: 20,
  minHoldoutSample: 40,
  minValidationSample: 40,
  minShadowSample: 30,
  minPromotionSample: 120,
  bootstrapResamples: 500,
  bootstrapConfidenceLevel: 0.95,
  calibrationMinBucketSample: 20,
  redCardEarlyMinute: 30,
  redCardLateMinute: 75,
  learningRunWeekday: DateTime.tuesday,
  learningRunHourBerlin: 4,
  monthlyReviewWeekday: DateTime.wednesday,
  monthlyReviewMaxDayOfMonth: 7,
  maxChallengersPerLeagueMarket: 4,
  staleLockMinutes: 180,
);

void main() {
  group('EngineWeightConfig bounds', () {
    // Test 14 (Section 14): sinnvolle Suchräume.
    test('global baseline is exactly the production 50/50 split', () {
      expect(EngineWeightConfig.global.attackWeight, 0.5);
      expect(EngineWeightConfig.global.defenseWeight, 0.5);
    });

    test('candidates within [0.30, 0.70] are considered within bounds', () {
      final config = _config();
      expect(const EngineWeightConfig(attackWeight: 0.45).isWithinBounds(config), isTrue);
      expect(const EngineWeightConfig(attackWeight: 0.30).isWithinBounds(config), isTrue);
      expect(const EngineWeightConfig(attackWeight: 0.70).isWithinBounds(config), isTrue);
    });

    test('an absurd candidate like 0.90/0.10 is rejected as out of bounds', () {
      final config = _config();
      expect(const EngineWeightConfig(attackWeight: 0.90).isWithinBounds(config), isFalse);
      expect(const EngineWeightConfig(attackWeight: 0.05).isWithinBounds(config), isFalse);
    });
  });

  // Test 30 (Section 86): Global Shrinkage Test.
  group('EngineWeightConfig.shrunkTowardsGlobal', () {
    test('a tiny league sample stays very close to the global weight', () {
      final config = _config();
      const raw = EngineWeightConfig(attackWeight: 0.70);
      final shrunk = raw.shrunkTowardsGlobal(sampleSize: 10, config: config);
      // factor = 10 / (10 + 150) ≈ 0.0625 -> barely moves from 0.5
      expect(shrunk.attackWeight, closeTo(0.5125, 0.001));
      expect(shrunk.attackWeight, lessThan(0.55));
    });

    test('a large league sample moves much closer to the raw candidate', () {
      final config = _config();
      const raw = EngineWeightConfig(attackWeight: 0.70);
      final shrunk = raw.shrunkTowardsGlobal(sampleSize: 5000, config: config);
      // factor = 5000 / 5150 ≈ 0.9709
      expect(shrunk.attackWeight, closeTo(0.6942, 0.001));
    });

    test('shrinkage is monotonic in sample size', () {
      final config = _config();
      const raw = EngineWeightConfig(attackWeight: 0.65);
      final small = raw.shrunkTowardsGlobal(sampleSize: 50, config: config);
      final medium = raw.shrunkTowardsGlobal(sampleSize: 500, config: config);
      final large = raw.shrunkTowardsGlobal(sampleSize: 5000, config: config);
      expect(small.attackWeight, lessThan(medium.attackWeight));
      expect(medium.attackWeight, lessThan(large.attackWeight));
    });

    test('shrinking the global weight itself is a no-op', () {
      final config = _config();
      final shrunk = EngineWeightConfig.global.shrunkTowardsGlobal(
        sampleSize: 1000,
        config: config,
      );
      expect(shrunk.attackWeight, closeTo(0.5, 1e-9));
    });
  });

  group('EngineWeightConfig.configHash', () {
    // Test 10 (Section 86): Immutable Model Test (hash stability part).
    test('identical weights always produce the identical hash', () {
      const a = EngineWeightConfig(attackWeight: 0.55);
      const b = EngineWeightConfig(attackWeight: 0.55);
      expect(a.configHash(), b.configHash());
    });

    test('different weights produce different hashes', () {
      const a = EngineWeightConfig(attackWeight: 0.55);
      const b = EngineWeightConfig(attackWeight: 0.56);
      expect(a.configHash(), isNot(b.configHash()));
    });
  });
}
