import 'package:phoenix_backend/src/model_lab/fixture_form_filter.dart';
import 'package:test/test.dart';

// Section "FREUNDSCHAFTSSPIELE UND ABGESAGTE SPIELE" (Claude AN2.txt,
// 2026-08-25): Regressionstests, ausgelöst durch die Wolves-Recent-Daten
// bei Fixture 1623096 (enthielten eine Freundschaftsspiel-Serie
// "Friendlies Clubs" und ein abgesagtes Spiel, status "CANC").
Map<String, Object?> fixtureRow({
  required String status,
  required String leagueName,
  int homeGoals = 1,
  int awayGoals = 0,
}) {
  return {
    'fixture': {
      'status': {'short': status},
    },
    'league': {'name': leagueName},
    'teams': {
      'home': {'id': 1},
      'away': {'id': 2},
    },
    'goals': {'home': homeGoals, 'away': awayGoals},
  };
}

void main() {
  group('isFriendlyFixture', () {
    test('detects "Friendlies Clubs" (the real value seen for Wolves)', () {
      expect(isFriendlyFixture(fixtureRow(status: 'FT', leagueName: 'Friendlies Clubs')), isTrue);
    });
    test('detects "Friendlies International"', () {
      expect(isFriendlyFixture(fixtureRow(status: 'FT', leagueName: 'Friendlies International')), isTrue);
    });
    test('a real competition is not a friendly', () {
      expect(isFriendlyFixture(fixtureRow(status: 'FT', leagueName: 'Championship')), isFalse);
      expect(isFriendlyFixture(fixtureRow(status: 'FT', leagueName: 'League Cup')), isFalse);
    });
  });

  group('selectFormFixtures', () {
    test('keeps a normal finished league match', () {
      final rows = [fixtureRow(status: 'FT', leagueName: 'Championship')];
      expect(selectFormFixtures(rows), hasLength(1));
    });

    test('excludes a cancelled fixture', () {
      final rows = [fixtureRow(status: 'CANC', leagueName: 'Friendlies Clubs')];
      expect(selectFormFixtures(rows), isEmpty);
    });

    test('excludes an abandoned fixture', () {
      final rows = [fixtureRow(status: 'ABD', leagueName: 'Championship')];
      expect(selectFormFixtures(rows), isEmpty);
    });

    test('excludes a postponed fixture with no result', () {
      final rows = [fixtureRow(status: 'PST', leagueName: 'Championship')];
      expect(selectFormFixtures(rows), isEmpty);
    });

    test(
      'prefers competitive matches over friendlies when enough competitive matches exist',
      () {
        final rows = [
          fixtureRow(status: 'FT', leagueName: 'Championship'),
          fixtureRow(status: 'FT', leagueName: 'Championship'),
          fixtureRow(status: 'FT', leagueName: 'League Cup'),
          fixtureRow(status: 'FT', leagueName: 'Friendlies Clubs'),
          fixtureRow(status: 'FT', leagueName: 'Friendlies Clubs'),
        ];
        final selected = selectFormFixtures(rows, limit: 3);
        expect(selected, hasLength(3));
        expect(selected.every((r) => !isFriendlyFixture(r)), isTrue);
      },
    );

    test(
      'falls back to friendlies as filler only when not enough competitive matches exist',
      () {
        final rows = [
          fixtureRow(status: 'FT', leagueName: 'Championship'),
          fixtureRow(status: 'FT', leagueName: 'Friendlies Clubs'),
          fixtureRow(status: 'CANC', leagueName: 'Friendlies Clubs'),
        ];
        final selected = selectFormFixtures(rows, limit: 5);
        // 1 Pflichtspiel + 1 Freundschaftsspiel (das abgesagte bleibt draußen).
        expect(selected, hasLength(2));
      },
    );

    test('reproduces the exact live scenario (Wolves recent data)', () {
      final rows = [
        fixtureRow(status: 'FT', leagueName: 'Championship'),
        fixtureRow(status: 'FT', leagueName: 'Championship'),
        fixtureRow(status: 'FT', leagueName: 'League Cup'),
        fixtureRow(status: 'FT', leagueName: 'Friendlies Clubs'),
        fixtureRow(status: 'CANC', leagueName: 'Friendlies Clubs'),
      ];
      final selected = selectFormFixtures(rows, limit: 5);
      // 3 echte Pflichtspiele reichen nicht bis zum Limit 5, also wird 1
      // Freundschaftsspiel als Lückenfüller ergänzt; das abgesagte Spiel
      // bleibt in jedem Fall draußen.
      expect(selected, hasLength(4));
    });
  });
}
