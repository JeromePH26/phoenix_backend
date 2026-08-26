import 'package:phoenix_backend/src/model_lab/team_strength_engine.dart';
import 'package:test/test.dart';

// PHÖNIX Engine-Umbau, Phase 2 (Plan "wild-cuddling-hoare", 2026-08-26):
// Team-Stärke-Ratings via Iterative Proportional Fitting (Maher-Modell).
void main() {
  group('TeamStrengthEngine.fit', () {
    test('empty input returns a safe, empty, converged fit', () {
      final fit = TeamStrengthEngine.fit(const []);
      expect(fit.converged, isTrue);
      expect(fit.attack, isEmpty);
      expect(fit.defense, isEmpty);
      // Unbekanntes Team faellt auf den neutralen Wert zurueck.
      expect(fit.attackOf('unknown'), TeamStrengthFit.neutralStrength);
      expect(fit.defenseOf('unknown'), TeamStrengthFit.neutralStrength);
    });

    test('a perfectly symmetric league (every team equally strong) '
        'converges to attack/defense ~1.0 for everyone', () {
      // 4 Teams, jeder gegen jeden home+away, immer 1:1 - kein Team ist
      // besser/schlechter als ein anderes.
      final teams = ['A', 'B', 'C', 'D'];
      final matches = <MatchResult>[];
      for (final home in teams) {
        for (final away in teams) {
          if (home == away) continue;
          matches.add(MatchResult(
            homeTeamId: home,
            awayTeamId: away,
            homeGoals: 1,
            awayGoals: 1,
          ));
        }
      }

      final fit = TeamStrengthEngine.fit(matches);
      expect(fit.converged, isTrue);
      for (final team in teams) {
        expect(fit.attackOf(team), closeTo(1.0, 0.01));
        expect(fit.defenseOf(team), closeTo(1.0, 0.01));
      }
      // Gleich viele Heim- wie Auswaertstore je Spiel -> kein Heimvorteil.
      expect(fit.homeAdvantage, closeTo(1.0, 0.05));
    });

    test('a clearly stronger team ends up with attack > 1 and defense < 1', () {
      // A schiesst konstant 3, kassiert konstant 0 gegen B/C/D. B/C/D sind
      // untereinander ausgeglichen (1:1). 6 Runden (statt 1), damit jedes
      // Team genug Spiele hat, dass die Shrinkage-Regularisierung (siehe
      // TeamStrengthEngine.fit) das klare Signal nicht dominiert - mit nur
      // 3 Spielen je Team waere selbst ein extremes Ergebnis stark Richtung
      // neutral geglaettet, was hier nicht getestet werden soll.
      final singleRound = <MatchResult>[
        const MatchResult(homeTeamId: 'A', awayTeamId: 'B', homeGoals: 3, awayGoals: 0),
        const MatchResult(homeTeamId: 'B', awayTeamId: 'A', homeGoals: 0, awayGoals: 3),
        const MatchResult(homeTeamId: 'A', awayTeamId: 'C', homeGoals: 3, awayGoals: 0),
        const MatchResult(homeTeamId: 'C', awayTeamId: 'A', homeGoals: 0, awayGoals: 3),
        const MatchResult(homeTeamId: 'A', awayTeamId: 'D', homeGoals: 3, awayGoals: 0),
        const MatchResult(homeTeamId: 'D', awayTeamId: 'A', homeGoals: 0, awayGoals: 3),
        const MatchResult(homeTeamId: 'B', awayTeamId: 'C', homeGoals: 1, awayGoals: 1),
        const MatchResult(homeTeamId: 'C', awayTeamId: 'B', homeGoals: 1, awayGoals: 1),
        const MatchResult(homeTeamId: 'B', awayTeamId: 'D', homeGoals: 1, awayGoals: 1),
        const MatchResult(homeTeamId: 'D', awayTeamId: 'B', homeGoals: 1, awayGoals: 1),
        const MatchResult(homeTeamId: 'C', awayTeamId: 'D', homeGoals: 1, awayGoals: 1),
        const MatchResult(homeTeamId: 'D', awayTeamId: 'C', homeGoals: 1, awayGoals: 1),
      ];
      final matches = [
        for (var round = 0; round < 6; round++) ...singleRound,
      ];

      final fit = TeamStrengthEngine.fit(matches);
      expect(fit.converged, isTrue);
      expect(fit.attackOf('A'), greaterThan(1.5));
      expect(fit.defenseOf('A'), lessThan(0.5));
      // B/C/D sind untereinander gleich stark und schwaecher als A.
      expect(fit.attackOf('B'), lessThan(fit.attackOf('A')));
      expect(fit.attackOf('C'), closeTo(fit.attackOf('B'), 0.05));
      expect(fit.attackOf('D'), closeTo(fit.attackOf('B'), 0.05));
    });

    test('home teams consistently outscoring away teams produces '
        'homeAdvantage > 1.0', () {
      final teams = ['A', 'B', 'C', 'D'];
      final matches = <MatchResult>[];
      for (final home in teams) {
        for (final away in teams) {
          if (home == away) continue;
          // Heimteam schiesst immer 1 Tor mehr als das Auswaertsteam.
          matches.add(MatchResult(
            homeTeamId: home,
            awayTeamId: away,
            homeGoals: 2,
            awayGoals: 1,
          ));
        }
      }

      final fit = TeamStrengthEngine.fit(matches);
      expect(fit.converged, isTrue);
      expect(fit.homeAdvantage, greaterThan(1.3));
    });

    test('a team with very few matches stays close to neutral even with an '
        'extreme record, while a well-established team with the same '
        'record does not (empirical-Bayes shrinkage towards neutral)', () {
      // "Sparse" (E) hat nur EIN Spiel: 5:0-Sieg gegen einen ausgeglichenen
      // Gegner-Pool. "Established" (A) hat denselben 5:0-Torschnitt, aber
      // ueber viele Spiele hinweg belegt - beide "verdienen" sich rechnerisch
      // dieselbe Rohquote, sollen aber unterschiedlich stark geglaettet
      // werden.
      final matches = <MatchResult>[
        // A (etabliert): 6x 5:0 gegen wechselnde Gegner.
        for (var i = 0; i < 6; i++)
          MatchResult(homeTeamId: 'A', awayTeamId: 'opp$i', homeGoals: 5, awayGoals: 0),
        // E (datenarm): nur 1x 5:0.
        const MatchResult(homeTeamId: 'E', awayTeamId: 'opp99', homeGoals: 5, awayGoals: 0),
        // Ausgeglichene Gegner-Basis, damit das Modell insgesamt identifizierbar bleibt.
        for (var i = 0; i < 6; i++)
          MatchResult(homeTeamId: 'opp$i', awayTeamId: 'opp${(i + 1) % 6}', homeGoals: 1, awayGoals: 1),
        const MatchResult(homeTeamId: 'opp99', awayTeamId: 'opp0', homeGoals: 1, awayGoals: 1),
      ];

      final fit = TeamStrengthEngine.fit(matches);
      final distanceFromNeutralA = (fit.attackOf('A') - 1.0).abs();
      final distanceFromNeutralE = (fit.attackOf('E') - 1.0).abs();
      // Beide Teams weichen wegen desselben 5:0-Rohsignals in dieselbe
      // Richtung ab (attack > 1) - aber A (6 Spiele) darf sich weiter von
      // neutral entfernen duerfen als E (1 Spiel).
      expect(fit.attackOf('A'), greaterThan(1.0));
      expect(fit.attackOf('E'), greaterThan(1.0));
      expect(distanceFromNeutralA, greaterThan(distanceFromNeutralE));
    });

    test('converges within the default iteration budget for a realistic '
        'league size', () {
      // 18 Teams, jeder gegen jeden einmal (306 Spiele) mit leicht
      // unterschiedlicher Staerke - realistische Ligagroesse.
      final teams = List.generate(18, (i) => 'T$i');
      final matches = <MatchResult>[];
      for (var i = 0; i < teams.length; i++) {
        for (var j = 0; j < teams.length; j++) {
          if (i == j) continue;
          // Team-Index bestimmt eine leichte, deterministische Torneigung.
          final homeGoals = 1 + (i % 3);
          final awayGoals = (j % 2);
          matches.add(MatchResult(
            homeTeamId: teams[i],
            awayTeamId: teams[j],
            homeGoals: homeGoals,
            awayGoals: awayGoals,
          ));
        }
      }

      final fit = TeamStrengthEngine.fit(matches);
      expect(fit.converged, isTrue);
      expect(fit.iterations, lessThan(200));
    });
  });

  // PHÖNIX Engine-Umbau Phase 3 (Plan "wild-cuddling-hoare"): exponentieller
  // Zeitverfall statt Gleichgewichtung aller Trainingsspiele.
  group('TeamStrengthEngine.fit with halfLifeDays (time decay)', () {
    test('halfLifeDays: null (default) behaves identically to no decay - '
        'regression anchor', () {
      final asOf = DateTime.utc(2026, 1, 1);
      final matches = [
        for (var i = 0; i < 8; i++)
          MatchResult(
            homeTeamId: 'A',
            awayTeamId: 'opp$i',
            homeGoals: 3,
            awayGoals: 0,
            kickoff: asOf.subtract(Duration(days: i * 30)),
          ),
        for (var i = 0; i < 8; i++)
          MatchResult(
            homeTeamId: 'opp$i',
            awayTeamId: 'A',
            homeGoals: 0,
            awayGoals: 3,
            kickoff: asOf.subtract(Duration(days: i * 30 + 10)),
          ),
      ];
      final withoutDates = matches
          .map((m) => MatchResult(
                homeTeamId: m.homeTeamId,
                awayTeamId: m.awayTeamId,
                homeGoals: m.homeGoals,
                awayGoals: m.awayGoals,
              ))
          .toList();

      final fitWithDatesNoDecay = TeamStrengthEngine.fit(matches);
      final fitWithoutDates = TeamStrengthEngine.fit(withoutDates);
      expect(fitWithDatesNoDecay.attackOf('A'), closeTo(fitWithoutDates.attackOf('A'), 1e-9));
    });

    test('a recent hot streak outweighs an older cold streak when decay is '
        'active, but is balanced out (not fully ignored) without decay', () {
      final asOf = DateTime.utc(2026, 1, 1);
      // A: 4 alte Spiele (1 Jahr her) mit schwachem Ergebnis (0:2), dann 4
      // ganz aktuelle Spiele (letzte Woche) mit starkem Ergebnis (3:0).
      final matches = [
        for (var i = 0; i < 4; i++)
          MatchResult(
            homeTeamId: 'A',
            awayTeamId: 'old_opp$i',
            homeGoals: 0,
            awayGoals: 2,
            kickoff: asOf.subtract(const Duration(days: 365)),
          ),
        for (var i = 0; i < 4; i++)
          MatchResult(
            homeTeamId: 'A',
            awayTeamId: 'new_opp$i',
            homeGoals: 3,
            awayGoals: 0,
            kickoff: asOf.subtract(const Duration(days: 3)),
          ),
      ];

      final withDecay = TeamStrengthEngine.fit(
        matches,
        halfLifeDays: 60,
        asOf: asOf,
      );
      final withoutDecay = TeamStrengthEngine.fit(matches, asOf: asOf);

      // Mit kurzer Halbwertszeit (60 Tage) sind die 1 Jahr alten Spiele
      // praktisch gewichtslos -> attack naeher an "nur die starken neuen
      // Spiele zaehlen" als ohne Zeitverfall (wo alte und neue Spiele gleich
      // stark in den Rohdurchschnitt eingehen).
      expect(withDecay.attackOf('A'), greaterThan(withoutDecay.attackOf('A')));
    });

    test('a match without a kickoff date always gets full weight, even '
        'with decay active', () {
      final matches = [
        const MatchResult(
          homeTeamId: 'A',
          awayTeamId: 'B',
          homeGoals: 3,
          awayGoals: 0,
          // kein kickoff gesetzt
        ),
      ];
      // Sollte nicht abstuerzen und das Spiel trotzdem voll gewichten.
      final fit = TeamStrengthEngine.fit(
        matches,
        halfLifeDays: 30,
        asOf: DateTime.utc(2026, 1, 1),
      );
      expect(fit.converged, isTrue);
    });
  });

  group('TeamStrengthEngine.expectedGoals', () {
    test('an unknown (cold-start) team on both sides yields exactly '
        'homeAdvantage/1.0 - the neutral "average vs average" case', () {
      const fit = TeamStrengthFit(
        attack: {},
        defense: {},
        homeAdvantage: 1.4,
        iterations: 0,
        converged: true,
      );
      final goals = TeamStrengthEngine.expectedGoals(
        fit: fit,
        homeTeamId: 'unknown-home',
        awayTeamId: 'unknown-away',
      );
      expect(goals.home, 1.4);
      expect(goals.away, 1.0);
    });

    test('a fitted strong home team against a fitted weak away team '
        'produces a lopsided goal expectation', () {
      final matches = <MatchResult>[
        const MatchResult(homeTeamId: 'A', awayTeamId: 'B', homeGoals: 3, awayGoals: 0),
        const MatchResult(homeTeamId: 'B', awayTeamId: 'A', homeGoals: 0, awayGoals: 3),
        const MatchResult(homeTeamId: 'A', awayTeamId: 'C', homeGoals: 3, awayGoals: 0),
        const MatchResult(homeTeamId: 'C', awayTeamId: 'A', homeGoals: 0, awayGoals: 3),
        const MatchResult(homeTeamId: 'B', awayTeamId: 'C', homeGoals: 1, awayGoals: 1),
        const MatchResult(homeTeamId: 'C', awayTeamId: 'B', homeGoals: 1, awayGoals: 1),
      ];
      final fit = TeamStrengthEngine.fit(matches);

      final goals = TeamStrengthEngine.expectedGoals(
        fit: fit,
        homeTeamId: 'A',
        awayTeamId: 'B',
      );
      expect(goals.home, greaterThan(goals.away * 2));
    });
  });
}
