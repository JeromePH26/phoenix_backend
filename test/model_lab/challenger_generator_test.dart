import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/model_lab/challenger_generator.dart';
import 'package:test/test.dart';

ModelLabConfig _config({
  required double attackWeightMin,
  required double attackWeightMax,
  required List<double> attackWeightGrid,
  required int maxChallengersPerLeagueMarket,
}) => ModelLabConfig(
  promotionEnabled: false,
  minDataQuality: 50,
  minLearningEligibleSamples: 50,
  leagueAdaptationSampleThreshold: 100,
  strongerAdaptationSampleThreshold: 300,
  fullLeagueEngineSampleThreshold: 600,
  shrinkageK: 150,
  attackWeightMin: attackWeightMin,
  attackWeightMax: attackWeightMax,
  attackWeightGrid: attackWeightGrid,
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
  maxChallengersPerLeagueMarket: maxChallengersPerLeagueMarket,
  staleLockMinutes: 180,
);

void main() {
  group('ChallengerGenerator.candidateAttackWeights', () {
    test('returns the whole grid when it already fits the challenger cap', () {
      final config = _config(
        attackWeightMin: 0.20,
        attackWeightMax: 0.80,
        attackWeightGrid: const [0.20, 0.35, 0.45, 0.55, 0.65, 0.80],
        maxChallengersPerLeagueMarket: 6,
      );
      expect(
        ChallengerGenerator.candidateAttackWeights(config),
        const [0.20, 0.35, 0.45, 0.55, 0.65, 0.80],
      );
    });

    test('drops out-of-bounds candidates before capping', () {
      final config = _config(
        attackWeightMin: 0.30,
        attackWeightMax: 0.70,
        attackWeightGrid: const [0.10, 0.40, 0.60, 0.95],
        maxChallengersPerLeagueMarket: 4,
      );
      expect(ChallengerGenerator.candidateAttackWeights(config), const [0.40, 0.60]);
    });

    // Regression: ein Gitter mit mehr Punkten als der Challenger-Obergrenze
    // hätte vorher mit `.take(n)` nach dem Sortieren immer nur die
    // NIEDRIGSTEN Werte behalten - der obere Teil des konfigurierten
    // Suchraums wäre nie getestet worden.
    test('samples evenly across the full range instead of truncating to the lowest values', () {
      final config = _config(
        attackWeightMin: 0.0,
        attackWeightMax: 1.0,
        attackWeightGrid: const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
        maxChallengersPerLeagueMarket: 3,
      );
      final result = ChallengerGenerator.candidateAttackWeights(config);
      expect(result, const [0.0, 0.6, 1.0]);
      // Der höchste Gitterwert darf nicht systematisch verloren gehen.
      expect(result.last, greaterThan(0.6));
    });

    test('handles a challenger cap of exactly 1 without dividing by zero', () {
      final config = _config(
        attackWeightMin: 0.0,
        attackWeightMax: 1.0,
        attackWeightGrid: const [0.2, 0.4, 0.6, 0.8],
        maxChallengersPerLeagueMarket: 1,
      );
      expect(ChallengerGenerator.candidateAttackWeights(config), const [0.2]);
    });
  });
}
