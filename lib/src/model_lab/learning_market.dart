/// Die Markt-Familien, die das Model Lab getrennt lernt und versioniert.
///
/// Jeder Eintrag entspricht einem Markt, den die produktive
/// Monte-Carlo-Engine tatsächlich berechnet. Damit bekommt z. B. Unter 3,5
/// seinen eigenen Champion statt stillschweigend von einem BTTS-Champion
/// beurteilt zu werden. Draw No Bet ist ein ZWEI-Klassen-Markt, bedingt auf
/// "kein Unentschieden" (`P(Sieg) / (P(Sieg) + P(Niederlage))`) - identisch
/// zur Live-Engine (`football_simulation_service.dart`). Unentschieden-Spiele
/// sind ein Push (Einsatz zurück) und werden über [LearningSample.isVoidOutcomeFor]
/// / [ShadowPredictionService] komplett aus der DNB-Bewertung ausgefiltert,
/// nicht als Verlust gezählt. (Früher fälschlich als 3-Klassen-Markt kodiert,
/// byte-identisch zu 1X2 - eingefroren 2026-08-27, siehe
/// docs/engine-audit/04-calibration-uncertainty.md.)
enum LearningMarket {
  oneXTwo('1x2', 'Ergebnis (1X2)'),
  overUnder15('over_under_1_5', 'Über/Unter 1,5 Tore'),
  overUnder25('over_under_2_5', 'Über/Unter 2,5 Tore'),
  overUnder35('over_under_3_5', 'Über/Unter 3,5 Tore'),
  btts('btts', 'Beide Teams treffen'),
  homeTeamOver15('home_team_over_1_5', 'Heimteam über 1,5 Tore'),
  homeTeamUnder15('home_team_under_1_5', 'Heimteam unter 1,5 Tore'),
  awayTeamOver15('away_team_over_1_5', 'Auswärtsteam über 1,5 Tore'),
  awayTeamUnder15('away_team_under_1_5', 'Auswärtsteam unter 1,5 Tore'),
  homeTeamOver25('home_team_over_2_5', 'Heimteam über 2,5 Tore'),
  homeTeamUnder25('home_team_under_2_5', 'Heimteam unter 2,5 Tore'),
  awayTeamOver25('away_team_over_2_5', 'Auswärtsteam über 2,5 Tore'),
  awayTeamUnder25('away_team_under_2_5', 'Auswärtsteam unter 2,5 Tore'),
  doubleChance1x('double_chance_1x', 'Doppelte Chance 1X'),
  doubleChanceX2('double_chance_x2', 'Doppelte Chance X2'),
  drawNoBetHome('draw_no_bet_home', 'Draw No Bet Heim'),
  drawNoBetAway('draw_no_bet_away', 'Draw No Bet Auswärts');

  const LearningMarket(this.key, this.label);

  final String key;
  final String label;

  /// Nur 1X2 wird über drei Klassen (Heim/Remis/Auswärts) bewertet. Draw No
  /// Bet ist binär (Sieg/Niederlage, bedingt auf "kein Remis") - siehe
  /// Klassendoku.
  bool get isMultiClass => this == LearningMarket.oneXTwo;

  /// Märkte mit einem Push-Ausgang (Einsatz zurück), der weder Gewinn noch
  /// Verlust ist und deshalb aus Training/Bewertung fällt. Aktuell nur Draw
  /// No Bet bei einem Unentschieden.
  bool get hasVoidableOutcome =>
      this == LearningMarket.drawNoBetHome ||
      this == LearningMarket.drawNoBetAway;

  static LearningMarket? fromKey(String key) {
    for (final market in LearningMarket.values) {
      if (market.key == key) return market;
    }
    return null;
  }

  /// Ordnet die vom historischen `football_analysis_history.market_key`
  /// gespeicherten produktiven Marktschlüssel einem Model-Lab-Markt zu.
  /// Kombis, DC 12 und Handicaps werden bewusst nicht gelernt, weil sie nicht
  /// mehr als öffentliche PHÖNIX-Empfehlung zulässig sind.
  static LearningMarket? fromProductionMarketKey(String productionKey) {
    switch (productionKey) {
      case 'homeWin':
      case 'draw':
      case 'awayWin':
        return LearningMarket.oneXTwo;
      case 'over25':
      case 'under25':
        return LearningMarket.overUnder25;
      case 'over15':
      case 'under15':
        return LearningMarket.overUnder15;
      case 'over35':
      case 'under35':
        return LearningMarket.overUnder35;
      case 'bttsYes':
      case 'bttsNo':
        return LearningMarket.btts;
      case 'homeOver15':
        return LearningMarket.homeTeamOver15;
      case 'homeUnder15':
        return LearningMarket.homeTeamUnder15;
      case 'awayOver15':
        return LearningMarket.awayTeamOver15;
      case 'awayUnder15':
        return LearningMarket.awayTeamUnder15;
      case 'homeOver25':
        return LearningMarket.homeTeamOver25;
      case 'homeUnder25':
        return LearningMarket.homeTeamUnder25;
      case 'awayOver25':
        return LearningMarket.awayTeamOver25;
      case 'awayUnder25':
        return LearningMarket.awayTeamUnder25;
      case 'dc1x':
        return LearningMarket.doubleChance1x;
      case 'dcX2':
        return LearningMarket.doubleChanceX2;
      case 'dnbHome':
        return LearningMarket.drawNoBetHome;
      case 'dnbAway':
        return LearningMarket.drawNoBetAway;
      default:
        return null;
    }
  }
}
