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
    this.globalGoalsV1ExpectedHome,
    this.globalGoalsV1ExpectedAway,
    this.globalMarketAvailability,
    this.globalMarketHomeTeamId,
    this.globalMarketAwayTeamId,
    this.globalMarketLeagueAvgHomeGoals,
    this.globalMarketLeagueAvgAwayGoals,
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

  /// Vorab (bei Sample-Erstellung) berechnete Torerwartung des
  /// GLOBAL_GOALS_V1-Engines (siehe `GlobalGoalsV1Engine`), aus einem
  /// leakage-sicheren Phase-2-Snapshot vor dem Kickoff. `null`, wenn für
  /// dieses Fixture kein solcher Snapshot existiert - Phase-2-Scans laufen
  /// erst seit Kurzem und nicht für jede Liga/jedes historische Spiel.
  final double? globalGoalsV1ExpectedHome;
  final double? globalGoalsV1ExpectedAway;

  /// Rohdaten für `GlobalMarketEngine` (siehe `global_market_engine.dart`) -
  /// im Gegensatz zu [globalGoalsV1ExpectedHome]/[globalGoalsV1ExpectedAway]
  /// wird hier NICHT eine einzelne fertige Torerwartung vorab berechnet,
  /// sondern die Rohdaten gespeichert: `GlobalMarketEngine` hat mehrere
  /// Marktfamilien UND mehrere Hypothesis-Gewichtsvarianten je Familie -
  /// eine Vorab-Berechnung für jede Kombination wäre unnötig viel
  /// gespeicherter/berechneter Ballast. Dieselbe leakage-sichere
  /// Phase-2-Snapshot-Quelle wie [globalGoalsV1ExpectedHome].
  final Map<String, Object?>? globalMarketAvailability;
  final String? globalMarketHomeTeamId;
  final String? globalMarketAwayTeamId;
  final double? globalMarketLeagueAvgHomeGoals;
  final double? globalMarketLeagueAvgAwayGoals;

  bool get hasGlobalMarketData =>
      globalMarketAvailability != null &&
      globalMarketHomeTeamId != null &&
      globalMarketAwayTeamId != null;

  bool get hasGlobalGoalsV1Data =>
      globalGoalsV1ExpectedHome != null && globalGoalsV1ExpectedAway != null;

  /// Section 18/19: Snapshot Integrity - muss vor jeder Verwendung als
  /// Learning-Sample geprüft sein. Wird hier zusätzlich zur SQL-Filterung
  /// defensiv erneut geprüft (Belt-and-braces).
  bool get hasValidSnapshotTiming => snapshotCreatedAt.isBefore(kickoff);

  /// Ob der Ausgang dieses Spiels für den gegebenen Markt ein Push ist
  /// (Einsatz zurück, weder Gewinn noch Verlust). Solche Samples MÜSSEN vor
  /// jeder Bewertung/jedem Training herausgefiltert werden - [outcomeIndexFor]
  /// liefert für sie keinen sinnvollen Wert. Aktuell nur Draw No Bet bei
  /// einem Unentschieden.
  bool isVoidOutcomeFor(LearningMarket market) =>
      market.hasVoidableOutcome && homeGoals == awayGoals;

  /// Index der eingetretenen Klasse für den gegebenen Markt. Für
  /// LearningMarket.oneXTwo: 0=Heimsieg, 1=Unentschieden, 2=Auswärtssieg.
  /// Für binäre Märkte: 0=positiv (over25/bttsYes/DNB-Gewinn), 1=negativ.
  /// Bei Draw No Bet muss ein Unentschieden zuvor über [isVoidOutcomeFor]
  /// ausgefiltert sein; wird es doch übergeben, kommt defensiv 1 (Verlust).
  int outcomeIndexFor(LearningMarket market) {
    switch (market) {
      case LearningMarket.oneXTwo:
        if (homeGoals > awayGoals) return 0;
        if (homeGoals == awayGoals) return 1;
        return 2;
      case LearningMarket.overUnder25:
        return (homeGoals + awayGoals) > 2.5 ? 0 : 1;
      case LearningMarket.overUnder15:
        return (homeGoals + awayGoals) > 1.5 ? 0 : 1;
      case LearningMarket.overUnder35:
        return (homeGoals + awayGoals) > 3.5 ? 0 : 1;
      case LearningMarket.btts:
        return (homeGoals >= 1 && awayGoals >= 1) ? 0 : 1;
      case LearningMarket.homeTeamOver15:
        return homeGoals > 1.5 ? 0 : 1;
      case LearningMarket.homeTeamUnder15:
        return homeGoals <= 1.5 ? 0 : 1;
      case LearningMarket.awayTeamOver15:
        return awayGoals > 1.5 ? 0 : 1;
      case LearningMarket.awayTeamUnder15:
        return awayGoals <= 1.5 ? 0 : 1;
      case LearningMarket.homeTeamOver25:
        return homeGoals > 2.5 ? 0 : 1;
      case LearningMarket.homeTeamUnder25:
        return homeGoals <= 2.5 ? 0 : 1;
      case LearningMarket.awayTeamOver25:
        return awayGoals > 2.5 ? 0 : 1;
      case LearningMarket.awayTeamUnder25:
        return awayGoals <= 2.5 ? 0 : 1;
      case LearningMarket.doubleChance1x:
        return homeGoals >= awayGoals ? 0 : 1;
      case LearningMarket.doubleChanceX2:
        return awayGoals >= homeGoals ? 0 : 1;
      case LearningMarket.drawNoBetHome:
        // Push (Unentschieden) muss über isVoidOutcomeFor ausgefiltert sein.
        return homeGoals > awayGoals ? 0 : 1;
      case LearningMarket.drawNoBetAway:
        return awayGoals > homeGoals ? 0 : 1;
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
