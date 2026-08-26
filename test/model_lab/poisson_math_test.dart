import 'package:phoenix_backend/src/model_lab/poisson_math.dart';
import 'package:test/test.dart';

// PHÖNIX Engine-Umbau, Phase 1 Spur A (Plan "wild-cuddling-hoare", 2026-08-26):
// Dixon-Coles-Korrelationsausgleich als neue Model-Lab-Engine-Familie.
// Diese Tests sichern den wichtigsten Regressionsanker ab: bei rho == 0.0
// muss sich die Engine exakt wie die bisherige, unabhängige Poisson-Annahme
// verhalten - die produktive Simulation und alle bestehenden Model-Lab-
// Champions/Challenger bleiben unverändert, solange rho nicht explizit
// gesetzt wird.
void main() {
  group('PoissonMath.dixonColesTau', () {
    test('rho == 0.0 is 1.0 for every scoreline (no correction, control arm)', () {
      const cases = [(0, 0), (0, 1), (1, 0), (1, 1), (2, 0), (0, 2), (2, 2)];
      for (final (h, a) in cases) {
        expect(
          PoissonMath.dixonColesTau(
            homeGoals: h,
            awayGoals: a,
            homeLambda: 1.5,
            awayLambda: 1.1,
            rho: 0.0,
          ),
          1.0,
        );
      }
    });

    test('scorelines above 1:1 are always unadjusted regardless of rho', () {
      for (final rho in [-0.15, -0.05, 0.05]) {
        expect(
          PoissonMath.dixonColesTau(
            homeGoals: 2,
            awayGoals: 3,
            homeLambda: 1.5,
            awayLambda: 1.1,
            rho: rho,
          ),
          1.0,
        );
      }
    });

    test('a typical negative rho dampens 1:0/0:1 and boosts 0:0/1:1 '
        '(the empirically observed low-score correlation in football)', () {
      const homeLambda = 1.5;
      const awayLambda = 1.1;
      const rho = -0.1;

      final tau00 = PoissonMath.dixonColesTau(
        homeGoals: 0,
        awayGoals: 0,
        homeLambda: homeLambda,
        awayLambda: awayLambda,
        rho: rho,
      );
      final tau11 = PoissonMath.dixonColesTau(
        homeGoals: 1,
        awayGoals: 1,
        homeLambda: homeLambda,
        awayLambda: awayLambda,
        rho: rho,
      );
      final tau10 = PoissonMath.dixonColesTau(
        homeGoals: 1,
        awayGoals: 0,
        homeLambda: homeLambda,
        awayLambda: awayLambda,
        rho: rho,
      );
      final tau01 = PoissonMath.dixonColesTau(
        homeGoals: 0,
        awayGoals: 1,
        homeLambda: homeLambda,
        awayLambda: awayLambda,
        rho: rho,
      );

      expect(tau00, greaterThan(1.0));
      expect(tau11, greaterThan(1.0));
      expect(tau10, lessThan(1.0));
      expect(tau01, lessThan(1.0));
    });
  });

  group('PoissonMath.scoreMatrix', () {
    test('rho: 0.0 reproduces the independent-Poisson joint distribution '
        '(regression anchor for the current production behaviour)', () {
      // scoreMatrix renormalizes the full 0-12 grid to sum to exactly 1.0,
      // so cells differ from the raw pmf product by the (tiny) truncated-tail
      // correction - hence a looser tolerance than the sum-to-1 checks below.
      final matrix = PoissonMath.scoreMatrix(homeLambda: 1.7, awayLambda: 1.2);
      for (var h = 0; h <= 3; h++) {
        for (var a = 0; a <= 3; a++) {
          final expected =
              PoissonMath.pmf(1.7, h) * PoissonMath.pmf(1.2, a);
          expect(matrix[h][a], closeTo(expected, 1e-6));
        }
      }
    });

    test('always sums to 1.0, with or without correlation', () {
      for (final rho in [0.0, -0.05, -0.1]) {
        final matrix = PoissonMath.scoreMatrix(
          homeLambda: 1.7,
          awayLambda: 1.2,
          rho: rho,
        );
        var sum = 0.0;
        for (final row in matrix) {
          for (final cell in row) {
            sum += cell;
          }
        }
        expect(sum, closeTo(1.0, 1e-9));
      }
    });

    test('never produces a negative probability even for an aggressive rho', () {
      final matrix = PoissonMath.scoreMatrix(
        homeLambda: 0.3,
        awayLambda: 0.3,
        rho: -0.9,
      );
      for (final row in matrix) {
        for (final cell in row) {
          expect(cell, greaterThanOrEqualTo(0.0));
        }
      }
    });
  });

  group('PoissonMath market probabilities at rho: 0.0 match pre-Dixon-Coles '
      'behaviour exactly', () {
    test('matchResultProbabilities', () {
      final result = PoissonMath.matchResultProbabilities(1.7, 1.2);
      expect(result.home + result.draw + result.away, closeTo(1.0, 1e-9));
      expect(result.home, greaterThan(result.away));
    });

    test('overUnderProbabilities', () {
      final result = PoissonMath.overUnderProbabilities(1.7, 1.2, 2.5);
      expect(result.over + result.under, closeTo(1.0, 1e-9));
    });

    test('bttsProbabilities matches the old independence shortcut formula '
        '(1 - P(home=0)) * (1 - P(away=0))', () {
      const homeLambda = 1.7;
      const awayLambda = 1.2;
      final result = PoissonMath.bttsProbabilities(homeLambda, awayLambda);
      final expectedYes = (1 - PoissonMath.pmf(homeLambda, 0)) *
          (1 - PoissonMath.pmf(awayLambda, 0));
      expect(result.yes, closeTo(expectedYes, 1e-6));
      expect(result.yes + result.no, closeTo(1.0, 1e-9));
    });
  });

  group('PoissonMath market probabilities with rho != 0.0 stay internally '
      'consistent', () {
    test('matchResultProbabilities still sums to 1 and BTTS still '
        'complements to 1 under correlation', () {
      const rho = -0.1;
      final match =
          PoissonMath.matchResultProbabilities(1.4, 1.0, rho: rho);
      expect(match.home + match.draw + match.away, closeTo(1.0, 1e-9));

      final btts = PoissonMath.bttsProbabilities(1.4, 1.0, rho: rho);
      expect(btts.yes + btts.no, closeTo(1.0, 1e-9));

      final overUnder =
          PoissonMath.overUnderProbabilities(1.4, 1.0, 2.5, rho: rho);
      expect(overUnder.over + overUnder.under, closeTo(1.0, 1e-9));
    });

    test('a typical negative rho measurably shifts BTTS-yes away from the '
        'independent-Poisson value (tau boosts 0:0/1:1, dampens 1:0/0:1 - '
        'the net BTTS effect is not simply "less BTTS", just different)', () {
      const homeLambda = 1.1;
      const awayLambda = 0.9;
      final independent = PoissonMath.bttsProbabilities(homeLambda, awayLambda);
      final correlated =
          PoissonMath.bttsProbabilities(homeLambda, awayLambda, rho: -0.1);
      expect(correlated.yes, isNot(closeTo(independent.yes, 1e-6)));
    });
  });
}
