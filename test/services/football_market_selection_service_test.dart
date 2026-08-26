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

  group('selectForFixture - balanced primary markets', () {
    test(
      // Section 7 (Claude AN2.txt, "DOPPELTE CHANCE DARF NICHT HAUPTTIPP
      // WERDEN"): Doppelte Chance darf nie mehr der PHÖNIX-Haupttipp
      // werden, selbst wenn es klar die höchste Einzelwahrscheinlichkeit
      // hat - live beobachtet an Fixture 1623096 (Sheffield Wednesday vs.
      // Wolves), wo "Doppelte Chance 1X" als Haupttipp gewählt wurde.
      'never selects Doppelte Chance as the main tip, even with the '
      'highest probability - falls through to the best eligible core market',
      () {
        final selection = service.selectForFixture(
          fixtureId: '1490394',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.30,
              'draw': 0.26,
              'awayWin': 0.44,
              'dcX2': 0.80,
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
        // over25 (60%) is the highest-probability market among the
        // allowed set (1X2/BTTS/Über-Unter 2,5) - dcX2 (80%) is a
        // computed/displayed market but never eligible as the main tip.
        expect(phoenixTip['marketKey'], 'over25');
      },
    );

    test(
      'includes the requested diverse markets in the public market check',
      () {
        final selection = service.selectForFixture(
          fixtureId: '1490394',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.30,
              'draw': 0.26,
              'awayWin': 0.44,
              'dcX2': 0.70,
              'over15': 0.72,
              'over35': 0.44,
              'under35': 0.56,
              'homeOver15': 0.55,
              'homeUnder15': 0.45,
              'awayOver15': 0.45,
              'awayUnder15': 0.55,
              'homeOver25': 0.24,
              'homeUnder25': 0.76,
              'awayOver25': 0.18,
              'awayUnder25': 0.82,
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
              'over15': 1.39,
              'over35': 2.3,
              'under35': 1.8,
              'homeOver15': 1.82,
              'homeUnder15': 2.22,
              'awayOver15': 2.22,
              'awayUnder15': 1.82,
              'homeOver25': 4.17,
              'homeUnder25': 1.32,
              'awayOver25': 5.56,
              'awayUnder25': 1.22,
              'over25': 1.67,
              'under25': 2.5,
              'bttsYes': 1.72,
              'bttsNo': 2.4,
            },
          ),
          minimumProbabilityDecimal: 0.30,
        );

        expect(selection, isNotNull);
        final allMarkets =
            (selection!['allMarkets'] as List).cast<Map<String, Object?>>();
        expect(
          allMarkets.any((m) => m['key'] == 'dcX2'),
          isTrue,
          reason: 'DC must be visible in allMarkets',
        );
        expect(allMarkets.any((m) => m['key'] == 'over15'), isTrue);
        expect(allMarkets.any((m) => m['key'] == 'under35'), isTrue);
        expect(allMarkets.any((m) => m['key'] == 'homeOver15'), isTrue);
        expect(allMarkets.any((m) => m['key'] == 'homeUnder15'), isTrue);
        expect(allMarkets.any((m) => m['key'] == 'awayUnder15'), isTrue);
        expect(allMarkets.any((m) => m['key'] == 'homeOver25'), isTrue);
        expect(allMarkets.any((m) => m['key'] == 'homeUnder25'), isTrue);
        expect(allMarkets.any((m) => m['key'] == 'awayOver25'), isTrue);
        expect(allMarkets.any((m) => m['key'] == 'awayUnder25'), isTrue);
      },
    );

    test(
      'returns null instead of recommending a trivial low-odds market',
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
      // Section 7: Über/Unter 3,5 (wie jede Tor-Linie außer 2,5) darf nie
      // Haupttipp werden, selbst bei hoher, fair bepreister Wahrscheinlichkeit.
      'never selects Über/Unter 3,5 Tore as the main tip - falls through '
      'to the best eligible core market instead',
      () {
        final selection = service.selectForFixture(
          fixtureId: 'under35-fixture',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.42,
              'draw': 0.25,
              'awayWin': 0.33,
              'over15': 0.71,
              'over25': 0.48,
              'under25': 0.52,
              'over35': 0.26,
              'under35': 0.74,
              'bttsYes': 0.49,
              'bttsNo': 0.51,
            },
            fairOdds: {
              'over15': 1.41,
              'under35': 1.36,
            },
          ),
          minimumProbabilityDecimal: 0.68,
        );

        expect(selection, isNotNull);
        // Kein Kernmarkt erreicht hier 68 % - der Selector fällt auf den
        // Fallback (>= 50 %) zurück. under25 (52 %) ist dort der stärkste
        // erlaubte Markt, under35 (74 %) bleibt trotz höherer
        // Wahrscheinlichkeit ausgeschlossen.
        expect((selection!['phoenixTip'] as Map)['marketKey'], 'under25');
      },
    );

    test(
      // Section 7: Team-Tore-Linien und Draw No Bet dürfen nie Haupttipp
      // werden, auch nicht, wenn ihre Quoten-Freigabe erfüllt ist.
      'never selects team-goals or Draw No Bet markets as the main tip, '
      'even when their pricing gates are met',
      () {
        final teamGoals = service.selectForFixture(
          fixtureId: 'team-goals-fixture',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.45,
              'draw': 0.22,
              'awayWin': 0.33,
              'over25': 0.52,
              'under25': 0.48,
              'bttsYes': 0.56,
              'bttsNo': 0.44,
              'homeOver15': 0.70,
            },
            fairOdds: {'homeOver15': 1.45},
          ),
          minimumProbabilityDecimal: 0.68,
        );
        // Kein Kernmarkt erreicht 68 %; Fallback (>= 50 %) wählt bttsYes
        // (56 %) vor over25 (52 %). homeOver15 (70 %) bleibt ausgeschlossen.
        expect((teamGoals!['phoenixTip'] as Map)['marketKey'], 'bttsYes');

        final dnb = service.selectForFixture(
          fixtureId: 'dnb-fixture',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.50,
              'draw': 0.25,
              'awayWin': 0.25,
              'dnbHome': 0.68,
              'over25': 0.40,
              'under25': 0.60,
              'bttsYes': 0.45,
              'bttsNo': 0.55,
            },
            fairOdds: {'homeWin': 2.0, 'dnbHome': 1.47},
          ),
          minimumProbabilityDecimal: 0.68,
        );
        // Kein Kernmarkt erreicht 68 %; Fallback (>= 50 %) wählt under25
        // (60 %) vor homeWin (50 %) und bttsNo (55 %). dnbHome (68 %)
        // bleibt trotz erfüllter Preisfreigabe ausgeschlossen.
        expect((dnb!['phoenixTip'] as Map)['marketKey'], 'under25');
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
      'keeps a fallback as a visible PHOENIX tip but never qualifies it as '
      'a value tip when it misses the 68 percent gate',
      () {
        final selection = service.selectForFixture(
          fixtureId: 'fallback-only-fixture',
          simulation: simulationWith(
            probabilities: {
              'homeWin': 0.36,
              'draw': 0.27,
              'awayWin': 0.37,
              'over25': 0.44,
              'under25': 0.56,
              'bttsYes': 0.65,
              'bttsNo': 0.35,
            },
            fairOdds: {'bttsYes': 1.54},
            dataQuality: 90,
            simulations: 100000,
          ),
          minimumProbabilityDecimal: 0.68,
        );

        expect(selection, isNotNull);
        expect((selection!['phoenixTip'] as Map)['marketKey'], 'bttsYes');
        expect(selection['qualifiesForTip'], isFalse);
        // Claude AN2.txt (2026-08-26, "jedes Spiel soll einen Tipp haben"):
        // der PHÖNIX-Tipp (Modellaussage) bleibt sichtbar, auch wenn er
        // nicht als Value-Tipp/Wettempfehlung qualifiziert.
        expect((selection['display'] as Map)['showPhoenixTip'], isTrue);
      },
    );

    test('publishes only candidates that clear probability and trust gates',
        () {
      final selection = service.selectForFixture(
        fixtureId: 'qualified-fixture',
        simulation: simulationWith(
          probabilities: {
            'homeWin': 0.74,
            'draw': 0.14,
            'awayWin': 0.12,
            'over25': 0.45,
            'under25': 0.55,
            'bttsYes': 0.48,
            'bttsNo': 0.52,
          },
          fairOdds: {'homeWin': 1.45},
          dataQuality: 90,
          simulations: 100000,
        ),
        minimumProbabilityDecimal: 0.68,
      );

      expect(selection, isNotNull);
      expect(selection!['qualifiesForTip'], isTrue);
      expect((selection['display'] as Map)['showPhoenixTip'], isTrue);
    });

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
            fairOdds: {'bttsYes': 1.40},
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
