import 'package:phoenix_backend/src/model_lab/match_state.dart';
import 'package:phoenix_backend/src/model_lab/team_strength_engine.dart';
import 'package:test/test.dart';

void main() {
  group('MatchState.fromTeamStrength', () {
    final fit = TeamStrengthFit(
      attack: {'home': 1.4, 'away': 0.8},
      defense: {'home': 0.9, 'away': 1.3},
      homeAdvantage: 1.25,
      iterations: 12,
      converged: true,
    );

    test('expected goals follow the Maher formula', () {
      final s = MatchStateBuilder.fromTeamStrength(
        fit: fit,
        homeTeamId: 'home',
        awayTeamId: 'away',
        leagueBaselineHome: 1.5,
        leagueBaselineAway: 1.2,
        effectiveSampleSize: 30,
        coverage: 0.8,
        eloCoverage: true,
      );
      // home = attack[home] * defense[away] * homeAdv = 1.4 * 1.3 * 1.25
      expect(s.expectedGoalsHome, closeTo(1.4 * 1.3 * 1.25, 1e-9));
      // away = attack[away] * defense[home] = 0.8 * 0.9
      expect(s.expectedGoalsAway, closeTo(0.8 * 0.9, 1e-9));
      expect(s.tempo, closeTo(s.expectedGoalsHome + s.expectedGoalsAway, 1e-9));
      expect(s.uncertainty.usedFallbackBaseline, isFalse);
      expect(s.sourceType, 'team_strength_ipf');
    });

    test('two cold-start teams fall back to homeAdvantage / 1.0 and flag it',
        () {
      final s = MatchStateBuilder.fromTeamStrength(
        fit: fit,
        homeTeamId: 'newA',
        awayTeamId: 'newB',
        leagueBaselineHome: 1.5,
        leagueBaselineAway: 1.2,
        effectiveSampleSize: 0,
        coverage: 0.2,
        eloCoverage: false,
      );
      expect(s.expectedGoalsHome, closeTo(fit.homeAdvantage, 1e-9));
      expect(s.expectedGoalsAway, closeTo(1.0, 1e-9));
      expect(s.uncertainty.usedFallbackBaseline, isTrue);
    });
  });

  group('MatchState.fromGoalRates', () {
    test('keeps the shrunk rate as expectedGoals and derives ratios', () {
      final s = MatchStateBuilder.fromGoalRates(
        expectedGoalsHome: 1.8,
        expectedGoalsAway: 0.9,
        leagueBaselineHome: 1.5,
        leagueBaselineAway: 1.2,
        effectiveSampleSize: 12,
        coverage: 0.7,
        usedFallbackBaseline: false,
      );
      expect(s.expectedGoalsHome, 1.8);
      expect(s.homeAttack, closeTo(1.8 / 1.5, 1e-9));
      expect(s.awayAttack, closeTo(0.9 / 1.2, 1e-9));
      expect(s.sourceType, 'goal_rates_shrunk');
    });

    test('fallback path sets the flag and source type', () {
      final s = MatchStateBuilder.fromGoalRates(
        expectedGoalsHome: 1.5,
        expectedGoalsAway: 1.2,
        leagueBaselineHome: 1.5,
        leagueBaselineAway: 1.2,
        effectiveSampleSize: 0,
        coverage: 0.5,
        usedFallbackBaseline: true,
      );
      expect(s.uncertainty.usedFallbackBaseline, isTrue);
      expect(s.sourceType, 'safe_baseline_fallback');
    });
  });

  group('MatchStateUncertainty.confidence', () {
    test('rises with sample size and coverage, collapses on fallback', () {
      const rich = MatchStateUncertainty(
        effectiveSampleSize: 40,
        coverage: 0.9,
        usedFallbackBaseline: false,
        eloCoverage: true,
      );
      const thin = MatchStateUncertainty(
        effectiveSampleSize: 2,
        coverage: 0.3,
        usedFallbackBaseline: false,
        eloCoverage: false,
      );
      const fallback = MatchStateUncertainty(
        effectiveSampleSize: 40,
        coverage: 0.9,
        usedFallbackBaseline: true,
        eloCoverage: true,
      );
      expect(rich.confidence, greaterThan(thin.confidence));
      expect(fallback.confidence, lessThan(rich.confidence * 0.5));
      expect(rich.confidence, inInclusiveRange(0.0, 1.0));
    });
  });
}
