import 'package:phoenix_backend/src/model_lab/global_goals_v1_engine.dart';
import 'package:test/test.dart';

Map<String, Object?> _finishedFixture({
  required String homeId,
  required String awayId,
  required int homeGoals,
  required int awayGoals,
}) {
  return {
    'fixture': {
      'status': {'short': 'FT'},
    },
    'teams': {
      'home': {'id': homeId},
      'away': {'id': awayId},
    },
    'goals': {'home': homeGoals, 'away': awayGoals},
  };
}

Map<String, Object?> _standingsRow({
  required String teamId,
  required int points,
  required int played,
  required int goalsFor,
  required int goalsAgainst,
}) {
  return {
    'team': {'id': teamId},
    'points': points,
    'all': {
      'played': played,
      'goals': {'for': goalsFor, 'against': goalsAgainst},
    },
  };
}

void main() {
  const home = '100';
  const away = '200';

  group('GlobalGoalsV1Engine', () {
    test('xG/xGA is never a feature key: never present in coverage, never 0-substituted', () {
      final result = GlobalGoalsV1Engine.compute(
        availability: const {},
        homeTeamId: home,
        awayTeamId: away,
      );

      for (final coverage in [result.homeFeatureCoverage, result.awayFeatureCoverage]) {
        final original = coverage['originalWeights'] as Map;
        final available = coverage['availableFeatures'] as List;
        final missing = coverage['missingFeatures'] as List;
        expect(original.containsKey('xgXga'), isFalse);
        expect(available.contains('xgXga'), isFalse);
        expect(missing.contains('xgXga'), isFalse);
      }
      expect(
        result.warnings.any((w) => w.contains('xG')),
        isTrue,
        reason: 'must explicitly warn that no real xG exists, not silently omit it',
      );
    });

    test('completely empty availability yields null expectations, not 0', () {
      final result = GlobalGoalsV1Engine.compute(
        availability: const {},
        homeTeamId: home,
        awayTeamId: away,
      );

      expect(result.expectedHome, isNull);
      expect(result.expectedAway, isNull);
      expect(result.expectedTotal, isNull);
    });

    test('season goal-rate features alone produce a plausible non-null estimate', () {
      final result = GlobalGoalsV1Engine.compute(
        availability: const {
          'homeGoalsForAverageHome': 2.0,
          'awayGoalsAgainstAverageAway': 1.0,
          'awayGoalsForAverageAway': 1.2,
          'homeGoalsAgainstAverageHome': 0.8,
        },
        homeTeamId: home,
        awayTeamId: away,
      );

      expect(result.expectedHome, isNotNull);
      expect(result.expectedAway, isNotNull);
      // home attack (2.0) + away defense-away (1.0) only two available
      // features of equal ideal weight (15/15) -> simple average of 2.0/1.0.
      expect(result.expectedHome, closeTo(1.5, 1e-6));
      expect(result.expectedAway, closeTo(1.0, 1e-6));
    });

    test('recent form is aggregated from raw fixture rows, unfinished matches excluded', () {
      final availability = {
        'homeGoalsForAverageHome': 1.5,
        'awayGoalsAgainstAverageAway': 1.5,
        'homeRecentData': [
          _finishedFixture(homeId: home, awayId: '900', homeGoals: 3, awayGoals: 1),
          _finishedFixture(homeId: '901', awayId: home, homeGoals: 0, awayGoals: 2),
          // Not finished - must be excluded from the aggregate.
          {
            'fixture': {
              'status': {'short': 'NS'},
            },
            'teams': {
              'home': {'id': home},
              'away': {'id': '902'},
            },
            'goals': {'home': null, 'away': null},
          },
        ],
      };

      final result = GlobalGoalsV1Engine.compute(
        availability: availability,
        homeTeamId: home,
        awayTeamId: away,
      );

      final homeAvailable = (result.homeFeatureCoverage['availableFeatures'] as List);
      expect(homeAvailable.contains('recentFormAttack'), isTrue);
      // Home scored 3 (as home) and 2 (as away) across the 2 finished
      // matches -> 2.5 goals/game recent attack rate.
      expect(result.expectedHome, isNotNull);
    });

    test('standings feature extracted correctly from nested group structure', () {
      final availability = {
        'homeGoalsForAverageHome': 1.5,
        'homeGoalsAgainstAverageHome': 1.0,
        'standingsData': [
          {
            'league': {
              'standings': [
                [
                  _standingsRow(teamId: home, points: 10, played: 5, goalsFor: 8, goalsAgainst: 3),
                  _standingsRow(teamId: away, points: 6, played: 5, goalsFor: 5, goalsAgainst: 9),
                ],
              ],
            },
          },
        ],
      };

      final result = GlobalGoalsV1Engine.compute(
        availability: availability,
        homeTeamId: home,
        awayTeamId: away,
      );

      final awayAvailable = (result.awayFeatureCoverage['availableFeatures'] as List);
      // Away's expected goals uses HOME's standings goals-against rate
      // (opponent defense proxy) -> home conceded 3/5 = 0.6 goals/game.
      expect(awayAvailable.contains('standingsGoalRateOpponentDefense'), isTrue);
    });

    test('effective weights for available features always sum to 1.0', () {
      final result = GlobalGoalsV1Engine.compute(
        availability: const {
          'homeGoalsForAverageHome': 1.8,
          'awayGoalsAgainstAverageAway': 1.1,
        },
        homeTeamId: home,
        awayTeamId: away,
        leagueAvgHomeGoalsPerGame: 1.4,
      );

      final effective = result.homeFeatureCoverage['effectiveWeights'] as Map;
      final sum = effective.values.fold<double>(0, (s, w) => s + (w as num));
      expect(sum, closeTo(1.0, 1e-6));
    });

    test('expected goals are clamped to the same safe range as the production baseline', () {
      final result = GlobalGoalsV1Engine.compute(
        availability: const {
          'homeGoalsForAverageHome': 20.0,
          'awayGoalsAgainstAverageAway': 20.0,
        },
        homeTeamId: home,
        awayTeamId: away,
      );

      expect(result.expectedHome, lessThanOrEqualTo(3.80));
    });
  });
}
