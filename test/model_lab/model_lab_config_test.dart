import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:test/test.dart';

void main() {
  group('ModelLabConfig.fromEnvironment defaults', () {
    // Test 13 (Section 86): Promotion Disabled Test (Default-Teil - der
    // serverseitige Reject-Pfad selbst wird in model_lab_routes.dart direkt
    // gegen dieses Flag geprüft).
    test('promotion is disabled by default without any env var set', () {
      final config = ModelLabConfig.fromEnvironment();
      expect(config.promotionEnabled, isFalse);
    });

    test('data quality minimum defaults to 40 (Section 23; lowered 2026-08-27)',
        () {
      final config = ModelLabConfig.fromEnvironment();
      expect(config.minDataQuality, 40);
    });

    test('learning day defaults to Tuesday (Section 45)', () {
      final config = ModelLabConfig.fromEnvironment();
      expect(config.learningRunWeekday, DateTime.tuesday);
    });

    test('monthly review defaults to Wednesday within the first 7 days (Section 48/49)', () {
      final config = ModelLabConfig.fromEnvironment();
      expect(config.monthlyReviewWeekday, DateTime.wednesday);
      expect(config.monthlyReviewMaxDayOfMonth, 7);
    });

    test('attack weight grid stays within the configured bounds by default', () {
      final config = ModelLabConfig.fromEnvironment();
      for (final weight in config.attackWeightGrid) {
        expect(weight, greaterThanOrEqualTo(config.attackWeightMin));
        expect(weight, lessThanOrEqualTo(config.attackWeightMax));
      }
    });

    test('sample-size safety minimums are all positive', () {
      final config = ModelLabConfig.fromEnvironment();
      expect(config.minHoldoutSample, greaterThan(0));
      expect(config.minValidationSample, greaterThan(0));
      expect(config.minPromotionSample, greaterThan(0));
    });
  });
}
