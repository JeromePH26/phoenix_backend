import 'package:phoenix_backend/src/model_lab/feature_whitelist.dart';
import 'package:test/test.dart';

void main() {
  group('FeatureWhitelist', () {
    // Test 2 (Section 86): Gemini/AI Isolation Test.
    test('never extracts AI/Gemini legacy fields even if present in snapshot', () {
      final snapshot = <String, Object?>{
        'raw': {
          'homeGoalsForAverageHome': 1.4,
          'homeGoalsAgainstAverageHome': 1.1,
          'awayGoalsForAverageAway': 1.0,
          'awayGoalsAgainstAverageAway': 1.3,
        },
        'dataQuality': 72,
        'realXgAvailable': false,
        'sourceType': 'goal_rates_not_xg',
        'normalized': {
          'homeAttackStrength': 1.03,
          'homeDefenseStrength': 1.22,
          'awayAttackStrength': 0.87,
          'awayDefenseStrength': 1.03,
          'baseGoalRateExpectedHome': 1.25,
          'baseGoalRateExpectedAway': 1.15,
          'geminiHomeGoalDelta': 0.15,
          'geminiAwayGoalDelta': -0.10,
          'contextAdjusted': true,
        },
        'aiContext': {
          'applied': true,
          'reliability': 90,
          'homeGoalDelta': 0.15,
          'lineupStatus': 'confirmed',
        },
      };

      final extracted = FeatureWhitelist.extract(snapshot);

      expect(extracted.containsKey('aiContext'), isFalse);
      expect(extracted.containsKey('normalized.geminiHomeGoalDelta'), isFalse);
      expect(extracted.containsKey('normalized.geminiAwayGoalDelta'), isFalse);
      expect(extracted.containsKey('normalized.contextAdjusted'), isFalse);
      for (final key in extracted.keys) {
        expect(
          key.toLowerCase().contains('gemini') ||
              key.toLowerCase().contains('aicontext') ||
              key.toLowerCase().contains('aireliability') ||
              key.toLowerCase().contains('aianalysis'),
          isFalse,
          reason: '$key looks like an AI/Gemini field and must never be whitelisted',
        );
      }
    });

    // Test 5 (Section 86): Positive Feature Whitelist Test.
    test('ignores unknown/future raw_json fields not on the whitelist', () {
      final snapshot = <String, Object?>{
        'raw': {
          'homeGoalsForAverageHome': 1.4,
          'someBrandNewFutureField': 999,
        },
        'newlyAddedTopLevelField': 'should be ignored',
      };

      final extracted = FeatureWhitelist.extract(snapshot);

      expect(extracted.containsKey('newlyAddedTopLevelField'), isFalse);
      expect(extracted['raw.homeGoalsForAverageHome'], 1.4);
      expect(extracted.length, extracted.keys.toSet().length);
      for (final key in extracted.keys) {
        expect(FeatureWhitelist.allowedPaths.contains(key), isTrue);
      }
    });

    test('extracts all present whitelisted fields correctly', () {
      final snapshot = <String, Object?>{
        'raw': {
          'homeGoalsForAverageHome': 1.5,
          'homeGoalsAgainstAverageHome': 1.2,
          'awayGoalsForAverageAway': 0.9,
          'awayGoalsAgainstAverageAway': 1.4,
        },
        'dataQuality': 80,
        'realXgAvailable': true,
        'sourceType': 'goal_rates_not_xg',
        'normalized': {
          'homeAttackStrength': 1.1,
          'homeDefenseStrength': 1.1,
          'awayAttackStrength': 0.9,
          'awayDefenseStrength': 0.9,
          'baseGoalRateExpectedHome': 1.45,
          'baseGoalRateExpectedAway': 1.15,
        },
      };

      final extracted = FeatureWhitelist.extract(snapshot);

      expect(extracted['raw.homeGoalsForAverageHome'], 1.5);
      expect(extracted['dataQuality'], 80);
      expect(extracted['realXgAvailable'], true);
      expect(extracted['normalized.baseGoalRateExpectedHome'], 1.45);
    });

    test('missing fields are simply absent, never coerced to 0', () {
      final extracted = FeatureWhitelist.extract(const {});
      expect(extracted.containsKey('raw.homeGoalsForAverageHome'), isFalse);
      expect(extracted.length, 0);
    });
  });
}
