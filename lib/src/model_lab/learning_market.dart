/// Die Markt-Familien, die das Model Lab getrennt lernt und versioniert.
///
/// Jeder Eintrag entspricht einem Markt, den die produktive
/// Monte-Carlo-Engine tatsächlich berechnet. Damit bekommt z. B. Unter 3,5
/// seinen eigenen Champion statt stillschweigend von einem BTTS-Champion
/// beurteilt zu werden. Draw No Bet wird als Drei-Klassen-Markt bewertet
/// (Gewinn / Push / Verlust), damit Unentschieden nicht fälschlich als
/// verlorene Wette in das Learning eingeht.
enum LearningMarket {
  oneXTwo('1x2', 'Ergebnis (1X2)'),
  overUnder15('over_under_1_5', 'Über/Unter 1,5 Tore'),
  overUnder25('over_under_2_5', 'Über/Unter 2,5 Tore'),
  overUnder35('over_under_3_5', 'Über/Unter 3,5 Tore'),
  btts('btts', 'Beide Teams treffen'),
  homeTeamOver15('home_team_over_1_5', 'Heimteam über 1,5 Tore'),
  awayTeamOver15('away_team_over_1_5', 'Auswärtsteam über 1,5 Tore'),
  doubleChance1x('double_chance_1x', 'Doppelte Chance 1X'),
  doubleChanceX2('double_chance_x2', 'Doppelte Chance X2'),
  drawNoBetHome('draw_no_bet_home', 'Draw No Bet Heim'),
  drawNoBetAway('draw_no_bet_away', 'Draw No Bet Auswärts');

  const LearningMarket(this.key, this.label);

  final String key;
  final String label;

  bool get isMultiClass =>
      this == LearningMarket.oneXTwo ||
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
      case 'awayOver15':
        return LearningMarket.awayTeamOver15;
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
