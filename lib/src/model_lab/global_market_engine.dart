import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'feature_renormalization.dart';
import 'fixture_form_filter.dart';
import 'learning_market.dart';

/// Section "PHÖNIX MODEL LAB – GLOBALE CHAMPIONS" (Claude AN2.txt): eigene
/// gewichtete Torerwartungs-Engine je Marktfamilie (1X2, Tore/Totals, BTTS,
/// Team-Tore), statt überall dieselbe Formel zu verwenden.
///
/// WICHTIG - Abweichung von der Vorgabe, bewusst und dokumentiert: die
/// Vorlage sieht für jede Marktfamilie 25-45% Gewicht auf "xG/xGA",
/// "Teamstärke/Rating" und "Match-Kontext/Motivation" vor. Alle drei
/// existieren in PHÖNIX nicht als echte, gespeicherte Werte (siehe
/// `football_service.dart`: `realXgAvailable` ist fest `false`, es gibt
/// keine Team-Rating-/Elo-Tabelle, keine Motivations-/Kontext-Daten). Genau
/// dieselbe Vorlage verlangt an anderer Stelle (Section 9, "SEHR WICHTIG –
/// FEHLENDE DATEN"): fehlende Features werden NIEMALS durch 0 oder
/// Phantasiewerte ersetzt, sondern aus der Gewichtung entfernt und die
/// verbleibenden Gewichte proportional neu normalisiert. Genau das passiert
/// hier: die drei nicht verfügbaren Kategorien sind komplett gestrichen,
/// "Gegnerstärke" wurde auf die real vorhandene tabellenbasierte
/// Gegner-Abwehrkennzahl umgelegt, die verbleibenden echten Kategorien
/// (Angriff/Abwehr der Saison, aktuelle Form, Tabelle, Liga-Torkontext) und
/// die neu verfügbare H2H-Historie (`h2hData`, siehe `football_service.dart`
/// `/fixtures/headtohead`) tragen das gesamte Gewicht. [combineWeightedFeatures]
/// übernimmt dieselbe Renormalisierung zusätzlich pro einzelnem Spiel, falls
/// auch von den verbleibenden echten Features eines fehlt.
enum GlobalMarketFamily {
  /// 1X2, Doppelte Chance, Draw No Bet - alle aus derselben Ergebnis-
  /// Verteilung abgeleitet (Section 13/14 der Vorlage).
  oneXTwo('GLOBAL_1X2_V1', 'Global 1X2'),

  /// Torerwartung / Über-Unter-Märkte. In dieser Architektur ist "Totals"
  /// (Section 7 der Vorlage) strukturell identisch zu "Goals" (Section 5) -
  /// beide brauchen ausschließlich Home/Away Expected Goals, aus denen
  /// PoissonMath dieselben Über/Unter-Wahrscheinlichkeiten ableitet. Deshalb
  /// EINE Familie statt zwei nahezu identischer - die separate
  /// `GlobalGoalsV1Engine` (bereits produktiv als Challenger im Einsatz,
  /// Section 12: nie still verändern) deckt den "Goals"-Namen der Vorlage
  /// bereits ab.
  totals('GLOBAL_TOTALS_V1', 'Global Totals'),

  /// Beide Teams treffen.
  btts('GLOBAL_BTTS_V1', 'Global BTTS'),

  /// Heim-/Auswärtsteam über/unter - eigenes Profil, das die Torerwartung
  /// EINES Teams stärker gewichtet als die des Gegners (anders als bei
  /// 1X2/BTTS/Totals, wo beide Seiten für das Ergebnis gleich wichtig sind).
  teamGoals('GLOBAL_TEAM_GOALS_V1', 'Global Team Goals');

  const GlobalMarketFamily(this.version, this.label);

  final String version;
  final String label;

  /// Section 12/13/14 der Vorlage: 1X2 speist auch Doppelte Chance und Draw
  /// No Bet (aus derselben Ergebnisverteilung abgeleitet), Team-Tore-Märkte
  /// bekommen ihr eigenes Profil statt das der symmetrischen Märkte.
  static GlobalMarketFamily forMarket(LearningMarket market) => switch (market) {
        LearningMarket.oneXTwo ||
        LearningMarket.doubleChance1x ||
        LearningMarket.doubleChanceX2 ||
        LearningMarket.drawNoBetHome ||
        LearningMarket.drawNoBetAway =>
          GlobalMarketFamily.oneXTwo,
        LearningMarket.btts => GlobalMarketFamily.btts,
        LearningMarket.overUnder15 ||
        LearningMarket.overUnder25 ||
        LearningMarket.overUnder35 =>
          GlobalMarketFamily.totals,
        LearningMarket.homeTeamOver15 ||
        LearningMarket.homeTeamUnder15 ||
        LearningMarket.homeTeamOver25 ||
        LearningMarket.homeTeamUnder25 ||
        LearningMarket.awayTeamOver15 ||
        LearningMarket.awayTeamUnder15 ||
        LearningMarket.awayTeamOver25 ||
        LearningMarket.awayTeamUnder25 =>
          GlobalMarketFamily.teamGoals,
      };
}

/// Reine Gewichts-Presets je Marktfamilie (nicht auf 100 normiert - das
/// übernimmt [combineWeightedFeatures] automatisch). Nur echte, tatsächlich
/// gespeicherte Signale - siehe Klassendoku oben für die Begründung, warum
/// xG/Rating/Motivation fehlen.
class GlobalMarketWeights {
  const GlobalMarketWeights({
    required this.seasonAttack,
    required this.seasonDefenseOpponent,
    required this.recentFormAttack,
    required this.recentFormDefenseOpponent,
    required this.standingsGoalRateOpponentDefense,
    required this.leagueGoalContext,
    required this.h2h,
  });

  final double seasonAttack;
  final double seasonDefenseOpponent;
  final double recentFormAttack;
  final double recentFormDefenseOpponent;
  final double standingsGoalRateOpponentDefense;
  final double leagueGoalContext;
  final double h2h;

  GlobalMarketWeights scaled({
    double seasonFactor = 1,
    double formFactor = 1,
    double standingsFactor = 1,
    double leagueFactor = 1,
    double h2hFactor = 1,
  }) =>
      GlobalMarketWeights(
        seasonAttack: seasonAttack * seasonFactor,
        seasonDefenseOpponent: seasonDefenseOpponent * seasonFactor,
        recentFormAttack: recentFormAttack * formFactor,
        recentFormDefenseOpponent: recentFormDefenseOpponent * formFactor,
        standingsGoalRateOpponentDefense: standingsGoalRateOpponentDefense * standingsFactor,
        leagueGoalContext: leagueGoalContext * leagueFactor,
        h2h: h2h * h2hFactor,
      );

  static const Map<GlobalMarketFamily, GlobalMarketWeights> presets = {
    // Vorlage-Reste nach Streichung von xG 25% + Rating 20% + Kontext 6%:
    // Heim/Auswärts 15, Form 12, Angriff/Defensiv 10, Tabelle 9, H2H 3.
    // "Heim/Auswärtsleistung" und "Angriffs-/Defensivprofil" fallen in
    // diesem Datenmodell auf dieselben Features (Saisonwerte sind bereits
    // heim/auswärts-spezifisch gespeichert), deshalb zusammengelegt.
    // "Gegnerstärke" (Teil der gestrichenen Rating-Kategorie) wird durch die
    // reale tabellenbasierte Gegner-Abwehrkennzahl ersetzt statt ersatzlos
    // gestrichen.
    GlobalMarketFamily.oneXTwo: GlobalMarketWeights(
      seasonAttack: 12,
      seasonDefenseOpponent: 12,
      recentFormAttack: 6,
      recentFormDefenseOpponent: 6,
      standingsGoalRateOpponentDefense: 14,
      leagueGoalContext: 3,
      h2h: 3,
    ),
    // Vorlage-Reste nach Streichung von xG 35% + Schüsse/Chancenqualität 5%
    // (Schusslage wird bei PHÖNIX strukturell nicht erfasst): Angriff 15,
    // Defensive 15, Heim/Auswärts 10, Form 8, Gegnerstärke 7, Liga 5.
    GlobalMarketFamily.totals: GlobalMarketWeights(
      seasonAttack: 20,
      seasonDefenseOpponent: 20,
      recentFormAttack: 4,
      recentFormDefenseOpponent: 4,
      standingsGoalRateOpponentDefense: 7,
      leagueGoalContext: 5,
      h2h: 3,
    ),
    // Vorlage-Reste nach Streichung von xG 35% + Schüsse 7%: Angriff beider
    // Teams 15, Defensive Schwäche beider Teams 15, BTTS-Form 10,
    // Heim/Auswärts-Splits 10, Gegnerstärke 5, Liga-Kontext 3.
    GlobalMarketFamily.btts: GlobalMarketWeights(
      seasonAttack: 20,
      seasonDefenseOpponent: 20,
      recentFormAttack: 5,
      recentFormDefenseOpponent: 5,
      standingsGoalRateOpponentDefense: 5,
      leagueGoalContext: 3,
      h2h: 2,
    ),
    // Vorlage-Reste nach Streichung von eigenem xG/Angriffsstärke 30% +
    // Schüsse 10%: gegnerisches xGA/Defensive 25, Heim/Auswärts-Split 15,
    // Form 10, Gegnerstärke 10. Die gestrichenen 30% eigene Angriffsstärke
    // fließen auf die real vorhandene eigene Saison-Angriffskennzahl -
    // gerade bei einem team-spezifischen Markt ("wie viele Tore schießt
    // GENAU DIESES Team") ist das die zentrale reale Kennzahl.
    GlobalMarketFamily.teamGoals: GlobalMarketWeights(
      seasonAttack: 25,
      seasonDefenseOpponent: 20,
      recentFormAttack: 6,
      recentFormDefenseOpponent: 4,
      standingsGoalRateOpponentDefense: 8,
      leagueGoalContext: 3,
      h2h: 3,
    ),
  };
}

/// Section 10-12 der Vorlage (Claude AN2.txt): "nicht nur EIN Challenger...
/// jeder Challenger soll eine nachvollziehbare Hypothese darstellen" - vier
/// benannte, interpretierbare Gewichts-Varianten je Marktfamilie statt eines
/// blinden Zahlengitters. Jede Variante verschiebt den bestehenden, bereits
/// nur-echte-Daten-Preset relativ (per [GlobalMarketWeights.scaled]) in eine
/// nachvollziehbare Richtung - erfindet keine neuen Features.
enum GlobalMarketHypothesis {
  /// Gewichtet die letzten 5 Spiele stärker als Saisonwerte/Tabelle - die
  /// "wie gut spielt das Team GERADE JETZT"-Hypothese (steht dort, wo die
  /// Vorlage "xG Heavy" vorsieht - echtes xG existiert nicht, die aktuelle
  /// Form ist der nächstliegende reale Ersatz für "frischeste Qualität").
  formHeavy('form_heavy', 'Form-Heavy'),

  /// Gewichtet Saison-Angriff/Abwehr und Tabellenposition stärker als
  /// kurzfristige Form - die "Konstanz über die Saison zählt mehr als die
  /// letzten paar Spiele"-Hypothese.
  seasonHeavy('season_heavy', 'Saison/Tabellen-Heavy'),

  /// Kleine, kontrollierte Abweichung vom Basis-Preset (Section 11: "nicht
  /// identisch zum Champion") - betont H2H und Liga-Kontext etwas stärker,
  /// alles andere bleibt nah am Original.
  balanced('balanced', 'Balanced'),

  /// Gewichtet Angriffs-/Abwehrzahlen stark, Form/H2H/Liga-Kontext schwach -
  /// die "reine Tor-Statistik schlägt weichere Signale"-Hypothese.
  attackDefenseHeavy('attack_defense_heavy', 'Angriff/Verteidigung-Heavy');

  const GlobalMarketHypothesis(this.key, this.label);

  final String key;
  final String label;

  GlobalMarketWeights apply(GlobalMarketWeights base) => switch (this) {
        GlobalMarketHypothesis.formHeavy => base.scaled(formFactor: 2.2, seasonFactor: 0.8, standingsFactor: 0.8),
        GlobalMarketHypothesis.seasonHeavy => base.scaled(seasonFactor: 1.6, standingsFactor: 1.6, formFactor: 0.6),
        GlobalMarketHypothesis.balanced => base.scaled(h2hFactor: 1.4, leagueFactor: 1.4),
        GlobalMarketHypothesis.attackDefenseHeavy =>
          base.scaled(seasonFactor: 2.0, formFactor: 0.5, leagueFactor: 0.5, h2hFactor: 0.5),
      };
}

/// Wie `GlobalGoalsV1Engine`, aber parametrisiert über [GlobalMarketWeights]
/// statt mit fest einprogrammierten Gewichten, und zusätzlich mit einem
/// echten H2H-Feature (`h2hData`, aus `/fixtures/headtohead`, dieselbe
/// Rohdaten-Form wie `homeRecentData`/`awayRecentData`). `GlobalGoalsV1Engine`
/// selbst bleibt unverändert bestehen (bereits produktiv als Challenger
/// erzeugt, Section 12: Modelle werden nie still verändert) - dies ist die
/// Nachfolge-Generation für neue Challenger-Erzeugung.
class GlobalMarketEngine {
  const GlobalMarketEngine._();

  /// Deterministischer Hash: dieselbe Familie + Hypothese ergibt immer
  /// denselben Hash (verhindert Duplikate über den bestehenden Unique-Index
  /// auf `(market, league_id, config_hash)` - dasselbe Muster wie
  /// `GlobalGoalsV1Engine.configHash()`/`EngineWeightConfig.configHash()`).
  static String configHash({
    required GlobalMarketFamily family,
    GlobalMarketHypothesis? hypothesis,
  }) {
    final canonical = '${family.version}:${hypothesis?.key ?? "base"}';
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  static GoalsResult compute({
    required GlobalMarketFamily family,
    required Map<String, Object?> availability,
    required String homeTeamId,
    required String awayTeamId,
    double? leagueAvgHomeGoalsPerGame,
    double? leagueAvgAwayGoalsPerGame,
    // Für Hypothesis-Varianten (siehe [GlobalMarketHypothesis]) - wenn null,
    // wird der Basis-Preset der Marktfamilie verwendet (der Champion).
    GlobalMarketWeights? weightsOverride,
  }) {
    final weights = weightsOverride ?? GlobalMarketWeights.presets[family]!;
    final standingsRows = _flattenStandings(availability['standingsData']);
    final homeStanding = _findTeamStanding(standingsRows, homeTeamId);
    final awayStanding = _findTeamStanding(standingsRows, awayTeamId);

    final homeRecent = _teamGoalsFromFixtures(availability['homeRecentData'], homeTeamId);
    final awayRecent = _teamGoalsFromFixtures(availability['awayRecentData'], awayTeamId);
    final h2hHome = _teamGoalsFromFixtures(availability['h2hData'], homeTeamId);
    final h2hAway = _teamGoalsFromFixtures(availability['h2hData'], awayTeamId);

    final homeResult = combineWeightedFeatures([
      WeightedFeature(
        key: 'seasonAttack',
        idealWeight: weights.seasonAttack,
        value: _number(availability['homeGoalsForAverageHome']),
      ),
      WeightedFeature(
        key: 'seasonDefenseOpponent',
        idealWeight: weights.seasonDefenseOpponent,
        value: _number(availability['awayGoalsAgainstAverageAway']),
      ),
      WeightedFeature(
        key: 'recentFormAttack',
        idealWeight: weights.recentFormAttack,
        value: homeRecent?.scoredPerGame,
      ),
      WeightedFeature(
        key: 'recentFormDefenseOpponent',
        idealWeight: weights.recentFormDefenseOpponent,
        value: awayRecent?.concededPerGame,
      ),
      WeightedFeature(
        key: 'standingsGoalRateOpponentDefense',
        idealWeight: weights.standingsGoalRateOpponentDefense,
        value: awayStanding?.goalsAgainstPerGame,
      ),
      WeightedFeature(
        key: 'leagueGoalContext',
        idealWeight: weights.leagueGoalContext,
        value: leagueAvgHomeGoalsPerGame,
      ),
      WeightedFeature(
        key: 'h2h',
        idealWeight: weights.h2h,
        value: h2hHome?.scoredPerGame,
      ),
    ]);

    final awayResult = combineWeightedFeatures([
      WeightedFeature(
        key: 'seasonAttack',
        idealWeight: weights.seasonAttack,
        value: _number(availability['awayGoalsForAverageAway']),
      ),
      WeightedFeature(
        key: 'seasonDefenseOpponent',
        idealWeight: weights.seasonDefenseOpponent,
        value: _number(availability['homeGoalsAgainstAverageHome']),
      ),
      WeightedFeature(
        key: 'recentFormAttack',
        idealWeight: weights.recentFormAttack,
        value: awayRecent?.scoredPerGame,
      ),
      WeightedFeature(
        key: 'recentFormDefenseOpponent',
        idealWeight: weights.recentFormDefenseOpponent,
        value: homeRecent?.concededPerGame,
      ),
      WeightedFeature(
        key: 'standingsGoalRateOpponentDefense',
        idealWeight: weights.standingsGoalRateOpponentDefense,
        value: homeStanding?.goalsAgainstPerGame,
      ),
      WeightedFeature(
        key: 'leagueGoalContext',
        idealWeight: weights.leagueGoalContext,
        value: leagueAvgAwayGoalsPerGame,
      ),
      WeightedFeature(
        key: 'h2h',
        idealWeight: weights.h2h,
        value: h2hAway?.scoredPerGame,
      ),
    ]);

    final expectedHome = homeResult.value?.clamp(0.20, 3.80).toDouble();
    final expectedAway = awayResult.value?.clamp(0.20, 3.80).toDouble();

    return GoalsResult(
      family: family,
      expectedHome: expectedHome,
      expectedAway: expectedAway,
      expectedTotal: (expectedHome != null && expectedAway != null) ? expectedHome + expectedAway : null,
      homeFeatureCoverage: _coverage(homeResult),
      awayFeatureCoverage: _coverage(awayResult),
      warnings: [
        if (expectedHome == null || expectedAway == null)
          'Keine ausreichenden Daten für ${family.version} - alle Features fehlten.',
        'Keine echten xG/xGA-Daten vorhanden (strukturell nie verfügbar von API-Football).',
        'Kein Team-Rating/Elo, kein Match-Kontext/Motivation vorhanden (nicht in PHÖNIX gespeichert).',
      ],
    );
  }

  static Map<String, Object?> _coverage(RenormalizationResult result) => {
        'originalWeights': result.originalWeights,
        'effectiveWeights': result.effectiveWeights,
        'availableFeatures': result.availableFeatureKeys,
        'missingFeatures': result.missingFeatureKeys,
      };

  static List<Map<String, Object?>> _flattenStandings(Object? standingsData) {
    if (standingsData is! List) return const [];
    final rows = <Map<String, Object?>>[];
    for (final entry in standingsData) {
      if (entry is! Map) continue;
      final league = entry['league'];
      if (league is! Map) continue;
      final groups = league['standings'];
      if (groups is! List) continue;
      for (final group in groups) {
        if (group is! List) continue;
        for (final row in group) {
          if (row is Map) rows.add(Map<String, Object?>.from(row));
        }
      }
    }
    return rows;
  }

  static _StandingSnapshot? _findTeamStanding(
    List<Map<String, Object?>> rows,
    String teamId,
  ) {
    for (final row in rows) {
      final team = row['team'];
      if (team is! Map) continue;
      if (team['id']?.toString() != teamId) continue;
      final all = row['all'];
      if (all is! Map) continue;
      final played = _int(all['played']);
      if (played <= 0) continue;
      final goals = all['goals'];
      final goalsFor = goals is Map ? _number(goals['for']) : null;
      final goalsAgainst = goals is Map ? _number(goals['against']) : null;
      if (goalsFor == null || goalsAgainst == null) continue;
      return _StandingSnapshot(
        goalsForPerGame: goalsFor / played,
        goalsAgainstPerGame: goalsAgainst / played,
        played: played,
      );
    }
    return null;
  }

  /// Gemeinsame Auswertung für sowohl `homeRecentData`/`awayRecentData`
  /// (letzte 5 Spiele des Teams, unabhängig vom Gegner) als auch `h2hData`
  /// (letzte 5 Spiele GENAU gegen den heutigen Gegner) - beide haben
  /// identische API-Football-Rohform. Für H2H ergibt "vom Team X erzielte
  /// Tore in diesen Spielen" automatisch "von Team Y kassierte Tore",
  /// deshalb genügt hier EIN Feature pro Seite statt getrennt Angriff/Abwehr.
  static _TeamGoalsSnapshot? _teamGoalsFromFixtures(Object? fixtureListData, String teamId) {
    if (fixtureListData is! List || fixtureListData.isEmpty) return null;
    var scored = 0.0;
    var conceded = 0.0;
    var counted = 0;
    // Section 4 (Claude AN2.txt): abgesagte/abgebrochene/ergebnislos
    // verschobene Spiele raus, Freundschaftsspiele nur als Lückenfüller -
    // siehe fixture_form_filter.dart für die geteilte Begründung.
    for (final entry in selectFormFixtures(fixtureListData)) {
      final teams = entry['teams'];
      if (teams is! Map) continue;
      final home = teams['home'];
      final away = teams['away'];
      final homeId = home is Map ? home['id']?.toString() : null;
      final awayId = away is Map ? away['id']?.toString() : null;
      final goals = entry['goals'];
      if (goals is! Map) continue;
      final homeGoals = _number(goals['home']);
      final awayGoals = _number(goals['away']);
      if (homeGoals == null || awayGoals == null) continue;

      if (homeId == teamId) {
        scored += homeGoals;
        conceded += awayGoals;
        counted++;
      } else if (awayId == teamId) {
        scored += awayGoals;
        conceded += homeGoals;
        counted++;
      }
    }
    if (counted == 0) return null;
    return _TeamGoalsSnapshot(
      scoredPerGame: scored / counted,
      concededPerGame: conceded / counted,
      sampleSize: counted,
    );
  }

  static double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  static int _int(Object? value) => value is int
      ? value
      : value is num
          ? value.round()
          : int.tryParse(value?.toString() ?? '') ?? 0;
}

class _StandingSnapshot {
  const _StandingSnapshot({
    required this.goalsForPerGame,
    required this.goalsAgainstPerGame,
    required this.played,
  });
  final double goalsForPerGame;
  final double goalsAgainstPerGame;
  final int played;
}

class _TeamGoalsSnapshot {
  const _TeamGoalsSnapshot({
    required this.scoredPerGame,
    required this.concededPerGame,
    required this.sampleSize,
  });
  final double scoredPerGame;
  final double concededPerGame;
  final int sampleSize;
}

class GoalsResult {
  const GoalsResult({
    required this.family,
    required this.expectedHome,
    required this.expectedAway,
    required this.expectedTotal,
    required this.homeFeatureCoverage,
    required this.awayFeatureCoverage,
    required this.warnings,
  });

  final GlobalMarketFamily family;
  final double? expectedHome;
  final double? expectedAway;
  final double? expectedTotal;
  final Map<String, Object?> homeFeatureCoverage;
  final Map<String, Object?> awayFeatureCoverage;
  final List<String> warnings;

  Map<String, Object?> toJson() => {
        'version': family.version,
        'expectedHome': expectedHome,
        'expectedAway': expectedAway,
        'expectedTotal': expectedTotal,
        'homeFeatureCoverage': homeFeatureCoverage,
        'awayFeatureCoverage': awayFeatureCoverage,
        'warnings': warnings,
      };
}
