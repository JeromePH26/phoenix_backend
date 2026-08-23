import 'package:phoenix_backend/src/model_lab/engine_replica.dart';
import 'package:phoenix_backend/src/model_lab/global_market_engine.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/learning_sample.dart';
import 'package:phoenix_backend/src/model_lab/weight_config.dart';
import 'package:test/test.dart';

LearningSample _sample({
  Map<String, Object?>? globalMarketAvailability,
  String? globalMarketHomeTeamId,
  String? globalMarketAwayTeamId,
}) {
  final kickoff = DateTime.utc(2026, 1, 1);
  return LearningSample(
    fixtureId: 'f1',
    leagueId: '78',
    kickoff: kickoff,
    snapshotCreatedAt: kickoff.subtract(const Duration(hours: 6)),
    dataQuality: 80,
    features: const {
      'raw.homeGoalsForAverageHome': 1.5,
      'raw.homeGoalsAgainstAverageHome': 1.1,
      'raw.awayGoalsForAverageAway': 1.0,
      'raw.awayGoalsAgainstAverageAway': 1.3,
    },
    homeGoals: 2,
    awayGoals: 1,
    globalMarketAvailability: globalMarketAvailability,
    globalMarketHomeTeamId: globalMarketHomeTeamId,
    globalMarketAwayTeamId: globalMarketAwayTeamId,
  );
}

void main() {
  group('ModelEngine.globalMarket', () {
    test('returns null when the sample has no GlobalMarketEngine data', () {
      final engine = ModelEngine.globalMarket(GlobalMarketFamily.oneXTwo);
      final output = engine.evaluate(market: LearningMarket.oneXTwo, sample: _sample());
      expect(output, isNull);
    });

    test('evaluates using the base preset when no hypothesis is given', () {
      final engine = ModelEngine.globalMarket(GlobalMarketFamily.oneXTwo);
      final sample = _sample(
        globalMarketAvailability: const {
          'homeGoalsForAverageHome': 1.8,
          'awayGoalsAgainstAverageAway': 1.1,
          'awayGoalsForAverageAway': 1.0,
          'homeGoalsAgainstAverageHome': 1.2,
        },
        globalMarketHomeTeamId: '100',
        globalMarketAwayTeamId: '200',
      );
      final output = engine.evaluate(market: LearningMarket.oneXTwo, sample: sample);
      expect(output, isNotNull);
      expect(output!.classProbabilities.length, 3);
      final sum = output.classProbabilities.reduce((a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-6));
    });

    test('a hypothesis variant produces a different prediction than the base preset', () {
      // Season numbers point one way (high home attack), the other real
      // signals point the opposite way (weak recent form, weak standings) -
      // only then does shifting weight between them actually move the
      // prediction. If only one feature is available, every hypothesis
      // renormalizes to the same 100% on it regardless of its raw factor.
      final sample = _sample(
        globalMarketAvailability: {
          'homeGoalsForAverageHome': 2.4,
          'awayGoalsAgainstAverageAway': 0.6,
          'awayGoalsForAverageAway': 0.6,
          'homeGoalsAgainstAverageHome': 2.4,
          'homeRecentData': [
            {
              'fixture': {'status': {'short': 'FT'}},
              'teams': {
                'home': {'id': '100'},
                'away': {'id': '999'},
              },
              'goals': {'home': 0, 'away': 3},
            },
          ],
        },
        globalMarketHomeTeamId: '100',
        globalMarketAwayTeamId: '200',
      );

      final base = ModelEngine.globalMarket(GlobalMarketFamily.totals);
      final formHeavy = ModelEngine.globalMarket(
        GlobalMarketFamily.totals,
        hypothesis: GlobalMarketHypothesis.attackDefenseHeavy,
      );

      final baseOutput = base.evaluate(market: LearningMarket.overUnder25, sample: sample);
      final variantOutput = formHeavy.evaluate(market: LearningMarket.overUnder25, sample: sample);
      expect(baseOutput, isNotNull);
      expect(variantOutput, isNotNull);
      // attackDefenseHeavy pushes weight fully onto the extreme
      // season attack/defense numbers above -> must shift the prediction.
      expect(baseOutput!.classProbabilities[0], isNot(closeTo(variantOutput!.classProbabilities[0], 1e-9)));
    });

    test('toJson tags the engine version and, when set, the hypothesis key', () {
      final base = ModelEngine.globalMarket(GlobalMarketFamily.btts);
      expect(base.toJson(), {'engineVersion': GlobalMarketFamily.btts.version});

      final withHypothesis = ModelEngine.globalMarket(
        GlobalMarketFamily.btts,
        hypothesis: GlobalMarketHypothesis.formHeavy,
      );
      expect(withHypothesis.toJson(), {
        'engineVersion': GlobalMarketFamily.btts.version,
        'hypothesis': GlobalMarketHypothesis.formHeavy.key,
      });
    });

    test('attackWeightBlend and globalGoalsV1 engines are unaffected by the new variant', () {
      final attackWeight = const ModelEngine.attackWeightBlend(EngineWeightConfig.global);
      final output = attackWeight.evaluate(market: LearningMarket.oneXTwo, sample: _sample());
      expect(output, isNotNull); // attackWeight always has a fallback, never null.

      final goalsV1 = const ModelEngine.globalGoalsV1();
      final goalsV1Output = goalsV1.evaluate(market: LearningMarket.oneXTwo, sample: _sample());
      expect(goalsV1Output, isNull); // no globalGoalsV1ExpectedHome/Away on this sample.
    });
  });
}
