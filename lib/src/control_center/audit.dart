/// PHÖNIX CONTROL CENTER: Hilfsfunktion zum Bilden eines
/// `previousValue`/`newValue`-Diffs für `admin_audit_log`. Reine Funktion,
/// keine Datenbankzugriffe.
library;

/// Vergleicht [before] und [after] und liefert nur die Schlüssel zurück, bei
/// denen sich der Wert tatsächlich geändert hat - als
/// `(previousValue, newValue)`-Paar mit identischen Schlüsselmengen.
({Map<String, Object?> previousValue, Map<String, Object?> newValue})
    diffEmployeeFields({
  required Map<String, Object?> before,
  required Map<String, Object?> after,
}) {
  final previousValue = <String, Object?>{};
  final newValue = <String, Object?>{};

  for (final key in after.keys) {
    final beforeValue = before[key];
    final afterValue = after[key];
    if (_valuesEqual(beforeValue, afterValue)) continue;
    previousValue[key] = beforeValue;
    newValue[key] = afterValue;
  }

  return (previousValue: previousValue, newValue: newValue);
}

bool _valuesEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_valuesEqual(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}
