import 'package:phoenix_backend/src/model_lab/team_name_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('TeamNameResolver.normalize', () {
    test('lowercases, strips accents and legal-form tokens', () {
      expect(TeamNameResolver.normalize('FC Bayern München'), 'bayern munchen');
      expect(TeamNameResolver.normalize('Atlético Madrid'), 'atletico madrid');
      expect(TeamNameResolver.normalize('AC Milan'), 'milan');
      expect(TeamNameResolver.normalize('Real Sociedad'), 'real sociedad');
    });

    test('applies the known abbreviation aliases', () {
      expect(TeamNameResolver.normalize('Man Utd'), 'manchester united');
      expect(TeamNameResolver.normalize('Spurs'), 'tottenham');
      expect(TeamNameResolver.normalize('Wolves'), 'wolverhampton');
      expect(
          TeamNameResolver.normalize("Nott'm Forest"), 'nottingham forest');
    });

    test('collapses separators and empty result for a pure legal form', () {
      expect(TeamNameResolver.normalize('  Real   Madrid  '), 'real madrid');
      expect(TeamNameResolver.normalize('FC'), '');
    });
  });

  group('TeamNameResolver.similarity', () {
    test('identical normalized names score 1, empty scores 0', () {
      expect(TeamNameResolver.similarity('inter', 'inter'), 1.0);
      expect(TeamNameResolver.similarity('', ''), 0.0);
    });

    test('near-identical names score high, unrelated names score low', () {
      expect(TeamNameResolver.similarity('bayern munchen', 'bayern munich'),
          greaterThan(0.7));
      expect(TeamNameResolver.similarity('arsenal', 'chelsea'), lessThan(0.4));
    });
  });

  group('TeamNameResolver.bestMatch', () {
    final candidates = {
      'manchester united': 't1',
      'manchester city': 't2',
      'liverpool': 't3',
      'arsenal': 't4',
    };

    test('a clear match returns the team id with status matched', () {
      final r = TeamMatchResult();
      final id = TeamNameResolver.bestMatch('Man Utd', candidates, result: r);
      expect(id, 't1');
      expect(r.status, TeamMatchStatus.matched);
      expect(r.bestScore, greaterThanOrEqualTo(TeamNameResolver.matchThreshold));
    });

    test('an unknown name returns null with status noMatch', () {
      final r = TeamMatchResult();
      final id =
          TeamNameResolver.bestMatch('Real Betis', candidates, result: r);
      expect(id, isNull);
      expect(r.status, TeamMatchStatus.noMatch);
    });

    test('a low-confidence best candidate is noMatch, not a guess', () {
      final r = TeamMatchResult();
      // "manchester" alone is ~0.5-0.6 to both manchester-* entries - below
      // the acceptance threshold, so no id is returned.
      final id =
          TeamNameResolver.bestMatch('Manchester', candidates, result: r);
      expect(id, isNull);
      expect(r.status, TeamMatchStatus.noMatch);
    });

    test('two candidates within the margin are rejected as ambiguous', () {
      final r = TeamMatchResult();
      // Both keys are one character off the input -> both >= threshold and
      // no clear winner.
      final id = TeamNameResolver.bestMatch(
        'red staz',
        {'red star': 't1', 'red stax': 't2'},
        result: r,
      );
      expect(id, isNull);
      expect(r.status, TeamMatchStatus.ambiguous);
      expect(r.bestScore, greaterThanOrEqualTo(TeamNameResolver.matchThreshold));
    });
  });

  group('TeamNameResolver.leagueNamePlausible', () {
    test('accepts a containing or keyword-overlapping name', () {
      expect(
          TeamNameResolver.leagueNamePlausible('Bundesliga', 'Bundesliga'), isTrue);
      expect(
          TeamNameResolver.leagueNamePlausible(
              'Primera Division', 'La Liga'),
          isFalse);
      expect(
          TeamNameResolver.leagueNamePlausible(
              'Serie A', 'Serie A'),
          isTrue);
    });
  });
}
