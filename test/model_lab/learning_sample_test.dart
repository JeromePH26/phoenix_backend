import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/learning_sample.dart';
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

LearningSample _sample({
  required DateTime kickoff,
  required DateTime snapshotCreatedAt,
  int homeGoals = 2,
  int awayGoals = 1,
  int? earliestRedCardMinute,
}) =>
    LearningSample(
      fixtureId: 'f1',
      leagueId: '78',
      kickoff: kickoff,
      snapshotCreatedAt: snapshotCreatedAt,
      dataQuality: 80,
      features: const {'raw.homeGoalsForAverageHome': 1.4},
      homeGoals: homeGoals,
      awayGoals: awayGoals,
      earliestRedCardMinute: earliestRedCardMinute,
    );

void main() {
  group('LearningSample.hasValidSnapshotTiming', () {
    // Test 6 (Section 86): Timestamp Test.
    test('is true when the snapshot was saved before kickoff', () {
      final kickoff = DateTime.utc(2026, 3, 1, 18);
      final sample = _sample(
        kickoff: kickoff,
        snapshotCreatedAt: kickoff.subtract(const Duration(hours: 2)),
      );
      expect(sample.hasValidSnapshotTiming, isTrue);
    });

    test('is false when the snapshot was saved after kickoff', () {
      final kickoff = DateTime.utc(2026, 3, 1, 18);
      final sample = _sample(
        kickoff: kickoff,
        snapshotCreatedAt: kickoff.add(const Duration(minutes: 5)),
      );
      expect(sample.hasValidSnapshotTiming, isFalse);
    });

    test('is false when the snapshot timestamp equals kickoff exactly', () {
      final kickoff = DateTime.utc(2026, 3, 1, 18);
      final sample = _sample(kickoff: kickoff, snapshotCreatedAt: kickoff);
      expect(sample.hasValidSnapshotTiming, isFalse);
    });
  });

  group('LearningSample.outcomeIndexFor', () {
    // Test 4 (Section 86): Pre-Match Leakage Test - das Ergebnis fließt
    // NIEMALS in `features` ein, sondern ausschließlich über die getrennten
    // homeGoals/awayGoals-Felder in die Outcome-Berechnung.
    test('outcome is derived from separate result fields, never from features',
        () {
      final sample = _sample(
        kickoff: DateTime.utc(2026, 3, 1),
        snapshotCreatedAt: DateTime.utc(2026, 2, 28),
        homeGoals: 3,
        awayGoals: 0,
      );
      expect(sample.features.containsKey('homeGoals'), isFalse);
      expect(sample.features.containsKey('awayGoals'), isFalse);
      expect(sample.features.containsKey('home_score'), isFalse);
      expect(sample.features.containsKey('away_score'), isFalse);
      expect(sample.outcomeIndexFor(LearningMarket.oneXTwo), 0);
    });

    test('1X2: home win, draw, away win map to indices 0, 1, 2', () {
      final win = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        homeGoals: 2,
        awayGoals: 1,
      );
      final draw = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        homeGoals: 1,
        awayGoals: 1,
      );
      final loss = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        homeGoals: 0,
        awayGoals: 2,
      );
      expect(win.outcomeIndexFor(LearningMarket.oneXTwo), 0);
      expect(draw.outcomeIndexFor(LearningMarket.oneXTwo), 1);
      expect(loss.outcomeIndexFor(LearningMarket.oneXTwo), 2);
    });

    test('over/under 2.5 boundary is exactly at 3 total goals', () {
      final under = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        homeGoals: 1,
        awayGoals: 1,
      );
      final over = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        homeGoals: 2,
        awayGoals: 1,
      );
      expect(under.outcomeIndexFor(LearningMarket.overUnder25), 1);
      expect(over.outcomeIndexFor(LearningMarket.overUnder25), 0);
    });

    test('BTTS requires both teams to score at least once', () {
      final bttsYes = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        homeGoals: 1,
        awayGoals: 1,
      );
      final bttsNo = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        homeGoals: 2,
        awayGoals: 0,
      );
      expect(bttsYes.outcomeIndexFor(LearningMarket.btts), 0);
      expect(bttsNo.outcomeIndexFor(LearningMarket.btts), 1);
    });

    test('new market families map results without treating DNB draws as losses',
        () {
      final homeTwo = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        homeGoals: 2,
        awayGoals: 1,
      );
      final draw = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        homeGoals: 1,
        awayGoals: 1,
      );

      expect(homeTwo.outcomeIndexFor(LearningMarket.overUnder15), 0);
      expect(homeTwo.outcomeIndexFor(LearningMarket.overUnder35), 1);
      expect(homeTwo.outcomeIndexFor(LearningMarket.homeTeamOver15), 0);
      expect(homeTwo.outcomeIndexFor(LearningMarket.homeTeamUnder15), 1);
      expect(homeTwo.outcomeIndexFor(LearningMarket.awayTeamUnder15), 0);
      expect(homeTwo.outcomeIndexFor(LearningMarket.homeTeamOver25), 1);
      expect(homeTwo.outcomeIndexFor(LearningMarket.homeTeamUnder25), 0);
      expect(homeTwo.outcomeIndexFor(LearningMarket.awayTeamOver25), 1);
      expect(homeTwo.outcomeIndexFor(LearningMarket.awayTeamUnder25), 0);
      expect(homeTwo.outcomeIndexFor(LearningMarket.doubleChance1x), 0);
      expect(homeTwo.outcomeIndexFor(LearningMarket.doubleChanceX2), 1);
      expect(draw.outcomeIndexFor(LearningMarket.drawNoBetHome), 1);
      expect(draw.outcomeIndexFor(LearningMarket.drawNoBetAway), 1);
    });
  });

  group('LearningSample distortion diagnostics', () {
    test('no known red card means clean (Section 26/27)', () {
      final sample = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
      );
      expect(sample.distortionLevel(_config()), isNull);
      expect(sample.isClean(_config()), isTrue);
    });

    test('an early red card is high distortion and not clean', () {
      final sample = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        earliestRedCardMinute: 5,
      );
      expect(sample.distortionLevel(_config()), 'high');
      expect(sample.isClean(_config()), isFalse);
    });

    test('a very late red card is low distortion and still counts as clean',
        () {
      final sample = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        earliestRedCardMinute: 88,
      );
      expect(sample.distortionLevel(_config()), 'low');
      expect(sample.isClean(_config()), isTrue);
    });

    // Section 31 (Rote Karten): ein Match mit roter Karte wird nicht aus der
    // realen Performance gelöscht - es bleibt weiterhin ein valides Sample.
    test('a red card never removes the match from the dataset itself', () {
      final sample = _sample(
        kickoff: DateTime.utc(2026, 1, 1),
        snapshotCreatedAt: DateTime.utc(2025, 12, 31),
        earliestRedCardMinute: 5,
      );
      expect(sample.hasValidSnapshotTiming, isTrue);
      expect(() => sample.outcomeIndexFor(LearningMarket.oneXTwo),
          returnsNormally);
    });
  });
}
