import 'package:phoenix_backend/src/model_lab/feature_renormalization.dart';
import 'package:test/test.dart';

void main() {
  group('combineWeightedFeatures', () {
    test('all features available: effective weights equal original weights', () {
      final result = combineWeightedFeatures(const [
        WeightedFeature(key: 'a', idealWeight: 30, value: 1.0),
        WeightedFeature(key: 'b', idealWeight: 20, value: 2.0),
        WeightedFeature(key: 'c', idealWeight: 50, value: 3.0),
      ]);

      expect(result.missingFeatureKeys, isEmpty);
      expect(result.availableFeatureKeys, ['a', 'b', 'c']);
      expect(result.effectiveWeights['a'], closeTo(0.30, 1e-9));
      expect(result.effectiveWeights['b'], closeTo(0.20, 1e-9));
      expect(result.effectiveWeights['c'], closeTo(0.50, 1e-9));
      expect(result.value, closeTo(1.0 * 0.30 + 2.0 * 0.20 + 3.0 * 0.50, 1e-9));
    });

    test('missing feature is removed, not treated as 0', () {
      final result = combineWeightedFeatures(const [
        WeightedFeature(key: 'a', idealWeight: 30, value: 2.0),
        WeightedFeature(key: 'b', idealWeight: 70, value: null),
      ]);

      // If the missing feature were silently 0, the value would be
      // 2.0 * 0.30 + 0 * 0.70 = 0.6. It must instead be exactly 2.0, since
      // 'a' becomes the only (100%) available feature.
      expect(result.value, closeTo(2.0, 1e-9));
      expect(result.missingFeatureKeys, ['b']);
      expect(result.availableFeatureKeys, ['a']);
    });

    test('effective weights of available features always sum to exactly 1.0', () {
      final result = combineWeightedFeatures(const [
        WeightedFeature(key: 'a', idealWeight: 15, value: 1.0),
        WeightedFeature(key: 'b', idealWeight: 15, value: null),
        WeightedFeature(key: 'c', idealWeight: 8, value: 2.0),
        WeightedFeature(key: 'd', idealWeight: 8, value: null),
        WeightedFeature(key: 'e', idealWeight: 8, value: 3.0),
        WeightedFeature(key: 'f', idealWeight: 5, value: 4.0),
      ]);

      final sum = result.effectiveWeights.values.fold<double>(0, (s, w) => s + w);
      expect(sum, closeTo(1.0, 1e-9));
      expect(result.missingFeatureKeys, ['b', 'd']);
    });

    test('original weights (documentary) always sum to exactly 1.0 regardless of availability', () {
      final result = combineWeightedFeatures(const [
        WeightedFeature(key: 'a', idealWeight: 30, value: null),
        WeightedFeature(key: 'b', idealWeight: 70, value: null),
      ]);

      final sum = result.originalWeights.values.fold<double>(0, (s, w) => s + w);
      expect(sum, closeTo(1.0, 1e-9));
    });

    test('all features missing yields null value, never 0', () {
      final result = combineWeightedFeatures(const [
        WeightedFeature(key: 'a', idealWeight: 50, value: null),
        WeightedFeature(key: 'b', idealWeight: 50, value: null),
      ]);

      expect(result.value, isNull);
      expect(result.availableFeatureKeys, isEmpty);
      expect(result.missingFeatureKeys, ['a', 'b']);
    });

    test('single available feature gets 100% effective weight', () {
      final result = combineWeightedFeatures(const [
        WeightedFeature(key: 'a', idealWeight: 15, value: 7.0),
        WeightedFeature(key: 'b', idealWeight: 85, value: null),
      ]);

      expect(result.effectiveWeights['a'], closeTo(1.0, 1e-9));
      expect(result.value, closeTo(7.0, 1e-9));
    });
  });
}
