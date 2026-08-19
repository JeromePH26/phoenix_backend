/// PHÖNIX CONTROL CENTER: Rollen- und Berechtigungsmodell (additiv, separat
/// vom bestehenden statischen `PHOENIX_ADMIN_TOKEN`-Mechanismus in
/// `routes.dart`/`model_lab_routes.dart`). Reine, deterministische Logik -
/// keine Datenbankzugriffe, damit sie ohne Postgres testbar bleibt.
library;

/// Die acht erlaubten Mitarbeiterrollen (PHÖNIX Account-System Abschnitt 15:
/// `VICE_OWNER` und `SECURITY` kamen mit dem Account-System hinzu). `OWNER`
/// steht bewusst nicht in [kAssignableNonOwnerRoles], weil das Zuweisen von
/// `OWNER` einer eigenen Prüfung unterliegt (siehe `employee_rules.dart`).
const Set<String> kValidRoles = {
  'OWNER',
  'VICE_OWNER',
  'ADMIN',
  'TECHNICAL',
  'SUPPORT',
  'CONTENT',
  'MARKETING',
  'SECURITY',
};

/// Alle im Control Center bekannten Berechtigungsschlüssel. Dient u.a. der
/// Validierung von `permission_overrides`.
const Set<String> kAllPermissions = {
  'employees.view',
  'employees.manage',
  'audit.view',
  'search.view',
  'overview.view',
  'apiUsage.view',
  'jobs.view',
  'appControl.view',
  'appControl.manage',
  'devices.view',
  'support.view',
  'support.manage',
  'news.view',
  'news.manage',
  'faq.view',
  'faq.manage',
  'advertising.view',
  'advertising.manage',
  'push.manage',
  'premium.view',
  'premium.manage',
  'featureFlags.view',
  'featureFlags.manage',
  'release.view',
  'release.manage',
  'incidents.view',
  'incidents.manage',
  'security.view',
  'security.manage',
  'systemHealth.view',

  // PHÖNIX Account-System (Abschnitt 76/77, additiv): granulare Rechte für
  // Nutzerkonten, Sperren, Erstattungen, IP-Blocks und den Mitarbeiter-
  // Passwort-Reset-Freigabe-Workflow. Bewusst fein aufgeteilt statt in
  // `users.manage` gebündelt - z.B. darf Support laut Abschnitt 77 Nutzer
  // sehen, aber nicht sperren oder Security-/Zahlungsdetails einsehen.
  'users.view',
  'users.manage',
  'users.suspend',
  'users.unsuspend',
  'users.viewSecurityReport',
  'users.viewBettingHistory',
  'premium.manualGrant',
  'premium.manualRevoke',
  'refunds.decide',
  'ipBlocks.manage',
  'support.internalNotes',
  'support.assign',
  'employees.create',
  'employees.editPermissions',
  'employees.passwordResetApprove',
  'employees.sessionsManage',
};

/// Standard-Berechtigungen je Rolle. `OWNER` taucht hier absichtlich nicht
/// auf - Owner erhalten in [hasPermission] immer `true`, unabhängig von
/// dieser Tabelle und unabhängig von `permission_overrides` (Owner können
/// nicht eingeschränkt werden).
const Map<String, Set<String>> kRoleDefaultPermissions = {
  // Abschnitt 21: ADMIN bekommt NICHT automatisch
  // `employees.passwordResetApprove` (expliziter Default "NEIN" laut Spec) -
  // nur OWNER (immer, s.o.) und VICE_OWNER (s.u.) dürfen per Default
  // Mitarbeiter-Passwort-Resets freigeben.
  'ADMIN': {
    'employees.view',
    'employees.manage',
    'employees.create',
    'employees.editPermissions',
    'employees.sessionsManage',
    'audit.view',
    'search.view',
    'overview.view',
    'apiUsage.view',
    'jobs.view',
    'appControl.view',
    'appControl.manage',
    'devices.view',
    'support.view',
    'support.manage',
    'support.internalNotes',
    'support.assign',
    'news.view',
    'news.manage',
    'faq.view',
    'faq.manage',
    'advertising.view',
    'advertising.manage',
    'push.manage',
    'premium.view',
    'premium.manage',
    'premium.manualGrant',
    'premium.manualRevoke',
    'refunds.decide',
    'users.view',
    'users.manage',
    'users.suspend',
    'users.unsuspend',
    'users.viewSecurityReport',
    'users.viewBettingHistory',
    'ipBlocks.manage',
    'featureFlags.view',
    'featureFlags.manage',
    'release.view',
    'release.manage',
    'incidents.view',
    'incidents.manage',
    'security.view',
    'security.manage',
    'systemHealth.view',
  },
  // Abschnitt 21: VICE_OWNER ist praktisch ADMIN + der Sonderberechtigung,
  // Mitarbeiter-Passwort-Resets freizugeben (Default "JA", per Override
  // individuell einschränkbar).
  'VICE_OWNER': {
    'employees.view',
    'employees.manage',
    'employees.create',
    'employees.editPermissions',
    'employees.sessionsManage',
    'employees.passwordResetApprove',
    'audit.view',
    'search.view',
    'overview.view',
    'apiUsage.view',
    'jobs.view',
    'appControl.view',
    'appControl.manage',
    'devices.view',
    'support.view',
    'support.manage',
    'support.internalNotes',
    'support.assign',
    'news.view',
    'news.manage',
    'faq.view',
    'faq.manage',
    'advertising.view',
    'advertising.manage',
    'push.manage',
    'premium.view',
    'premium.manage',
    'premium.manualGrant',
    'premium.manualRevoke',
    'refunds.decide',
    'users.view',
    'users.manage',
    'users.suspend',
    'users.unsuspend',
    'users.viewSecurityReport',
    'users.viewBettingHistory',
    'ipBlocks.manage',
    'featureFlags.view',
    'featureFlags.manage',
    'release.view',
    'release.manage',
    'incidents.view',
    'incidents.manage',
    'security.view',
    'security.manage',
    'systemHealth.view',
  },
  'TECHNICAL': {
    'overview.view',
    'search.view',
    'apiUsage.view',
    'jobs.view',
    'appControl.view',
    'devices.view',
    'support.view',
    'users.view',
    'featureFlags.view',
    'featureFlags.manage',
    'release.view',
    'release.manage',
    'incidents.view',
    'incidents.manage',
    'security.view',
    'systemHealth.view',
  },
  // Abschnitt 77: "Support bekommt nur das, was für Support nötig ist" -
  // explizit KEIN users.suspend/unsuspend, KEIN users.viewSecurityReport,
  // KEIN users.viewBettingHistory per Default (Sperren/Security bleiben
  // ADMIN/VICE_OWNER/SECURITY vorbehalten, individuell per Override
  // erweiterbar).
  'SUPPORT': {
    'overview.view',
    'search.view',
    'devices.view',
    'users.view',
    'support.view',
    'support.manage',
    'support.internalNotes',
    'support.assign',
  },
  'CONTENT': {
    'overview.view',
    'search.view',
    'news.view',
    'news.manage',
    'faq.view',
    'faq.manage',
  },
  'MARKETING': {
    'overview.view',
    'search.view',
    'advertising.view',
    'advertising.manage',
    'push.manage',
  },
  // Neue Rolle (Abschnitt 15): Fokus auf Konto-/Netzwerksicherheit -
  // Sperren, Security-Reports, IP-Blocks, Anti-Abuse - aber bewusst OHNE
  // allgemeine Mitarbeiterverwaltung oder Premium-/Erstattungsrechte.
  'SECURITY': {
    'overview.view',
    'search.view',
    'devices.view',
    'users.view',
    'users.suspend',
    'users.unsuspend',
    'users.viewSecurityReport',
    'ipBlocks.manage',
    'support.view',
    'security.view',
    'security.manage',
    'audit.view',
  },
};

/// Prüft, ob [role] mit [permission] laut Rollen-Standardmatrix und
/// [overrides] (JSONB-Feld `permission_overrides`, `true` = gewähren,
/// `false` = entziehen, fehlender Key = Rollen-Standard gilt) berechtigt
/// ist. `OWNER` ist immer `true` und kann durch `overrides` nicht
/// eingeschränkt werden (Produktvorgabe).
bool hasPermissionForRole({
  required String role,
  required String permission,
  Map<String, Object?> overrides = const {},
}) {
  if (role == 'OWNER') return true;

  final override = overrides[permission];
  if (override is bool) return override;

  return kRoleDefaultPermissions[role]?.contains(permission) ?? false;
}
