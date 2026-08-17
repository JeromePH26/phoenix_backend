import '../config/model_lab_config.dart';
import 'learning_market.dart';

/// Ein einzelnes, leakage-sicheres Trainings-/Test-Sample: der letzte VOR dem
/// Kickoff gespeicherte Pre-Match-Snapshot eines Fixtures plus dessen NACH
/// Matchende bekannt gewordenes Ergebnis. Enthält ausschließlich whitelisted
/// Features (siehe `FeatureWhitelist`).
class LearningSample {
  const LearningSample({
    required this.fixtureId,
    required this.leagueId,
    required this.kickoff,
    required this.snapshotCreatedAt,
    required this.dataQuality,
    required this.features,
    required this.homeGoals,
    required this.awayGoals,
    this.earliestRedCardMinute,
  });

  final String fixtureId;
  final String leagueId;
  final DateTime kickoff;
  final DateTime snapshotCreatedAt;
  final int dataQuality;
  final Map<String, Object?> features;
  final int homeGoals;
  final int awayGoals;
  final int? earliestRedCardMinute;

  /// Section 18/19: Snapshot Integrity - muss vor jeder Verwendung als
  /// Learning-Sample geprüft sein. Wird hier zusätzlich zur SQL-Filterung
  /// defensiv erneut geprüft (Belt-and-braces).
  bool get hasValidSnapshotTiming => snapshotCreatedAt.isBefore(kickoff);

  /// Index der eingetretenen Klasse für den gegebenen Markt. Für
  /// LearningMarket.oneXTwo: 0=Heimsieg, 1=Unentschieden, 2=Auswärtssieg.
  /// Für binäre Märkte: 0=positiv (over25/bttsYes), 1=negativ.
  int outcomeIndexFor(LearningMarket market) {
    switch (market) {
      case LearningMarket.oneXTwo:
        if (homeGoals > awayGoals) return 0;
        if (homeGoals == awayGoals) return 1;
        return 2;
      case LearningMarket.overUnder25:
        return (homeGoals + awayGoals) > 2.5 ? 0 : 1;
      case LearningMarket.btts:
        return (homeGoals >= 1 && awayGoals >= 1) ? 0 : 1;
    }
  }

  /// Section 25/26: einfache, nachvollziehbare Verzerrungs-Diagnose anhand
  /// der frühesten bekannten roten Karte. `null` bedeutet "keine bekannte
  /// rote Karte" (nicht zwangsläufig "keine rote Karte" - siehe
  /// Coverage-Hinweis im Model-Lab-Bericht: football_live_events deckt nur
  /// von Nutzern favorisierte Fixtures ab).
  String? distortionLevel(ModelLabConfig config) {
    final minute = earliestRedCardMinute;
    if (minute == null) return null;
    if (minute <= config.redCardEarlyMinute) return 'high';
    if (minute <= config.redCardLateMinute) return 'medium';
    return 'low';
  }

  /// Section 27: "Clean" = keine bekannte oder nur späte rote Karte.
  bool isClean(ModelLabConfig config) {
    final level = distortionLevel(config);
    return level == null || level == 'low';
  }
}
