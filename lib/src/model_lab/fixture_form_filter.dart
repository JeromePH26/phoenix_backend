/// Section "FREUNDSCHAFTSSPIELE UND ABGESAGTE SPIELE" (Claude AN2.txt,
/// 2026-08-25): geteilte, testbare Filterlogik für rohe API-Football-
/// Fixture-Einträge (wie sie in `homeRecentData`/`awayRecentData`/`h2hData`
/// gespeichert werden - siehe `FootballService.coverageForFixture`), damit
/// Form-/Torraten-Berechnungen nicht durch abgesagte, abgebrochene,
/// ergebnislos verschobene oder unverbindliche Freundschaftsspiele verzerrt
/// werden. Vorher duplizierten `GlobalMarketEngine` und `GlobalGoalsV1Engine`
/// jeweils ihre eigene, unvollständige `_finishedStatuses`-Prüfung (keine
/// von beiden kannte Freundschaftsspiele) - diese Datei ist jetzt die
/// einzige Stelle, an der die Regel lebt.
library fixture_form_filter;

/// Nur Spiele mit einem echten Endstand zählen für Form-/Torraten-Zwecke.
/// Abgesagte (`CANC`), abgebrochene (`ABD`) und ergebnislos verschobene
/// (`PST`) Spiele werden über diese Positivliste automatisch ausgeschlossen
/// - ergänzt `AWD`/`WO` (kampflos entschieden), da dort ein echtes Ergebnis
/// feststeht, auch ohne gespielte 90 Minuten.
const finishedMatchStatuses = {'FT', 'AET', 'PEN', 'AWD', 'WO'};

bool _isFinishedResult(Map<String, Object?> fixtureRow) {
  final fixture = fixtureRow['fixture'];
  final status = fixture is Map ? fixture['status'] : null;
  final short = status is Map ? status['short']?.toString() : null;
  return short != null && finishedMatchStatuses.contains(short);
}

/// API-Football liefert für Freundschaftsspiele keinen eigenen `type`, aber
/// einen unverwechselbaren `league.name` ("Friendlies", "Friendlies Clubs",
/// "Friendlies International", ...) - Substring-Match statt exaktem
/// Vergleich, damit keine der Varianten durchrutscht.
bool isFriendlyFixture(Map<String, Object?> fixtureRow) {
  final league = fixtureRow['league'];
  final name = league is Map ? league['name']?.toString().toLowerCase() : null;
  return name != null && name.contains('friendl');
}

/// Section 4: Pflichtspiele werden bevorzugt, Freundschaftsspiele nur
/// verwendet, wenn ohne sie nicht genug Pflichtspiele übrig bleiben.
/// Deshalb kein hartes Ausschlusskriterium hier, sondern ein zweistufiges
/// Verfahren über [selectFormFixtures] weiter unten - diese Funktion prüft
/// nur die nicht verhandelbaren Fälle (kein Ergebnis vorhanden).
bool hasUsableResult(Map<String, Object?> fixtureRow) => _isFinishedResult(fixtureRow);

/// Wählt aus einer rohen Fixture-Liste (`homeRecentData`/`awayRecentData`/
/// `h2hData`) bis zu [limit] für Form-/Torraten-Berechnungen nutzbare
/// Spiele. Abgesagte/abgebrochene/ergebnislose Spiele werden immer
/// ausgeschlossen. Freundschaftsspiele werden nur verwendet, wenn nicht
/// bereits [limit] Pflichtspiele vorhanden sind - Pflichtspiele haben also
/// in jedem Fall Vorrang, Freundschaftsspiele füllen nur echte Lücken auf
/// (z.B. direkt nach der Sommerpause, wenn noch kaum Pflichtspiele
/// stattgefunden haben).
List<Map<String, Object?>> selectFormFixtures(
  List<dynamic> rawFixtures, {
  int limit = 5,
}) {
  final competitive = <Map<String, Object?>>[];
  final friendlies = <Map<String, Object?>>[];

  for (final entry in rawFixtures) {
    if (entry is! Map) continue;
    final row = Map<String, Object?>.from(entry);
    if (!hasUsableResult(row)) continue;
    if (isFriendlyFixture(row)) {
      friendlies.add(row);
    } else {
      competitive.add(row);
    }
  }

  if (competitive.length >= limit) return competitive.take(limit).toList();
  return [...competitive, ...friendlies].take(limit).toList();
}
