/// Steuert, wie PHÖNIX eine Fußballliga verarbeitet. Die Datenstruktur bleibt
/// für jede Stufe identisch; nur Aktualisierungsfrequenz und öffentliche
/// Sichtbarkeit unterscheiden sich.
enum FootballLeagueTier {
  /// Öffentliche PHÖNIX-Ligen: vollständige Analyse, Tipps und Live-Priorität.
  focus('focus'),

  /// Hintergrund mit Detaildaten und Shadow-Predictions, jedoch ohne Tipps.
  watchlist('watchlist'),

  /// Weltweiter Langzeit-Datensatz mit budgetiertem Backfill.
  dataPool('data_pool'),

  /// Bewusst ausgeschlossene Wettbewerbe.
  blocked('blocked');

  const FootballLeagueTier(this.storageKey);

  final String storageKey;

  bool get isPublic => this == FootballLeagueTier.focus;
  bool get isBackgroundEnabled => this != FootballLeagueTier.blocked;

  static FootballLeagueTier fromStorage(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'focus' => FootballLeagueTier.focus,
      'watchlist' => FootballLeagueTier.watchlist,
      'blocked' => FootballLeagueTier.blocked,
      _ => FootballLeagueTier.dataPool,
    };
  }

  /// Rückwärtskompatibilität für bestehende Admin- und App-Endpunkte.
  static FootballLeagueTier fromLegacyManualStatus(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'whitelist' => FootballLeagueTier.focus,
      'blacklist' => FootballLeagueTier.blocked,
      _ => FootballLeagueTier.dataPool,
    };
  }
}
