import 'package:phoenix_backend/src/model_lab/learning_dataset_classifier.dart';
import 'package:test/test.dart';

void main() {
  const c = LearningDatasetClassifier(minDataQuality: 40, productionDataQuality: 60);
  final ko = DateTime.utc(2026, 3, 1, 15);
  final beforeKo = DateTime.utc(2026, 3, 1, 6);
  final afterKo = DateTime.utc(2026, 3, 1, 18);
  final now = DateTime.utc(2026, 3, 2);

  DatasetClassification live({
    String? tier = 'focus',
    bool finished = true,
    bool goals = true,
    DateTime? snapshot,
    int dq = 70,
    bool isCup = false,
    bool standings = true,
    bool teamStats = true,
    int leagueCount = 100,
  }) =>
      c.classifyLive(
        collectionTier: tier,
        finishedStatus: finished,
        hasGoals: goals,
        kickoff: ko,
        snapshotCreatedAt: snapshot ?? beforeKo,
        dataQuality: dq,
        isCup: isCup,
        hasStandings: standings,
        hasUsableTeamStats: teamStats,
        leagueEligibleCount: leagueCount,
        now: now,
      );

  group('classifyLive', () {
    test('a clean focus fixture with rich data is production', () {
      expect(live().dataClass, LearningDataClass.production);
      expect(live().excludedReason, isNull);
    });

    test('a cup fixture drops from production to learning', () {
      final r = live(isCup: true);
      expect(r.dataClass, LearningDataClass.learning);
    });

    test('a focus fixture just above the learning floor is learning', () {
      final r = live(dq: 45, standings: false);
      expect(r.dataClass, LearningDataClass.learning);
    });

    test('below the data-quality floor is research with a reason', () {
      final r = live(dq: 30);
      expect(r.dataClass, LearningDataClass.research);
      expect(r.excludedReason, 'data_quality_below_40');
    });

    test('a post-kickoff snapshot is quarantine (leakage)', () {
      final r = live(snapshot: afterKo);
      expect(r.dataClass, LearningDataClass.quarantine);
      expect(r.leakageResult, 'snapshot_after_kickoff');
    });

    test('finished status without goals is quarantine', () {
      final r = live(goals: false);
      expect(r.dataClass, LearningDataClass.quarantine);
      expect(r.excludedReason, 'finished_without_goals');
    });

    test('data_pool tier is research even with a clean snapshot', () {
      final r = live(tier: 'data_pool', dq: 80);
      expect(r.dataClass, LearningDataClass.research);
      expect(r.excludedReason, 'data_pool_tier');
    });

    test('a thin watchlist league is research', () {
      final r = live(tier: 'watchlist', leagueCount: 5, standings: false);
      expect(r.dataClass, LearningDataClass.research);
      expect(r.excludedReason, 'thin_watchlist_league');
    });

    test('a well-populated watchlist league reaches learning', () {
      final r = live(tier: 'watchlist', leagueCount: 40, standings: false);
      expect(r.dataClass, LearningDataClass.learning);
    });

    test('a non-whitelisted tier is research/not_whitelisted', () {
      final r = live(tier: 'blocked');
      expect(r.dataClass, LearningDataClass.research);
      expect(r.excludedReason, 'not_whitelisted');
    });

    test('an upcoming (not yet played) focus fixture is not learning', () {
      final r = c.classifyLive(
        collectionTier: 'focus',
        finishedStatus: false,
        hasGoals: false,
        kickoff: DateTime.utc(2026, 4, 1),
        snapshotCreatedAt: DateTime.utc(2026, 3, 30),
        dataQuality: 55,
        isCup: false,
        hasStandings: false,
        hasUsableTeamStats: false,
        leagueEligibleCount: 100,
        now: now,
      );
      expect(r.dataClass, LearningDataClass.research);
      expect(r.excludedReason, 'not_yet_settled');
    });
  });

  group('classifyHistoricalTwin', () {
    test('a fully linked twin with a result is learning', () {
      final r = c.classifyHistoricalTwin(
        leagueLinked: true,
        bothTeamsLinked: true,
        hasResult: true,
      );
      expect(r.dataClass, LearningDataClass.learning);
    });

    test('an unlinked twin is research/historical_unlinked', () {
      final r = c.classifyHistoricalTwin(
        leagueLinked: false,
        bothTeamsLinked: false,
        hasResult: true,
      );
      expect(r.dataClass, LearningDataClass.research);
      expect(r.excludedReason, 'historical_unlinked');
    });

    test('a linked twin without a result is quarantine', () {
      final r = c.classifyHistoricalTwin(
        leagueLinked: true,
        bothTeamsLinked: true,
        hasResult: false,
      );
      expect(r.dataClass, LearningDataClass.quarantine);
    });
  });
}
