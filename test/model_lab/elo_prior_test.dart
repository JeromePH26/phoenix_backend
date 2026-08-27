import 'dart:math';

import 'package:phoenix_backend/src/model_lab/elo_prior.dart';
import 'package:phoenix_backend/src/model_lab/team_strength_engine.dart';
import 'package:test/test.dart';

void main() {
  group('EloPrior.fit', () {
    test('recovers a positive coefficient from Elo-driven supremacy', () {
      // Erzeuge Teams: höheres z -> stärkere Tor-Überlegenheit (k_true ~ 0.35).
      final rng = Random(1);
      const kTrue = 0.35;
      final obs = <({double z, double supremacyLog})>[];
      for (var i = 0; i < 400; i++) {
        final z = (rng.nextDouble() * 6) - 3;
        final noise = (rng.nextDouble() - 0.5) * 0.2;
        obs.add((z: z, supremacyLog: 2 * kTrue * z + noise));
      }
      final prior = EloPrior.fit(obs);
      expect(prior.k, closeTo(kTrue, 0.05));
    });

    test('too few observations -> neutral (k = 0)', () {
      final prior = EloPrior.fit(const [
        (z: 1.0, supremacyLog: 0.5),
        (z: -1.0, supremacyLog: -0.5),
      ]);
      expect(prior.k, 0);
    });

    test('forTeam: stronger team gets attack > 1 and defense < 1, mirrored', () {
      const prior = EloPrior(k: 0.4);
      final strong = prior.forTeam(
        elo: 1750,
        leagueMeanElo: 1500,
        leagueEloSd: 125,
      );
      expect(strong.attack, greaterThan(1.0));
      expect(strong.defense, lessThan(1.0));
      expect(strong.attack * strong.defense, closeTo(1.0, 1e-9));

      final weak = prior.forTeam(
        elo: 1250,
        leagueMeanElo: 1500,
        leagueEloSd: 125,
      );
      expect(weak.attack, lessThan(1.0));
    });

    test('forTeam: missing elo or zero sd -> neutral', () {
      const prior = EloPrior(k: 0.4);
      expect(
        prior.forTeam(elo: null, leagueMeanElo: 1500, leagueEloSd: 125).attack,
        1.0,
      );
      expect(
        prior.forTeam(elo: 1700, leagueMeanElo: 1500, leagueEloSd: 0).attack,
        1.0,
      );
    });

    test('forLeague applies one league-relative prior per known team', () {
      const prior = EloPrior(k: 0.25);
      final values = prior.forLeague({'strong': 1800, 'average': 1500, 'weak': 1200});

      expect(values.keys, containsAll(['strong', 'average', 'weak']));
      expect(values['strong']!.attack, greaterThan(1.0));
      expect(values['strong']!.defense, lessThan(1.0));
      expect(values['weak']!.attack, lessThan(1.0));
    });
  });

  group('EloPrior.standardize', () {
    test('produces standardized z and log supremacy', () {
      final rows = EloPrior.standardize(const [
        (eloDiff: 200, goalsFor: 40, goalsAgainst: 20),
        (eloDiff: 0, goalsFor: 25, goalsAgainst: 25),
        (eloDiff: -200, goalsFor: 15, goalsAgainst: 35),
      ]);
      expect(rows, hasLength(3));
      // Mittleres Team hat eloDiff = Mittelwert -> z ~ 0.
      expect(rows[1].z, closeTo(0.0, 1e-9));
      // Starkes Team: mehr erzielt als kassiert -> supremacyLog > 0.
      expect(rows[0].supremacyLog, greaterThan(0));
      expect(rows[2].supremacyLog, lessThan(0));
    });
  });

  group('TeamStrengthEngine.fit with priors', () {
    test('a thin-data team is pulled toward its Elo prior, not flat 1.0', () {
      // "weak" spielt nur 2 Spiele (dünn), Prior sagt schwacher Angriff.
      final matches = [
        for (var i = 0; i < 10; i++)
          MatchResult(
              homeTeamId: 'a', awayTeamId: 'b', homeGoals: 2, awayGoals: 1),
        for (var i = 0; i < 10; i++)
          MatchResult(
              homeTeamId: 'b', awayTeamId: 'a', homeGoals: 1, awayGoals: 2),
        MatchResult(
            homeTeamId: 'weak', awayTeamId: 'a', homeGoals: 3, awayGoals: 0),
        MatchResult(
            homeTeamId: 'b', awayTeamId: 'weak', homeGoals: 0, awayGoals: 3),
      ];
      final priors = {
        'weak': (attack: 0.6, defense: 1.4),
      };
      final withPrior =
          TeamStrengthEngine.fit(matches, priors: priors, regularizationK: 8);
      final withoutPrior = TeamStrengthEngine.fit(matches, regularizationK: 8);

      // Trotz des überraschenden 3:0 bleibt "weak" mit Prior näher an 0.6,
      // ohne Prior näher an 1.0 (Shrinkage-Ziel).
      expect(withPrior.attackOf('weak'), lessThan(withoutPrior.attackOf('weak')));
    });

    test('a cold-start team (no matches) returns its prior, not 1.0', () {
      final fit = TeamStrengthEngine.fit(
        [
          MatchResult(
              homeTeamId: 'x', awayTeamId: 'y', homeGoals: 1, awayGoals: 1),
        ],
        priors: {'ghost': (attack: 1.3, defense: 0.77)},
      );
      expect(fit.attackOf('ghost'), 1.3);
      expect(fit.defenseOf('ghost'), 0.77);
      expect(fit.attackOf('nobody'), TeamStrengthFit.neutralStrength);
    });

    test('empty priors is the exact old behaviour (regression anchor)', () {
      final matches = [
        for (var i = 0; i < 20; i++)
          MatchResult(
              homeTeamId: 'a', awayTeamId: 'b', homeGoals: 2, awayGoals: 1),
      ];
      final a = TeamStrengthEngine.fit(matches);
      final b = TeamStrengthEngine.fit(matches, priors: const {});
      expect(a.attackOf('a'), b.attackOf('a'));
      expect(a.homeAdvantage, b.homeAdvantage);
    });
  });
}
