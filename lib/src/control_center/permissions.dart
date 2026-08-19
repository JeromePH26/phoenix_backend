/// PHÖNIX CONTROL CENTER: Rollen- und Berechtigungsmodell (additiv, separat
/// vom bestehenden statischen `PHOENIX_ADMIN_TOKEN`-Mechanismus in
/// `routes.dart`/`model_lab_routes.dart`). Reine, deterministische Logik -
/// keine Datenbankzugriffe, damit sie ohne Postgres testbar bleibt.
library;

/// Die fünf erlaubten Mitarbeiterrollen. `OWNER` steht bewusst nicht in
/// [kAssignableNonOwnerRoles], weil das Zuweisen von `OWNER` einer eigenen
/// Prüfung unterliegt (siehe `employee_rules.dart`).
const Set<String> kValidRoles = {
  'OWNER',
  'ADMIN',
  'TECHNICAL',
  'SUPPORT',
  'CONTENT',
  'MARKETING',
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
};

/// Standard-Berechtigungen je Rolle. `OWNER` taucht hier absichtlich nicht
/// auf - Owner erhalten in [hasPermission] immer `true`, unabhängig von
/// dieser Tabelle und unabhängig von `permission_overrides` (Owner können
/// nicht eingeschränkt werden).
const Map<String, Set<String>> kRoleDefaultPermissions = {
  'ADMIN': {
    'employees.view',
    'employees.manage',
    'audit.view',
    'search.view',
    'overview.view',
    'apiUsage.view',
    'jobs.view',
    'appControl.view',
    'appControl.manage',
  },
  'TECHNICAL': {
    'overview.view',
    'search.view',
    'apiUsage.view',
    'jobs.view',
    'appControl.view',
  },
  'SUPPORT': {'overview.view', 'search.view'},
  'CONTENT': {'overview.view', 'search.view'},
  'MARKETING': {'overview.view', 'search.view'},
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
