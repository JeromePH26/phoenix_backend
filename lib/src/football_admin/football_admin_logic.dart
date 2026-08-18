/// PHÖNIX CONTROL CENTER PHASE 2: Football-Domain-Admin-APIs (Matches,
/// Teams/Wappen & Assets, Datenqualität). Reine, deterministische
/// Hilfsfunktionen ohne Datenbankzugriff, damit die Kern-Business-Logik ohne
/// Postgres testbar bleibt (gleiches Prinzip wie
/// `lib/src/control_center/employee_rules.dart` aus Phase 1). Die
/// eigentlichen Routen (`lib/src/api/routes.dart`) und Datenbankzugriffe
/// (`lib/src/database/database.dart`) rufen diese Funktionen lediglich auf.
library;

/// JSON-Feldname (PATCH-Body) -> tatsächlicher Spaltenname in
/// `football_matches`. Bewusst eine feste, kleine Allowlist - nur diese fünf
/// booleschen Steuerungs-Flags dürfen über
/// `PATCH /api/admin/football/matches/<id>` verändert werden.
const Map<String, String> matchFlagJsonToColumn = {
  'visible': 'visible',
  'analysisEnabled': 'analysis_enabled',
  'tipEnabled': 'tip_enabled',
  'learningEnabled': 'learning_enabled',
  'liveEnabled': 'live_enabled',
};

/// Ergebnis des Parsens/Validierens eines PATCH-Bodys für
/// `/api/admin/football/matches/<id>`.
class MatchFlagsPatchResult {
  const MatchFlagsPatchResult({
    this.flags = const <String, bool>{},
    this.reason,
    this.comment,
    this.error,
  });

  /// Nur die tatsächlich übergebenen Flags, keyed by DB-Spaltenname (nicht
  /// JSON-Feldname), damit der Aufrufer sie direkt in ein `SET ...`
  /// einsetzen kann.
  final Map<String, bool> flags;
  final String? reason;
  final String? comment;

  /// Nutzerlesbare Fehlermeldung; `null` bedeutet: Body war gültig.
  final String? error;

  bool get isValid => error == null;
}

/// Validiert den PATCH-Body für die Flags-Aktualisierung eines Matches.
/// Erlaubt ist ein beliebiges, nicht-leeres Subset von
/// [matchFlagJsonToColumn] als Boolean, plus optionale String-Felder
/// `reason`/`comment`. Unbekannte Felder oder falsche Typen führen zu einem
/// Fehler statt stillschweigend ignoriert zu werden, damit ein Tippfehler im
/// Frontend nicht unbemerkt wirkungslos bleibt.
MatchFlagsPatchResult parseMatchFlagsPatch(Map<String, Object?> body) {
  final flags = <String, bool>{};

  for (final entry in body.entries) {
    if (entry.key == 'reason' || entry.key == 'comment') continue;
    final column = matchFlagJsonToColumn[entry.key];
    if (column == null) {
      return MatchFlagsPatchResult(error: 'Unbekanntes Feld: ${entry.key}');
    }
    if (entry.value is! bool) {
      return MatchFlagsPatchResult(
        error: '${entry.key} muss ein Boolean sein.',
      );
    }
    flags[column] = entry.value as bool;
  }

  if (flags.isEmpty) {
    return const MatchFlagsPatchResult(
      error:
          'Mindestens ein Flag (visible, analysisEnabled, tipEnabled, '
          'learningEnabled, liveEnabled) muss angegeben werden.',
    );
  }

  final rawReason = body['reason'];
  final rawComment = body['comment'];

  return MatchFlagsPatchResult(
    flags: flags,
    reason: (rawReason is String && rawReason.trim().isNotEmpty)
        ? rawReason.trim()
        : null,
    comment: (rawComment is String && rawComment.trim().isNotEmpty)
        ? rawComment.trim()
        : null,
  );
}

/// Kehrt [matchFlagJsonToColumn] um (Spaltenname -> JSON-Feldname), damit
/// eine Antwort dem Frontend dieselben camelCase-Namen zurückgeben kann, die
/// es im Request geschickt hat, statt roher DB-Spaltennamen.
final Map<String, String> matchFlagColumnToJson = {
  for (final entry in matchFlagJsonToColumn.entries) entry.value: entry.key,
};

/// Übersetzt ein Spaltenname-keyed Flags-Map (wie es die DB-Schicht liefert)
/// zurück in JSON-Feldnamen für die Response.
Map<String, bool> mapFlagsToJsonKeys(Map<String, bool> flagsByColumn) {
  return {
    for (final entry in flagsByColumn.entries)
      (matchFlagColumnToJson[entry.key] ?? entry.key): entry.value,
  };
}

/// Übersetzt eine rohe `football_matches`-Zeile (Spaltennamen aus
/// `toColumnMap()`, z.B. `league_id`, `home_team_name`, `analysis_enabled`)
/// in die camelCase-/verschachtelte JSON-Form, die das Control-Center-
/// Frontend erwartet (`league: {id, name}`, `homeTeam: {id, name, logoUrl}`,
/// `kickoffUtc`, `hasAnalysis`, ...). Extra-Schlüssel aus [row] (z.B.
/// `updated_at`, `raw_json`), die nicht Teil des festen Vertrags sind, werden
/// unverändert durchgereicht, damit nichts still verloren geht.
Map<String, Object?> mapMatchRowToJson(Map<String, Object?> row) {
  const known = {
    'id',
    'kickoff_utc',
    'status',
    'league_id',
    'league_name',
    'country',
    'home_team_id',
    'home_team_name',
    'home_logo',
    'away_team_id',
    'away_team_name',
    'away_logo',
    'home_goals',
    'away_goals',
    'visible',
    'analysis_enabled',
    'tip_enabled',
    'learning_enabled',
    'live_enabled',
    'has_analysis',
  };

  final json = <String, Object?>{
    'id': row['id'],
    'kickoffUtc': row['kickoff_utc'],
    'status': row['status'],
    'league': {
      'id': row['league_id'],
      'name': row['league_name'],
      'country': row['country'],
    },
    'homeTeam': {
      'id': row['home_team_id'],
      'name': row['home_team_name'],
      'logoUrl': row['home_logo'],
    },
    'awayTeam': {
      'id': row['away_team_id'],
      'name': row['away_team_name'],
      'logoUrl': row['away_logo'],
    },
    'homeGoals': row['home_goals'],
    'awayGoals': row['away_goals'],
    'visible': row['visible'],
    'analysisEnabled': row['analysis_enabled'],
    'tipEnabled': row['tip_enabled'],
    'learningEnabled': row['learning_enabled'],
    'liveEnabled': row['live_enabled'],
    'hasAnalysis': row['has_analysis'],
  };

  for (final entry in row.entries) {
    if (!known.contains(entry.key)) {
      json[entry.key] = entry.value;
    }
  }

  return json;
}

/// `limit`-Query-Parameter für Listen-Endpunkte: `null`/ungültig -> Default,
/// niemals über `maxValue` und niemals unter 1.
int clampListLimit(
  int? requested, {
  int defaultValue = 50,
  int maxValue = 200,
}) {
  if (requested == null || requested < 1) return defaultValue;
  return requested > maxValue ? maxValue : requested;
}

/// `offset`-Query-Parameter: `null`/negativ -> 0.
int clampOffset(int? requested) {
  if (requested == null || requested < 0) return 0;
  return requested;
}

/// Parst einen `true`/`false`-Query-Parameter. `null` bedeutet "nicht
/// gesetzt" (Filter deaktiviert) - unterscheidet sich bewusst von `false`.
/// Ein ungültiger Wert (z.B. "yes") wird ebenfalls als "nicht gesetzt"
/// behandelt statt einen Serverfehler auszulösen.
bool? parseBoolParam(String? value) {
  if (value == null) return null;
  final normalized = value.trim().toLowerCase();
  if (normalized == 'true') return true;
  if (normalized == 'false') return false;
  return null;
}

/// Ab wann ein gecachtes Wappen/Logo als veraltet ("STALE") gilt. 90 Tage ist
/// eine bewusst gewählte, dokumentierte Schwelle - Vereinslogos ändern sich
/// selten, aber ein Cache, der seit über drei Monaten nicht mehr aktualisiert
/// wurde, sollte einem Admin auffallen, falls die Quelle inzwischen ein neues
/// Bild liefert (z.B. nach einem Rebranding).
const Duration kAssetStaleAfter = Duration(days: 90);

/// Berechnet den Anzeige-Status eines Team-/Liga-Assets für
/// `GET /api/admin/football/assets`:
/// - `MISSING`: nicht gecacht oder leerer Bildinhalt.
/// - `STALE`: gecacht, aber seit [staleAfter] nicht mehr aktualisiert.
/// - `OK`: gecacht und aktuell.
String computeAssetStatus({
  required bool cached,
  required bool hasBytes,
  DateTime? updatedAt,
  required DateTime now,
  Duration staleAfter = kAssetStaleAfter,
}) {
  if (!cached || !hasBytes) return 'MISSING';
  if (updatedAt != null && now.difference(updatedAt) > staleAfter) {
    return 'STALE';
  }
  return 'OK';
}

/// Erlaubte Content-Types für einen Asset-Replace-Upload. Deckungsgleich mit
/// den Bildformaten, die die Sportdaten-API tatsächlich liefert
/// (`FootballAssetService`), plus SVG für manuell hochgeladene Vektorlogos.
const Set<String> kAllowedAssetContentTypes = {
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/svg+xml',
};

bool isAllowedAssetContentType(String? contentType) {
  if (contentType == null) return false;
  return kAllowedAssetContentTypes.contains(contentType.trim().toLowerCase());
}

/// Obergrenze für einen manuellen Asset-Replace-Upload (Produktvorgabe:
/// "nicht absurd groß", hier konkret auf 5MB festgelegt).
const int kMaxAssetReplaceBytes = 5 * 1024 * 1024;

/// Validiert einen Asset-Replace-Request. Gibt bei einem Fehler eine
/// nutzerlesbare Meldung zurück, sonst `null`.
String? validateAssetReplacePayload({
  required String? contentType,
  required int byteLength,
  int maxBytes = kMaxAssetReplaceBytes,
}) {
  if (!isAllowedAssetContentType(contentType)) {
    return 'contentType muss image/png, image/jpeg, image/webp oder '
        'image/svg+xml sein.';
  }
  if (byteLength <= 0) {
    return 'Bilddaten (imageBase64) fehlen.';
  }
  if (byteLength > maxBytes) {
    final maxMb = (maxBytes / (1024 * 1024)).toStringAsFixed(0);
    return 'Bilddatei ist zu groß (maximal ${maxMb}MB).';
  }
  return null;
}
