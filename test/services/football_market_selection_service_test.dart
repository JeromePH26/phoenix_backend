import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/services/football_market_selection_service.dart';
import 'package:test/test.dart';

void main() {
  final service = FootballMarketSelectionService(
    database: PhoenixDatabase('postgres://unused/unused'),
  );

  Map<String, Object?> simulationWith({
    required Map<String, double> probabilities,
    Map<String, double> fairOdds = const {},
    int simulations = 10000,
    int dataQuality = 90,
  }) {
    return {
      'homeTeam': 'Home FC',
      'awayTeam': 'Away FC',
      'league': 'Test League',
      'kickoff': '2026-08-20T18:00:00Z',
      'probabilities': probabilities,
      'fairOdds': fairOdds,
      'goalExpectations': {'realXgAvailable': true},
      'aiContext': {},
      'dataQuality': dataQuality,
      'simulations': simulations,
    };
  }

  group('selectForFixture - primary tip market restriction', () {
    test(
      'never selects Doppelte Chance (dc1x/dcX2) as the phoenixTip even '
      'when it has the highest raw probability',
      () {
        // Regression test for the live production bug: NY Red Bulls vs.
        // Nashville stored dcX2 (Doppelte Chance X2, 70.4 %) as phoenixTip
        // even though the product rule only allows 1X2/BTTS/Over-Under 2.5
        // as the main recommendation.
        final selection = service.selectForFixture(
          fixtureId: '1490394',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.30,
              'draw': 0.26,
              'awayWin': 0.44,
              'dcX2': 0.70, // higher than any allowed core market
              'dc1x': 0.56,
              'over25': 0.60,
              'under25': 0.40,
              'bttsYes': 0.58,
              'bttsNo': 0.42,
            },
            fairOdds: {
              'homeWin': 3.3,
              'draw': 3.8,
              'awayWin': 2.3,
              'dcX2': 1.43,
              'dc1x': 1.79,
              'over25': 1.67,
              'under25': 2.5,
              'bttsYes': 1.72,
              'bttsNo': 2.4,
            },
          ),
          minimumProbabilityDecimal: 0.30,
        );

        expect(selection, isNotNull);
        final phoenixTip = selection!['phoenixTip'] as Map;
        expect(
          phoenixTip['marketKey'],
          isNot(anyOf('dcX2', 'dc1x', 'dnbHome', 'dnbAway')),
        );
        expect(
          phoenixTip['marketKey'],
          anyOf(
            'homeWin',
            'draw',
            'awayWin',
            'over25',
            'under25',
            'bttsYes',
            'bttsNo',
          ),
        );
      },
    );

    test(
      'still shows Doppelte Chance / DNB informationally in topMarkets and '
      'allMarkets (Marktcheck), just never as the phoenixTip',
      () {
        final selection = service.selectForFixture(
          fixtureId: '1490394',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.30,
              'draw': 0.26,
              'awayWin': 0.44,
              'dcX2': 0.70,
              'over25': 0.60,
              'under25': 0.40,
              'bttsYes': 0.58,
              'bttsNo': 0.42,
            },
            fairOdds: {
              'homeWin': 3.3,
              'draw': 3.8,
              'awayWin': 2.3,
              'dcX2': 1.43,
              'over25': 1.67,
              'under25': 2.5,
              'bttsYes': 1.72,
              'bttsNo': 2.4,
            },
          ),
          minimumProbabilityDecimal: 0.30,
        );

        expect(selection, isNotNull);
        final allMarkets = (selection!['allMarkets'] as List)
            .cast<Map<String, Object?>>();
        expect(
          allMarkets.any((m) => m['key'] == 'dcX2'),
          isTrue,
          reason: 'DC must remain visible informationally in allMarkets',
        );
      },
    );

    test(
      'never falls back to over35/under35 or DC as an emergency tip when '
      'no core market qualifies - returns null instead (Publish Gate)',
      () {
        final selection = service.selectForFixture(
          fixtureId: '999',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.0,
              'draw': 0.0,
              'awayWin': 0.0,
              'over25': 0.0,
              'under25': 0.0,
              'bttsYes': 0.0,
              'bttsNo': 0.0,
              'dcX2': 0.9,
              'over35': 0.9,
            },
          ),
          minimumProbabilityDecimal: 0.68,
        );

        expect(selection, isNull);
      },
    );

    test(
      'qualifiesForTip is false when simulations are 0, even if a core '
      'market probability would otherwise qualify (Publish Gate)',
      () {
        final selection = service.selectForFixture(
          fixtureId: '1490391',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.33,
              'draw': 0.24,
              'awayWin': 0.43,
              'over25': 0.60,
              'under25': 0.40,
              'bttsYes': 0.72,
              'bttsNo': 0.28,
            },
            simulations: 0,
            dataQuality: 91,
          ),
          minimumProbabilityDecimal: 0.30,
        );

        expect(selection, isNotNull);
        expect(selection!['qualifiesForTip'], isFalse);
        final trustComponents =
            (selection['trust'] as Map)['components'] as Map;
        expect(trustComponents['simulationCount'], 0);
      },
    );

    test(
      'never silently reports 100000 simulations when the raw field is '
      'missing - reports the honest value instead',
      () {
        final simulation = simulationWith(
          probabilities: {
            'homeWin': 0.33,
            'draw': 0.24,
            'awayWin': 0.43,
            'over25': 0.60,
            'under25': 0.40,
            'bttsYes': 0.72,
            'bttsNo': 0.28,
          },
        );
        simulation.remove('simulations');

        final selection = service.selectForFixture(
          fixtureId: '1490391',
          simulation: simulation,
          minimumProbabilityDecimal: 0.30,
        );

        expect(selection, isNotNull);
        final trustComponents =
            (selection!['trust'] as Map)['components'] as Map;
        expect(trustComponents['simulationCount'], 0);
      },
    );

    test(
      'homeWin/draw/awayWin/over25/under25/bttsYes/bttsNo remain fully '
      'eligible as the phoenixTip',
      () {
        final selection = service.selectForFixture(
          fixtureId: '1',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.20,
              'draw': 0.20,
              'awayWin': 0.20,
              'over25': 0.20,
              'under25': 0.20,
              'bttsYes': 0.80,
              'bttsNo': 0.20,
            },
            fairOdds: {'bttsYes': 1.30},
          ),
          minimumProbabilityDecimal: 0.30,
        );

        expect(selection, isNotNull);
        final phoenixTip = selection!['phoenixTip'] as Map;
        expect(phoenixTip['marketKey'], 'bttsYes');
      },
    );
  });
}
