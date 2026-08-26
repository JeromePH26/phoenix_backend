import 'package:phoenix_backend/src/model_lab/dixon_coles_engine.dart';
import 'package:phoenix_backend/src/model_lab/engine_replica.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/learning_sample.dart';
import 'package:phoenix_backend/src/model_lab/weight_config.dart';
import 'package:test/test.dart';

// PHÖNIX Engine-Umbau, Phase 1 Spur A (Plan "wild-cuddling-hoare", 2026-08-26).
LearningSample _sample({required Map<String, Object?> features}) {
  return LearningSample(
    fixtureId: 'test-fixture',
    leagueId: '39',
    kickoff: DateTime.utc(2026, 1, 1),
    snapshotCreatedAt: DateTime.utc(2025, 12, 31),
    dataQuality: 80,
    features: features,
    homeGoals: 1,
    awayGoals: 1,
  );
}

const _wellKnownFeatures = {
  'raw.homeGoalsForAverageHome': 1.6,
  'raw.homeGoalsAgainstAverageHome': 1.0,
  'raw.awayGoalsForAverageAway': 1.0,
  'raw.awayGoalsAgainstAverageAway': 1.4,
};

void main() {
  group('DixonColesEngine.configHash', () {
    test('is deterministic for the same rho', () {
      expect(DixonColesEngine.configHash(-0.05), DixonColesEngine.configHash(-0.05));
    });

    test('differs between different rho values', () {
      expect(
        DixonColesEngine.configHash(-0.05),
        isNot(DixonColesEngine.configHash(-0.10)),
      );
    });
  });

  group('ModelEngine.dixonColes', () {
    test('toJson exposes the engine version and rho', () {
      final json = const ModelEngine.dixonColes(-0.05).toJson();
      expect(json['engineVersion'], DixonColesEngine.version);
      expect(json['rho'], -0.05);
    });

    test('evaluate() never returns null (same neutral-fallback guarantee '
        'as the plain attackWeightBlend engine it reuses)', () {
      const engine = ModelEngine.dixonColes(-0.05);
      final output = engine.evaluate(
        market: LearningMarket.oneXTwo,
        sample: _sample(features: const {}),
      );
      expect(output, isNotNull);
      expect(output!.usedFallbackBaseline, isTrue);
    });

    test('rho: 0.0 produces identical probabilities to the plain '
        'attackWeightBlend global-baseline engine (regression anchor - the '
        'new challenger family must not silently change existing behaviour '
        'when its correlation knob is off)', () {
      const dixonColesControl = ModelEngine.dixonColes(0.0);
      final baseline = ModelEngine.attackWeightBlend(EngineWeightConfig.global);
      for (final market in LearningMarket.values) {
        final a = dixonColesControl.evaluate(
          market: market,
          sample: _sample(features: _wellKnownFeatures),
        )!;
        final b = baseline.evaluate(
          market: market,
          sample: _sample(features: _wellKnownFeatures),
        )!;
        for (var i = 0; i < a.classProbabilities.length; i++) {
          expect(a.classProbabilities[i], closeTo(b.classProbabilities[i], 1e-6));
        }
      }
    });

    test('every derived market stays internally consistent (probabilities '
        'sum to 1) with a real, non-zero rho', () {
      const engine = ModelEngine.dixonColes(-0.10);
      final sample = _sample(features: _wellKnownFeatures);
      for (final market in LearningMarket.values) {
        final output = engine.evaluate(market: market, sample: sample)!;
        final sum = output.classProbabilities.fold(0.0, (a, b) => a + b);
        expect(sum, closeTo(1.0, 1e-6), reason: 'market: ${market.key}');
      }
    });
  });
}
