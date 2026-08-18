/// PHÖNIX CONTROL CENTER: OWNER-Sonderregeln, die über die reine
/// Berechtigungsmatrix (`permissions.dart`) hinausgehen. Reine, deterministische
/// Funktionen - keine Datenbankzugriffe, damit sie ohne Postgres testbar
/// bleiben. Die Aufrufer (Routen) laden die nötigen Fakten (Zielrolle,
/// aktuelle Owner-Anzahl, ...) selbst aus der Datenbank.
library;

/// Nur ein `OWNER` darf einen neuen `OWNER` anlegen oder eine bestehende
/// Person zu `OWNER` befördern. Alle anderen Zielrollen sind für jeden mit
/// `employees.manage` erlaubt (die Berechtigung selbst wird separat über
/// [hasPermissionForRole] geprüft).
bool canAssignRole({required String actorRole, required String targetRole}) {
  if (targetRole == 'OWNER') return actorRole == 'OWNER';
  return true;
}

/// Nicht-Owner dürfen die Zeile eines `OWNER`-Mitarbeiters überhaupt nicht
/// anfassen (weder Rolle noch Status noch Overrides), unabhängig davon, was
/// im Request steht.
bool canModifyEmployeeRow({
  required String actorRole,
  required String targetCurrentRole,
}) {
  if (targetCurrentRole == 'OWNER') return actorRole == 'OWNER';
  return true;
}

/// Schützt vor versehentlichem Owner-Lockout (Produktvorgabe): das Deaktivieren
/// des letzten aktiven Owners ist immer verboten, unabhängig von der Rolle
/// der ausführenden Person.
///
/// [activeOwnerCount] ist die Anzahl aktueller `status = 'active'`-Owner
/// INKLUSIVE des Ziel-Mitarbeiters (so wie die DB sie vor der Änderung
/// zählt).
bool wouldRemoveLastActiveOwner({
  required bool targetIsOwner,
  required bool targetCurrentlyActive,
  required int activeOwnerCount,
}) {
  if (!targetIsOwner || !targetCurrentlyActive) return false;
  return activeOwnerCount <= 1;
}
