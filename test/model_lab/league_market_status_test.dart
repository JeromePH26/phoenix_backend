import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/model_lab/league_market_status.dart';
import 'package:test/test.dart';

ModelLabConfig _config() => ModelLabConfig(
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
  group('classifyLeagueMarketStatus', () {
    // Test 1 (Section 86, spirit): a league below the minimum never gets
    // treated as learning-eligible, matching the "no artificial training"
    // rule (Section 3/93).
    test('too little data is always NOT_ENOUGH_DATA regardless of other flags', () {
      final status = classifyLeagueMarketStatus(
        eligibleSampleSize: 10,
        hasLeagueChampion: true,
        hasLeagueChallengers: true,
        hasShadowPredictions: true,
        config: _config(),
      );
      expect(status, LeagueMarketStatus.notEnoughData);
    });

    test('enough data but below the adaptation threshold stays GLOBAL_ONLY', () {
      final status = classifyLeagueMarketStatus(
        eligibleSampleSize: 80,
        hasLeagueChampion: false,
        hasLeagueChallengers: false,
        hasShadowPredictions: false,
        config: _config(),
      );
      expect(status, LeagueMarketStatus.globalOnly);
    });

    test('above the adaptation threshold with no challenger yet is LEAGUE_ADAPTATION', () {
      final status = classifyLeagueMarketStatus(
        eligibleSampleSize: 150,
        hasLeagueChampion: false,
        hasLeagueChallengers: false,
        hasShadowPredictions: false,
        config: _config(),
      );
      expect(status, LeagueMarketStatus.leagueAdaptation);
    });

    test('existing challengers with no champion is CHALLENGER_READY', () {
      final status = classifyLeagueMarketStatus(
        eligibleSampleSize: 150,
        hasLeagueChampion: false,
        hasLeagueChallengers: true,
        hasShadowPredictions: false,
        config: _config(),
      );
      expect(status, LeagueMarketStatus.challengerReady);
    });

    test('shadow predictions without a league champion is SHADOW_ACTIVE', () {
      final status = classifyLeagueMarketStatus(
        eligibleSampleSize: 150,
        hasLeagueChampion: false,
        hasLeagueChallengers: true,
        hasShadowPredictions: true,
        config: _config(),
      );
      expect(status, LeagueMarketStatus.shadowActive);
    });

    test('an existing league champion always wins as CHAMPION_ACTIVE', () {
      final status = classifyLeagueMarketStatus(
        eligibleSampleSize: 700,
        hasLeagueChampion: true,
        hasLeagueChallengers: true,
        hasShadowPredictions: true,
        config: _config(),
      );
      expect(status, LeagueMarketStatus.championActive);
    });
  });

  group('sampleSizeTier', () {
    test('maps sample sizes to the four documented tiers', () {
      final config = _config();
      expect(sampleSizeTier(50, config), 'practically_global_only');
      expect(sampleSizeTier(150, config), 'cautious_league_adaptation');
      expect(sampleSizeTier(400, config), 'stronger_league_adaptation');
      expect(sampleSizeTier(700, config), 'full_league_engine_possible');
    });
  });
}
