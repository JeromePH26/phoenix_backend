import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/model_lab/model_lab_schedule.dart';
import 'package:test/test.dart';

ModelLabConfig _config() => ModelLabConfig(
  promotionEnabled: false,
  minDataQuality: 50,
  minLearningEligibleSamples: 50,
  leagueAdaptationSampleThreshold: 100,
  strongerAdaptationSampleThreshold: 300,
  fullLeagueEngineSampleThreshold: 600,
  shrinkageK: 150,
  attackWeightMin: 0.30,
  attackWeightMax: 0.70,
  attackWeightGrid: const [0.40, 0.45, 0.55, 0.60],
  holdoutFraction: 0.20,
  walkForwardMinTrainingWindow: 60,
  walkForwardStepSize: 20,
  minHoldoutSample: 40,
  minValidationSample: 40,
  minShadowSample: 30,
  minPromotionSample: 120,
  bootstrapResamples: 500,
  bootstrapConfidenceLevel: 0.95,
  calibrationMinBucketSample: 20,
  redCardEarlyMinute: 30,
  redCardLateMinute: 75,
  learningRunWeekday: DateTime.tuesday,
  learningRunHourBerlin: 4,
  monthlyReviewWeekday: DateTime.wednesday,
  monthlyReviewMaxDayOfMonth: 7,
  maxChallengersPerLeagueMarket: 4,
  staleLockMinutes: 180,
);

DateTime _firstWeekdayOfMonth(int year, int month, int weekday) {
  var day = DateTime(year, month, 1);
  while (day.weekday != weekday) {
    day = day.add(const Duration(days: 1));
  }
  return day;
}

void main() {
  group('ModelLabSchedule.isFirstWednesday', () {
    // Test 14 (Section 86): First Wednesday Test.
    test('the first Wednesday of the month is a real review day', () {
      final firstWednesday = _firstWeekdayOfMonth(2026, 9, DateTime.wednesday);
      expect(ModelLabSchedule.isFirstWednesday(firstWednesday, _config()), isTrue);
    });

    test('the second Wednesday of the month is NOT a review day', () {
      final firstWednesday = _firstWeekdayOfMonth(2026, 9, DateTime.wednesday);
      final secondWednesday = firstWednesday.add(const Duration(days: 7));
      expect(ModelLabSchedule.isFirstWednesday(secondWednesday, _config()), isFalse);
    });

    test('a Tuesday is never a review day even in the first week', () {
      final firstWednesday = _firstWeekdayOfMonth(2026, 9, DateTime.wednesday);
      final precedingTuesday = firstWednesday.subtract(const Duration(days: 1));
      expect(ModelLabSchedule.isFirstWednesday(precedingTuesday, _config()), isFalse);
    });

    test('every month of a full year has exactly one qualifying Wednesday', () {
      for (var month = 1; month <= 12; month++) {
        var qualifying = 0;
        for (var day = 1; day <= 7; day++) {
          final date = DateTime(2026, month, day);
          if (ModelLabSchedule.isFirstWednesday(date, _config())) qualifying++;
        }
        expect(qualifying, 1, reason: 'month $month must have exactly one first Wednesday');
      }
    });
  });

  group('ModelLabSchedule.isLearningDay', () {
    test('only Tuesday counts as the learning day', () {
      final config = _config();
      final monday = _firstWeekdayOfMonth(2026, 8, DateTime.monday);
      for (var offset = 0; offset < 7; offset++) {
        final date = monday.add(Duration(days: offset));
        expect(
          ModelLabSchedule.isLearningDay(date, config),
          date.weekday == DateTime.tuesday,
        );
      }
    });
  });

  group('ModelLabSchedule.nextLearningRun / nextMonthlyReview', () {
    test('next learning run always lands on a future Tuesday', () {
      final now = _firstWeekdayOfMonth(2026, 8, DateTime.monday).add(const Duration(hours: 10));
      final next = ModelLabSchedule.nextLearningRun(now, _config());
      expect(next.weekday, DateTime.tuesday);
      expect(next.isAfter(now), isTrue);
    });

    test('next monthly review always lands on a future first Wednesday', () {
      final now = _firstWeekdayOfMonth(2026, 8, DateTime.monday).add(const Duration(hours: 10));
      final next = ModelLabSchedule.nextMonthlyReview(now, _config());
      expect(next.weekday, DateTime.wednesday);
      expect(next.day, lessThanOrEqualTo(7));
      expect(next.isAfter(now), isTrue);
    });

    test('rolls over into the next month once the current first Wednesday has passed', () {
      final firstWednesday = _firstWeekdayOfMonth(2026, 9, DateTime.wednesday);
      final afterReviewDay = firstWednesday.add(const Duration(hours: 10));
      final next = ModelLabSchedule.nextMonthlyReview(afterReviewDay, _config());
      expect(next.month, firstWednesday.month == 12 ? 1 : firstWednesday.month + 1);
    });
  });
}
