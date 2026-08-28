import 'package:phoenix_backend/src/model_lab/phoenix_global_engine.dart';
import 'package:test/test.dart';

void main() {
  group('PhoenixGlobalEngine', () {
    test('uses one global feature model when the snapshot has team data', () {
      final result = PhoenixGlobalEngine.compute(
        availability: const {
          'homeGoalsForAverageHome': 1.8,
          'awayGoalsAgainstAverageAway': 1.4,
          'awayGoalsForAverageAway': 1.1,
          'homeGoalsAgainstAverageHome': 0.9,
        },
        homeTeamId: 'home',
        awayTeamId: 'away',
        safeHomeFallback: 1.3,
        safeAwayFallback: 1.1,
        leagueAvgHomeGoalsPerGame: 1.4,
        leagueAvgAwayGoalsPerGame: 1.1,
      );

      expect(result.usesGlobalFeatures, isTrue);
      expect(result.source, 'global_goals_v1_conservative');
      expect(result.expectedHome, greaterThan(0.2));
      expect(result.expectedAway, greaterThan(0.2));
    });

    test('keeps a stable fallback if no global feature is available', () {
      final result = PhoenixGlobalEngine.compute(
        availability: const {},
        homeTeamId: 'home',
        awayTeamId: 'away',
        safeHomeFallback: 1.32,
        safeAwayFallback: 1.08,
      );

      expect(result.usesGlobalFeatures, isFalse);
      expect(result.source, 'global_safe_fallback');
      expect(result.expectedHome, 1.32);
      expect(result.expectedAway, 1.08);
    });

    test('anchors an overconfident model to the devigged 1X2 consensus', () {
      final withoutOdds = PhoenixGlobalEngine.compute(
        availability: const {
          'homeGoalsForAverageHome': 1.8,
          'awayGoalsAgainstAverageAway': 1.3,
          'awayGoalsForAverageAway': 1.7,
          'homeGoalsAgainstAverageHome': 1.4,
        },
        homeTeamId: 'home',
        awayTeamId: 'away',
        safeHomeFallback: 1.4,
        safeAwayFallback: 1.2,
      );
      final withOdds = PhoenixGlobalEngine.compute(
        availability: const {
          'homeGoalsForAverageHome': 1.8,
          'awayGoalsAgainstAverageAway': 1.3,
          'awayGoalsForAverageAway': 1.7,
          'homeGoalsAgainstAverageHome': 1.4,
          'oddsData': [
            {
              'bookmakers': [
                {
                  'bets': [
                    {
                      'name': 'Match Winner',
                      'values': [
                        {'value': 'Home', 'odd': '1.35'},
                        {'value': 'Draw', 'odd': '5.20'},
                        {'value': 'Away', 'odd': '8.50'},
                      ],
                    },
                  ],
                },
              ],
            },
          ],
        },
        homeTeamId: 'home',
        awayTeamId: 'away',
        safeHomeFallback: 1.4,
        safeAwayFallback: 1.2,
      );

      expect(withOdds.marketCalibration['applied'], isTrue);
      expect(withOdds.expectedHome, greaterThan(withoutOdds.expectedHome));
      expect(withOdds.expectedAway, lessThan(withoutOdds.expectedAway));
    });
  });
}
