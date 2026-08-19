/// PHÖNIX ACCOUNT SYSTEM (Abschnitt 28/29): zentrale, reine Berechnung von
/// `effective_premium` aus den strikt getrennten Premiumquellen. Keine
/// Datenbankzugriffe - der Aufrufer lädt die Entitlement-Zeilen aus
/// `user_premium_entitlements` selbst und übergibt sie hier zur Auswertung.
library;

enum PremiumSource {
  googlePlay('GOOGLE_PLAY'),
  website('WEBSITE'),
  manual('MANUAL'),
  promotion('PROMOTION'),
  staff('STAFF'),
  partner('PARTNER');

  const PremiumSource(this.key);
  final String key;

  static PremiumSource? fromKey(String key) {
    for (final source in PremiumSource.values) {
      if (source.key == key) return source;
    }
    return null;
  }
}

class PremiumEntitlement {
  const PremiumEntitlement({
    required this.source,
    required this.active,
    this.expiresAt,
  });

  final PremiumSource source;
  final bool active;
  final DateTime? expiresAt;

  /// Eine Zeile zählt nur, wenn sie aktiv ist UND (kein Ablaufdatum ODER das
  /// Ablaufdatum noch nicht erreicht ist).
  bool isCurrentlyValid(DateTime now) {
    if (!active) return false;
    final expiry = expiresAt;
    if (expiry == null) return true;
    return expiry.isAfter(now);
  }
}

/// Abschnitt 29: "Effective Premium" ist wahr, sobald IRGENDEINE
/// Premiumquelle (außer STAFF, siehe unten) aktuell gültig ist - unabhängig
/// davon, wie viele es gibt oder welche Quelle.
///
/// Abschnitt 29 explizit: Staff Access gibt vollen App-Zugriff, zählt aber
/// NICHT als zahlender Premiumkunde - `PremiumSource.staff`-Zeilen werden
/// deshalb hier bewusst ignoriert. Staff-Zugriff wird separat über
/// `admin_employees.staff_app_access`/[hasFullAppAccess] behandelt.
bool effectivePremium(
  List<PremiumEntitlement> entitlements, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  return entitlements.any(
    (e) => e.source != PremiumSource.staff && e.isCurrentlyValid(at),
  );
}

/// Abschnitt 17/29: voller App-Zugriff (Feature-Gating in der Flutter-App),
/// unabhängig davon, ob es sich um einen zahlenden Premiumkunden handelt.
/// Ein Mitarbeiter mit `staffAppAccess = true` bekommt vollen Zugriff, auch
/// ohne jemals ein Abo abgeschlossen zu haben.
bool hasFullAppAccess(
  List<PremiumEntitlement> entitlements, {
  required bool staffAppAccess,
  DateTime? now,
}) {
  if (staffAppAccess) return true;
  return effectivePremium(entitlements, now: now);
}
