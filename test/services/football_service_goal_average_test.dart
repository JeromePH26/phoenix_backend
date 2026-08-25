import 'package:phoenix_backend/src/services/football_service.dart';
import 'package:test/test.dart';

// Section "ENGINE-FEHLER VOLLSTÄNDIG UNTERSUCHEN UND BEHEBEN" (Claude
// AN2.txt, 2026-08-25): Regressionstests für den live beobachteten Bug bei
// Sheffield Wednesday vs. Wolves (Fixture 1623096) - Wolves hatten 0
// Auswärtsspiele, API-Football lieferte dafür "0.0" als Durchschnitt statt
// "keine Daten", wodurch beide Team-Torerwartungen künstlich auf 0,5 fielen.
void main() {
  group('FootballService.goalAverageIfPlayed', () {
    // Fall A (Section 18): genügend Daten vorhanden -> kein unnötiger
    // Fallback, der echte Wert bleibt erhalten.
    test('keeps the real average when the team has played in this split', () {
      expect(FootballService.goalAverageIfPlayed(1.8, 3), 1.8);
      expect(FootballService.goalAverageIfPlayed('2.70', 3), '2.70');
    });

    // Fall B (Section 18): Heimteam hat noch kein Heimspiel -> 0 Spiele
    // darf nicht als echte 0,0-Torquote durchgereicht werden.
    test('returns null (not the provider zero) when played is 0', () {
      expect(FootballService.goalAverageIfPlayed(0.0, 0), isNull);
      expect(FootballService.goalAverageIfPlayed('0.0', 0), isNull);
    });

    // Fall C (Section 18): Auswärtsteam hat noch kein Auswärtsspiel -> auch
    // ein String-"0" aus dem Provider (API-Football liefert played teils als
    // String) muss als "kein Spiel" erkannt werden.
    test('treats a string "0" played count the same as a numeric 0', () {
      expect(FootballService.goalAverageIfPlayed(0.0, '0'), isNull);
    });

    test('reproduces the exact live bug input (Sheffield Wednesday vs. Wolves, fixture 1623096)', () {
      // Wolves: awayPlayed = {away: 0, home: 3, total: 3}. Der Provider
      // meldete trotzdem awayGoalsForAverageAway = 0.0 und
      // awayGoalsAgainstAverageAway = 0.0 fuer den 0-Spiele-Auswaerts-Split.
      expect(FootballService.goalAverageIfPlayed(0.0, 0), isNull);
      // Der Heim-Split (3 Spiele) blieb davon unberuehrt und bleibt ein
      // echter Wert.
      expect(FootballService.goalAverageIfPlayed(2.7, 3), 2.7);
    });

    test('a genuinely low-scoring team (real games played) is not treated as missing data', () {
      // Ein Team, das in echten Spielen tatsaechlich 0 Tore erzielt hat,
      // darf NICHT mit "keine Daten" verwechselt werden - der Unterschied
      // ist ausschliesslich `played`, nicht der Torwert selbst.
      expect(FootballService.goalAverageIfPlayed(0.0, 5), 0.0);
    });

    test('missing/unparseable played count is treated as 0 (no data), not crashing', () {
      expect(FootballService.goalAverageIfPlayed(1.5, null), isNull);
      expect(FootballService.goalAverageIfPlayed(1.5, 'unknown'), isNull);
    });
  });
}
