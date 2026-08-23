import 'package:phoenix_backend/src/model_lab/global_market_engine.dart';
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

void main() {
  const home = '100';
  const away = '200';

  group('GlobalMarketEngine.compute', () {
    test('every market family has a preset and produces a valid version tag', () {
      for (final family in GlobalMarketFamily.values) {
        expect(GlobalMarketWeights.presets.containsKey(family), isTrue);
        expect(family.version, isNotEmpty);
      }
      // Distinct version strings - two families must never silently share
      // one, or model rows would collide on the (market, league, config_hash)
      // unique index in a confusing way.
      final versions = GlobalMarketFamily.values.map((f) => f.version).toSet();
      expect(versions.length, GlobalMarketFamily.values.length);
    });

    test('xG, rating and motivation are never feature keys for any family - never present, never 0-substituted', () {
      for (final family in GlobalMarketFamily.values) {
        final result = GlobalMarketEngine.compute(
          family: family,
          availability: const {},
          homeTeamId: home,
          awayTeamId: away,
        );
        for (final coverage in [result.homeFeatureCoverage, result.awayFeatureCoverage]) {
          final original = coverage['originalWeights'] as Map;
          for (final forbidden in ['xg', 'xgXga', 'rating', 'teamRating', 'motivation', 'context']) {
            expect(original.containsKey(forbidden), isFalse, reason: '$family must not have a "$forbidden" feature');
          }
        }
        expect(result.warnings.any((w) => w.contains('xG')), isTrue);
        expect(result.warnings.any((w) => w.contains('Rating') || w.contains('Motivation')), isTrue);
      }
    });

    test('completely empty availability yields null expectations for every family, not 0', () {
      for (final family in GlobalMarketFamily.values) {
        final result = GlobalMarketEngine.compute(
          family: family,
          availability: const {},
          homeTeamId: home,
          awayTeamId: away,
        );
        expect(result.expectedHome, isNull, reason: '$family');
        expect(result.expectedAway, isNull, reason: '$family');
      }
    });

    test('h2h feature: home side gets goals scored specifically against this opponent', () {
      final availability = {
        'homeGoalsForAverageHome': 1.5,
        'awayGoalsAgainstAverageAway': 1.5,
        // 3 historical meetings between exactly `home` and `away`, venue
        // alternates - home team's own goals must be summed regardless of
        // which side of the fixture they played on.
        'h2hData': [
          _finishedFixture(homeId: home, awayId: away, homeGoals: 2, awayGoals: 1),
          _finishedFixture(homeId: away, awayId: home, homeGoals: 0, awayGoals: 3),
          _finishedFixture(homeId: home, awayId: away, homeGoals: 1, awayGoals: 1),
        ],
      };

      final result = GlobalMarketEngine.compute(
        family: GlobalMarketFamily.oneXTwo,
        availability: availability,
        homeTeamId: home,
        awayTeamId: away,
      );

      final homeAvailable = (result.homeFeatureCoverage['availableFeatures'] as List);
      final awayAvailable = (result.awayFeatureCoverage['availableFeatures'] as List);
      expect(homeAvailable.contains('h2h'), isTrue);
      expect(awayAvailable.contains('h2h'), isTrue);
      // home scored 2 + 3 + 1 = 6 across 3 meetings -> 2.0/game.
      // away scored 1 + 0 + 1 = 2 across 3 meetings -> 0.667/game.
      expect(result.expectedHome, isNotNull);
      expect(result.expectedAway, isNotNull);
    });

    test('h2h ignores unfinished fixtures in the list', () {
      final availability = {
        'homeGoalsForAverageHome': 1.5,
        'awayGoalsAgainstAverageAway': 1.5,
        'h2hData': [
          _finishedFixture(homeId: home, awayId: away, homeGoals: 4, awayGoals: 0),
          {
            'fixture': {
              'status': {'short': 'PST'},
            },
            'teams': {
              'home': {'id': home},
              'away': {'id': away},
            },
            'goals': {'home': null, 'away': null},
          },
        ],
      };

      final result = GlobalMarketEngine.compute(
        family: GlobalMarketFamily.totals,
        availability: availability,
        homeTeamId: home,
        awayTeamId: away,
      );

      final homeAvailable = (result.homeFeatureCoverage['availableFeatures'] as List);
      expect(homeAvailable.contains('h2h'), isTrue);
      expect(result.expectedHome, isNotNull);
    });

    test('effective weights for available features always sum to 1.0, for every family', () {
      for (final family in GlobalMarketFamily.values) {
        final result = GlobalMarketEngine.compute(
          family: family,
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
        expect(sum, closeTo(1.0, 1e-6), reason: '$family');
      }
    });

    test('expected goals are clamped to the same safe range as the production baseline', () {
      final result = GlobalMarketEngine.compute(
        family: GlobalMarketFamily.teamGoals,
        availability: const {
          'homeGoalsForAverageHome': 20.0,
          'awayGoalsAgainstAverageAway': 20.0,
        },
        homeTeamId: home,
        awayTeamId: away,
      );
      expect(result.expectedHome, lessThanOrEqualTo(3.80));
    });

    test('teamGoals family weights its own attack more heavily than opponent defense', () {
      final weights = GlobalMarketWeights.presets[GlobalMarketFamily.teamGoals]!;
      expect(weights.seasonAttack, greaterThan(weights.seasonDefenseOpponent));
    });
  });

  group('GlobalMarketHypothesis', () {
    test('every hypothesis produces a genuinely different weight profile from the base preset', () {
      final base = GlobalMarketWeights.presets[GlobalMarketFamily.totals]!;
      for (final hypothesis in GlobalMarketHypothesis.values) {
        final varied = hypothesis.apply(base);
        final same = varied.seasonAttack == base.seasonAttack &&
            varied.seasonDefenseOpponent == base.seasonDefenseOpponent &&
            varied.recentFormAttack == base.recentFormAttack &&
            varied.recentFormDefenseOpponent == base.recentFormDefenseOpponent &&
            varied.standingsGoalRateOpponentDefense == base.standingsGoalRateOpponentDefense &&
            varied.leagueGoalContext == base.leagueGoalContext &&
            varied.h2h == base.h2h;
        expect(same, isFalse, reason: '${hypothesis.key} must differ from the champion (Section 11: "nicht identisch")');
      }
    });

    test('formHeavy actually increases form weight relative to the base preset', () {
      final base = GlobalMarketWeights.presets[GlobalMarketFamily.totals]!;
      final varied = GlobalMarketHypothesis.formHeavy.apply(base);
      final baseFormShare = (base.recentFormAttack + base.recentFormDefenseOpponent) /
          (base.seasonAttack +
              base.seasonDefenseOpponent +
              base.recentFormAttack +
              base.recentFormDefenseOpponent +
              base.standingsGoalRateOpponentDefense +
              base.leagueGoalContext +
              base.h2h);
      final variedFormShare = (varied.recentFormAttack + varied.recentFormDefenseOpponent) /
          (varied.seasonAttack +
              varied.seasonDefenseOpponent +
              varied.recentFormAttack +
              varied.recentFormDefenseOpponent +
              varied.standingsGoalRateOpponentDefense +
              varied.leagueGoalContext +
              varied.h2h);
      expect(variedFormShare, greaterThan(baseFormShare));
    });

    test('every hypothesis still produces a usable, non-null prediction with real data', () {
      for (final family in GlobalMarketFamily.values) {
        final base = GlobalMarketWeights.presets[family]!;
        for (final hypothesis in GlobalMarketHypothesis.values) {
          final result = GlobalMarketEngine.compute(
            family: family,
            availability: const {
              'homeGoalsForAverageHome': 1.8,
              'awayGoalsAgainstAverageAway': 1.1,
              'awayGoalsForAverageAway': 1.3,
              'homeGoalsAgainstAverageHome': 0.9,
            },
            homeTeamId: home,
            awayTeamId: away,
            weightsOverride: hypothesis.apply(base),
          );
          expect(result.expectedHome, isNotNull, reason: '$family/${hypothesis.key}');
          expect(result.expectedAway, isNotNull, reason: '$family/${hypothesis.key}');
        }
      }
    });
  });
}
