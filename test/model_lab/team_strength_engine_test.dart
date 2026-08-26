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
      // untereinander ausgeglichen (1:1).
      final matches = <MatchResult>[
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
