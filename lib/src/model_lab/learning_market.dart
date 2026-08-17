/// Die drei Wettmärkte, die das V0 Model Lab unterstützt. Dies sind exakt
/// die Märkte, die in der Aufgabenstellung durchgängig als Beispiel genutzt
/// werden UND die die produktive Engine tatsächlich berechnet
/// (`football_simulation_results.result.probabilities`: home/draw/away,
/// over25/under25, bttsYes/bttsNo). Keine erfundenen Märkte.
enum LearningMarket {
  oneXTwo('1x2', 'Ergebnis (1X2)'),
  overUnder25('over_under_2_5', 'Über/Unter 2,5 Tore'),
  btts('btts', 'Beide Teams treffen');

  const LearningMarket(this.key, this.label);

  final String key;
  final String label;

  bool get isMultiClass => this == LearningMarket.oneXTwo;

  static LearningMarket? fromKey(String key) {
    for (final market in LearningMarket.values) {
      if (market.key == key) return market;
    }
    return null;
  }

  /// Ordnet die vom historischen `football_analysis_history.market_key`
  /// gespeicherten produktiven Marktschlüssel (z.B. `homeWin`, `over25`,
  /// `bttsYes`) einem Model-Lab-Markt zu. Andere Marktschlüssel (DC, DNB,
  /// Handicaps, Team-Totals, Kombis) sind für V0 bewusst außerhalb des
  /// Scopes und werden nicht zugeordnet.
  static LearningMarket? fromProductionMarketKey(String productionKey) {
    switch (productionKey) {
      case 'homeWin':
      case 'draw':
      case 'awayWin':
        return LearningMarket.oneXTwo;
      case 'over25':
      case 'under25':
        return LearningMarket.overUnder25;
      case 'bttsYes':
      case 'bttsNo':
        return LearningMarket.btts;
      default:
        return null;
    }
  }
}
