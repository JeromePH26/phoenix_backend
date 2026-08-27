import 'package:phoenix_backend/src/model_lab/engine_replica.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/weight_config.dart';
import 'package:test/test.dart';

void main() {
  group('EngineReplica.expectedGoals', () {
    test('reproduces the production 50/50 blend at the global baseline', () {
      final goals = EngineReplica.expectedGoals(
        features: const {
          'raw.homeGoalsForAverageHome': 1.6,
          'raw.homeGoalsAgainstAverageHome': 1.0,
          'raw.awayGoalsForAverageAway': 1.0,
          'raw.awayGoalsAgainstAverageAway': 1.4,
        },
        weights: EngineWeightConfig.global,
      );

      // Produktive Formel: home = avg(homeFor, awayAgainst) = avg(1.6, 1.4) = 1.5
      // away = avg(awayFor, homeAgainst) = avg(1.0, 1.0) = 1.0
      expect(goals.home, closeTo(1.5, 1e-9));
      expect(goals.away, closeTo(1.0, 1e-9));
      expect(goals.usedFallback, isFalse);
    });

    // Test 16 (Section 86): Missing Feature Test.
    test('falls back to the neutral baseline instead of treating missing as 0',
        () {
      final goals = EngineReplica.expectedGoals(
        features: const {},
        weights: EngineWeightConfig.global,
      );
      expect(goals.home, 1.35);
      expect(goals.away, 1.10);
      expect(goals.usedFallback, isTrue);
    });

    test('uses the single available component if only one side is known', () {
      final goals = EngineReplica.expectedGoals(
        features: const {'raw.homeGoalsForAverageHome': 2.0},
        weights: EngineWeightConfig.global,
      );
      expect(goals.home, closeTo(2.0, 1e-9));
      expect(goals.usedFallback, isTrue);
    });

    test('clamps extreme goal expectations into the safe range', () {
      final goals = EngineReplica.expectedGoals(
        features: const {
          'raw.homeGoalsForAverageHome': 10.0,
          'raw.homeGoalsAgainstAverageHome': 10.0,
          'raw.awayGoalsForAverageAway': 10.0,
          'raw.awayGoalsAgainstAverageAway': 10.0,
        },
        weights: EngineWeightConfig.global,
      );
      expect(goals.home, lessThanOrEqualTo(3.80));
      expect(goals.away, lessThanOrEqualTo(3.80));
    });

    test('a higher attackWeight shifts the lambda toward the own scoring rate',
        () {
      const features = {
        'raw.homeGoalsForAverageHome': 2.0,
        'raw.homeGoalsAgainstAverageHome': 1.0,
        'raw.awayGoalsForAverageAway': 1.0,
        'raw.awayGoalsAgainstAverageAway': 0.5,
      };
      final low = EngineReplica.expectedGoals(
        features: features,
        weights: const EngineWeightConfig(attackWeight: 0.3),
      );
      final high = EngineReplica.expectedGoals(
        features: features,
        weights: const EngineWeightConfig(attackWeight: 0.7),
      );
      // homeFor(2.0) > awayAgainst(0.5), so a higher attackWeight must pull
      // the home lambda UP toward 2.0.
      expect(high.home, greaterThan(low.home));
    });
  });

  group('EngineReplica.evaluate', () {
    test('1X2 probabilities always sum to ~1', () {
      final output = EngineReplica.evaluate(
        market: LearningMarket.oneXTwo,
        features: const {
          'raw.homeGoalsForAverageHome': 1.6,
          'raw.homeGoalsAgainstAverageHome': 1.0,
          'raw.awayGoalsForAverageAway': 1.0,
          'raw.awayGoalsAgainstAverageAway': 1.4,
        },
        weights: EngineWeightConfig.global,
      );
      final sum = output.classProbabilities.reduce((a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-6));
    });

    test('a heavy home lambda advantage favours a home win', () {
      final output = EngineReplica.evaluate(
        market: LearningMarket.oneXTwo,
        features: const {
          'raw.homeGoalsForAverageHome': 3.0,
          'raw.homeGoalsAgainstAverageHome': 1.0,
          'raw.awayGoalsForAverageAway': 0.3,
          'raw.awayGoalsAgainstAverageAway': 3.0,
        },
        weights: EngineWeightConfig.global,
      );
      // home = avg(3.0, 3.0) = 3.0, away = avg(0.3, 1.0) = 0.65
      expect(output.classProbabilities[0],
          greaterThan(output.classProbabilities[2]));
    });

    test('BTTS yes/no probabilities always sum to ~1', () {
      final output = EngineReplica.evaluate(
        market: LearningMarket.btts,
        features: const {
          'raw.homeGoalsForAverageHome': 1.4,
          'raw.awayGoalsForAverageAway': 1.1,
        },
        weights: EngineWeightConfig.global,
      );
      final sum = output.classProbabilities.reduce((a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-6));
    });

    test('over/under 2.5 probabilities always sum to ~1', () {
      final output = EngineReplica.evaluate(
        market: LearningMarket.overUnder25,
        features: const {
          'raw.homeGoalsForAverageHome': 1.4,
          'raw.awayGoalsForAverageAway': 1.1,
        },
        weights: EngineWeightConfig.global,
      );
      final sum = output.classProbabilities.reduce((a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-6));
    });

    // 2026-08-27: Draw No Bet ist als 2-Klassen-Markt eingefroren (bedingt
    // auf "kein Remis"), nicht mehr byte-identisch zu 1X2 auf 0..2-Skala.
    test('Draw No Bet is 2-class, conditional on no draw, distinct from 1X2',
        () {
      const features = {
        'raw.homeGoalsForAverageHome': 2.0,
        'raw.homeGoalsAgainstAverageHome': 1.0,
        'raw.awayGoalsForAverageAway': 0.8,
        'raw.awayGoalsAgainstAverageAway': 1.6,
      };
      final oneXTwo = EngineReplica.evaluate(
        market: LearningMarket.oneXTwo,
        features: features,
        weights: EngineWeightConfig.global,
      );
      final dnbHome = EngineReplica.evaluate(
        market: LearningMarket.drawNoBetHome,
        features: features,
        weights: EngineWeightConfig.global,
      );
      final dnbAway = EngineReplica.evaluate(
        market: LearningMarket.drawNoBetAway,
        features: features,
        weights: EngineWeightConfig.global,
      );

      expect(dnbHome.classProbabilities, hasLength(2));
      expect(dnbHome.classLabels, ['won', 'lost']);
      expect(dnbHome.classProbabilities.reduce((a, b) => a + b),
          closeTo(1.0, 1e-9));
      // Bedingt auf "kein Remis": P(Heimsieg) / (P(Heimsieg) + P(Auswärtssieg)).
      final expectedWon = oneXTwo.classProbabilities[0] /
          (oneXTwo.classProbabilities[0] + oneXTwo.classProbabilities[2]);
      expect(dnbHome.classProbabilities[0], closeTo(expectedWon, 1e-9));
      expect(dnbAway.classProbabilities[0], closeTo(1 - expectedWon, 1e-9));
      // NICHT die rohe 1X2-Heimwahrscheinlichkeit (die enthält das Remis).
      expect(dnbHome.classProbabilities[0],
          isNot(closeTo(oneXTwo.classProbabilities[0], 1e-6)));
      expect(LearningMarket.drawNoBetHome.isMultiClass, isFalse);
      expect(LearningMarket.oneXTwo.isMultiClass, isTrue);
    });

    test('every public market family has a normalized Champion baseline', () {
      const features = {
        'raw.homeGoalsForAverageHome': 1.6,
        'raw.homeGoalsAgainstAverageHome': 1.0,
        'raw.awayGoalsForAverageAway': 1.1,
        'raw.awayGoalsAgainstAverageAway': 1.4,
      };

      for (final market in LearningMarket.values) {
        final output = EngineReplica.evaluate(
          market: market,
          features: features,
          weights: EngineWeightConfig.global,
        );
        expect(output.classProbabilities, isNotEmpty, reason: market.key);
        expect(
          output.classProbabilities.reduce((a, b) => a + b),
          closeTo(1.0, 1e-6),
          reason: market.key,
        );
      }
    });
  });
}
