/// M2 (AN2 §24-32): entscheidet pro `(fixture, market, source)`, in welche
/// Datenklasse eine Zeile fällt. Reine Logik ohne DB-Zugriff, damit sie mit
/// Unit-Tests abgedeckt ist; die Befüllung von `phoenix_learning_dataset`
/// macht `bin/phoenix_classify_dataset.dart`.
///
/// Klassen (docs/engine-audit/02-data-availability-audit.md §data-class):
/// - **production**: gut genug für die aktive Live-Analyse.
/// - **learning**: gut genug für Training / Challenger / Backtests /
///   Kalibrierung, nicht zwingend vollständig genug für Live.
/// - **research**: darf untersucht werden, aber NICHT automatisch in
///   Training / Champion-Auswahl / Live einfließen.
/// - **quarantine**: kaputt oder leakage-behaftet - nie verwenden.
class LearningDataClass {
  static const production = 'production';
  static const learning = 'learning';
  static const research = 'research';
  static const quarantine = 'quarantine';
}

/// Eine Zeile für `phoenix_learning_dataset`
/// (`PhoenixDatabase.upsertLearningDatasetRows`).
typedef LearningDatasetRow = ({
  String fixtureId,
  String market,
  String source,
  String dataClass,
  double? featureCompleteness,
  bool leakageChecked,
  String? leakageResult,
  String? snapshotRef,
  int? dataQuality,
  bool isCup,
  String? excludedReason,
  String? leagueId,
  DateTime? kickoff,
});

class DatasetClassification {
  const DatasetClassification(
    this.dataClass, {
    this.excludedReason,
    this.leakageResult = 'not_checked',
    this.featureCompleteness,
  });

  final String dataClass;

  /// Warum die Zeile NICHT in `production`/`learning` ist (`null`, wenn sie
  /// es ist). Für den §49-Audit.
  final String? excludedReason;

  /// `ok` | `snapshot_after_kickoff` | `no_snapshot` | `not_applicable` |
  /// `not_checked`.
  final String leakageResult;

  final double? featureCompleteness;
}

class LearningDatasetClassifier {
  const LearningDatasetClassifier({
    this.minDataQuality = 40,
    this.productionDataQuality = 60,
    this.thinLeagueSampleThreshold = 20,
  });

  /// Untergrenze für `learning` (M2-Bootstrap: die aktuelle
  /// `data_quality`-Schwelle; in M6 durch die echte Modellqualität ersetzt).
  final int minDataQuality;

  /// Untergrenze für `production`.
  final int productionDataQuality;

  /// Unter so vielen sonst-eligiblen Samples gilt eine Beobachtungsliga als
  /// zu dünn -> RESEARCH statt LEARNING.
  final int thinLeagueSampleThreshold;

  /// Klassifiziert einen LIVE-Pre-Match-Snapshot (`source = 'live'`).
  DatasetClassification classifyLive({
    required String? collectionTier,
    required bool finishedStatus,
    required bool hasGoals,
    required DateTime? kickoff,
    required DateTime? snapshotCreatedAt,
    required int dataQuality,
    required bool isCup,
    required bool hasStandings,
    required bool hasUsableTeamStats,
    required int leagueEligibleCount,
    DateTime? now,
  }) {
    final tier = collectionTier;
    final whitelisted =
        tier == 'focus' || tier == 'watchlist' || tier == 'data_pool';
    if (!whitelisted) {
      return const DatasetClassification(
        LearningDataClass.research,
        excludedReason: 'not_whitelisted',
        leakageResult: 'not_applicable',
      );
    }

    final played = kickoff != null &&
        (now ?? DateTime.now().toUtc()).isAfter(kickoff);

    // Beendet laut Status, aber keine Tore -> kaputte Zeile.
    if (finishedStatus && !hasGoals) {
      return const DatasetClassification(
        LearningDataClass.quarantine,
        excludedReason: 'finished_without_goals',
        leakageResult: 'not_applicable',
      );
    }

    // Leakage: Snapshot am/nach Anpfiff -> unbrauchbar fürs Lernen.
    final String leakage;
    if (snapshotCreatedAt == null) {
      leakage = 'no_snapshot';
    } else if (kickoff == null || !snapshotCreatedAt.isBefore(kickoff)) {
      leakage = 'snapshot_after_kickoff';
    } else {
      leakage = 'ok';
    }
    if (leakage != 'ok') {
      return DatasetClassification(
        LearningDataClass.quarantine,
        excludedReason: leakage,
        leakageResult: leakage,
      );
    }

    // Ab hier: whitelisted, kein Leakage. `data_pool` liefert real ~0
    // verwertbare Zeilen (avg dq 19) -> RESEARCH.
    if (tier == 'data_pool') {
      return const DatasetClassification(
        LearningDataClass.research,
        excludedReason: 'data_pool_tier',
        leakageResult: 'ok',
      );
    }

    // Zu dünn besetzte Beobachtungsligen -> RESEARCH.
    if (tier == 'watchlist' &&
        leagueEligibleCount < thinLeagueSampleThreshold) {
      return const DatasetClassification(
        LearningDataClass.research,
        excludedReason: 'thin_watchlist_league',
        leakageResult: 'ok',
      );
    }

    if (dataQuality < minDataQuality) {
      return DatasetClassification(
        LearningDataClass.research,
        excludedReason: 'data_quality_below_$minDataQuality',
        leakageResult: 'ok',
      );
    }

    // PRODUCTION: strengere Anforderungen. Gilt für gespielte (settled) wie
    // kommende Fixtures der Fokus-Stufe.
    if (tier == 'focus' &&
        !isCup &&
        dataQuality >= productionDataQuality &&
        hasStandings &&
        hasUsableTeamStats) {
      return DatasetClassification(
        LearningDataClass.production,
        leakageResult: 'ok',
      );
    }

    // LEARNING: nur gespielte Fixtures mit Ergebnis (kommende Spiele sind
    // noch kein Trainingsmaterial).
    if (played && finishedStatus && hasGoals) {
      return DatasetClassification(
        LearningDataClass.learning,
        leakageResult: 'ok',
      );
    }

    return const DatasetClassification(
      LearningDataClass.research,
      excludedReason: 'not_yet_settled',
      leakageResult: 'ok',
    );
  }

  /// Klassifiziert ein an unsere Liga-/Team-Dimension gebundenes historisches
  /// Twin-Spiel (`source = 'twins'`). Elo/Form/Markt sind pre-match und
  /// leakage-sicher; das Ergebnis stammt aus getrennten Feldern.
  DatasetClassification classifyHistoricalTwin({
    required bool leagueLinked,
    required bool bothTeamsLinked,
    required bool hasResult,
  }) {
    if (!leagueLinked || !bothTeamsLinked) {
      return const DatasetClassification(
        LearningDataClass.research,
        excludedReason: 'historical_unlinked',
        leakageResult: 'ok',
      );
    }
    if (!hasResult) {
      return const DatasetClassification(
        LearningDataClass.quarantine,
        excludedReason: 'historical_without_result',
        leakageResult: 'not_applicable',
      );
    }
    return const DatasetClassification(
      LearningDataClass.learning,
      leakageResult: 'ok',
    );
  }
}
