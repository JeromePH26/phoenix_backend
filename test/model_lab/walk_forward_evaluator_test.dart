import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/learning_sample.dart';
import 'package:phoenix_backend/src/model_lab/walk_forward_evaluator.dart';
import 'package:phoenix_backend/src/model_lab/weight_config.dart';
import 'package:test/test.dart';

ModelLabConfig _config({
  double holdoutFraction = 0.20,
  int minTrainingWindow = 20,
  int stepSize = 10,
}) => ModelLabConfig(
  promotionEnabled: false,
  minDataQuality: 50,
  minLearningEligibleSamples: 50,
  leagueAdaptationSampleThreshold: 100,
  strongerAdaptationSampleThreshold: 300,
  fullLeagueEngineSampleThreshold: 600,
  shrinkageK: 150,
  attackWeightMin: 0.30,
  attackWeightMax: 0.70,
  attackWeightGrid: const [0.40, 0.45, 0.55, 0.60],
  holdoutFraction: holdoutFraction,
  walkForwardMinTrainingWindow: minTrainingWindow,
  walkForwardStepSize: stepSize,
  minHoldoutSample: 5,
  minValidationSample: 5,
  minShadowSample: 5,
  minPromotionSample: 10,
  bootstrapResamples: 200,
  bootstrapConfidenceLevel: 0.95,
  calibrationMinBucketSample: 5,
  redCardEarlyMinute: 30,
  redCardLateMinute: 75,
  learningRunWeekday: DateTime.tuesday,
  learningRunHourBerlin: 4,
  monthlyReviewWeekday: DateTime.wednesday,
  monthlyReviewMaxDayOfMonth: 7,
  maxChallengersPerLeagueMarket: 4,
);

List<LearningSample> _chronologicalSamples(int count) {
  final base = DateTime.utc(2024, 1, 1);
  return List.generate(count, (i) {
    final kickoff = base.add(Duration(days: i));
    return LearningSample(
      fixtureId: 'fixture-$i',
      leagueId: '78',
      kickoff: kickoff,
      snapshotCreatedAt: kickoff.subtract(const Duration(hours: 6)),
      dataQuality: 80,
      features: {
        'raw.homeGoalsForAverageHome': 1.4 + (i % 5) * 0.1,
        'raw.homeGoalsAgainstAverageHome': 1.1,
        'raw.awayGoalsForAverageAway': 1.0,
        'raw.awayGoalsAgainstAverageAway': 1.3,
      },
      homeGoals: i.isEven ? 2 : 1,
      awayGoals: i.isEven ? 0 : 1,
    );
  });
}

void main() {
  group('ChronologicalSplit.split', () {
    // Test 7 (Section 86): Walk-Forward Test - keine Zukunft im Training.
    test('every walk-forward step tests only matches after its training window', () {
      final samples = _chronologicalSamples(100);
      final split = ChronologicalSplit.split(samples, _config());

      for (final step in split.steps) {
        expect(step.isChronologicallyValid, isTrue);
        expect(step.testStartInclusive, greaterThanOrEqualTo(step.trainEndExclusive));
      }
    });

    // Test 8 (Section 86): Holdout Isolation Test.
    test('holdout is always the chronologically last slice and never empty when enough data exists', () {
      final samples = _chronologicalSamples(100);
      final split = ChronologicalSplit.split(samples, _config());

      expect(split.holdout, isNotEmpty);
      final trainingAndValidation = [...split.training, ...split.validation];
      final latestNonHoldout = trainingAndValidation
          .map((s) => s.kickoff)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final earliestHoldout = split.holdout
          .map((s) => s.kickoff)
          .reduce((a, b) => a.isBefore(b) ? a : b);

      expect(earliestHoldout.isAfter(latestNonHoldout), isTrue);
    });

    test('training, validation and holdout partition the full sample set exactly once', () {
      final samples = _chronologicalSamples(97);
      final split = ChronologicalSplit.split(samples, _config());

      final total = split.training.length + split.validation.length + split.holdout.length;
      expect(total, samples.length);

      final allFixtureIds = {
        ...split.training.map((s) => s.fixtureId),
        ...split.validation.map((s) => s.fixtureId),
        ...split.holdout.map((s) => s.fixtureId),
      };
      expect(allFixtureIds.length, samples.length);
    });

    test('an empty sample list produces an empty, safe split', () {
      final split = ChronologicalSplit.split(const [], _config());
      expect(split.training, isEmpty);
      expect(split.validation, isEmpty);
      expect(split.holdout, isEmpty);
      expect(split.steps, isEmpty);
    });
  });

  group('ChampionChallengerComparison.compare', () {
    // Test 9 (Section 86): Same Matches Comparison Test.
    test('champion and challenger are always evaluated on the identical match set', () {
      final samples = _chronologicalSamples(60);
      final comparison = ChampionChallengerComparison.compare(
        market: LearningMarket.oneXTwo,
        leagueId: '78',
        scopeSamples: samples,
        championWeights: EngineWeightConfig.global,
        challengerWeights: const EngineWeightConfig(attackWeight: 0.6),
        config: _config(),
      );

      expect(comparison.championAll.sampleSize, samples.length);
      expect(comparison.challengerAll.sampleSize, samples.length);
    });

    test('an identical challenger to the champion shows exactly zero mean difference', () {
      final samples = _chronologicalSamples(60);
      final comparison = ChampionChallengerComparison.compare(
        market: LearningMarket.btts,
        leagueId: '78',
        scopeSamples: samples,
        championWeights: EngineWeightConfig.global,
        challengerWeights: EngineWeightConfig.global,
        config: _config(),
      );
      expect(comparison.brierUncertainty.meanDifference, closeTo(0.0, 1e-9));
    });

    // Section 27: All vs Clean.
    test('clean scope only ever contains a subset of the all scope', () {
      final samples = _chronologicalSamples(40);
      final comparison = ChampionChallengerComparison.compare(
        market: LearningMarket.overUnder25,
        leagueId: '78',
        scopeSamples: samples,
        championWeights: EngineWeightConfig.global,
        challengerWeights: const EngineWeightConfig(attackWeight: 0.45),
        config: _config(),
      );
      expect(comparison.championClean.sampleSize, lessThanOrEqualTo(comparison.championAll.sampleSize));
    });
  });
}
