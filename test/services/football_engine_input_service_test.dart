import 'package:phoenix_backend/src/services/football_engine_input_service.dart';
import 'package:test/test.dart';

// User feedback (2026-08-26, Control Center): "sowas wie 87% heimsieg kann
// nicht sein" - live beobachtet an Dinamo Tirana vs. Pafos (dataQuality nur
// 29, goalExpectations home=2.3/away=0.3 -> 83% Heimsieg-Wahrscheinlichkeit).
// Root cause: football_engine_input_service.dart nutzte eine rohe Torquote
// unabhängig davon, ob sie aus 3 oder 30 Spielen stammte - genau die in
// Claude AN2.txt Section 3 ("SAMPLE-SIZE-LOGIK") beschriebene Lücke.
// goalAverageIfPlayed (football_service.dart) unterscheidet nur "0 Spiele"
// von "0.0 Tore", schützt aber nicht vor einer dünnen, aber echten
// Stichprobe. shrinkGoalRateTowardsBaseline schließt diese Lücke.
void main() {
  group('FootballEngineInputService.shrinkGoalRateTowardsBaseline', () {
    test('a thin sample is pulled strongly towards the neutral baseline', () {
      // Reproduziert den live beobachteten Fall: 3 gespielte Partien,
      // away-Rohquote 0.3 -> deutlich Richtung Baseline (1.10) geglättet,
      // nicht mehr die extreme Rohquote.
      final shrunk = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
        0.3,
        baseline: 1.10,
        sampleSize: 3,
      );
      expect(shrunk, greaterThan(0.6));
      expect(shrunk, lessThan(1.10));
    });

    test('a large sample stays close to the raw value', () {
      final shrunk = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
        2.3,
        baseline: 1.35,
        sampleSize: 30,
      );
      expect(shrunk, greaterThan(2.0));
    });

    test('zero sample size shrinks fully to the baseline', () {
      expect(
        FootballEngineInputService.shrinkGoalRateTowardsBaseline(
          2.3,
          baseline: 1.35,
          sampleSize: 0,
        ),
        1.35,
      );
    });

    test('sample size at exactly k halves the distance to the baseline', () {
      // sampleSizeShrinkageK = 8: n / (n + k) = 0.5 bei n == k.
      final shrunk = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
        2.3,
        baseline: 1.35,
        sampleSize: FootballEngineInputService.sampleSizeShrinkageK,
      );
      expect(shrunk, closeTo(1.35 + 0.5 * (2.3 - 1.35), 0.001));
    });

    test('reproduces the live bug scenario (Dinamo Tirana vs. Pafos): '
        'the extreme home/away ratio narrows substantially', () {
      // Vorher (ungeschützte Rohquote): home=2.3, away=0.3 -> Verhältnis
      // ~7.7:1, aus dataQuality=29 (dünne Stichprobe).
      const rawHome = 2.3;
      const rawAway = 0.3;
      const thinSampleSize = 3;

      final shrunkHome = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
        rawHome,
        baseline: 1.35,
        sampleSize: thinSampleSize,
      );
      final shrunkAway = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
        rawAway,
        baseline: 1.10,
        sampleSize: thinSampleSize,
      );

      final rawRatio = rawHome / rawAway;
      final shrunkRatio = shrunkHome / shrunkAway;
      expect(shrunkRatio, lessThan(rawRatio));
      expect(shrunkRatio, lessThan(3.0));
    });

    test('never negative even for an out-of-range negative sample size', () {
      final shrunk = FootballEngineInputService.shrinkGoalRateTowardsBaseline(
        2.3,
        baseline: 1.35,
        sampleSize: -5,
      );
      expect(shrunk, 1.35);
    });
  });

  // Engine-Umbau Phase 1 Spur B (Plan "wild-cuddling-hoare", 2026-08-26):
  // statt immer Richtung des EINEN festen globalen Werts zu glätten, zuerst
  // Richtung eines liga-eigenen Normalwerts, der selbst wieder Richtung des
  // globalen Werts geglättet ist, solange die Liga wenig eigene Historie hat.
  group('FootballEngineInputService.leagueAwareBaseline', () {
    test('falls back to exactly the global baseline when the league has no '
        'matches in the 400-day window (regression safety)', () {
      expect(
        FootballEngineInputService.leagueAwareBaseline(
          globalBaseline: 1.35,
          leagueAvg: null,
          leagueContextSampleSize: 0,
        ),
        1.35,
      );
    });

    test('a league with a thin sample stays close to the global baseline '
        'even if its own average is very different', () {
      final shrunk = FootballEngineInputService.leagueAwareBaseline(
        globalBaseline: 1.35,
        leagueAvg: 2.5,
        leagueContextSampleSize: 3,
      );
      expect(shrunk, lessThan(1.6));
    });

    test('a league with a large, well-established sample shifts '
        'substantially towards its own average', () {
      final shrunk = FootballEngineInputService.leagueAwareBaseline(
        globalBaseline: 1.35,
        leagueAvg: 1.9,
        leagueContextSampleSize: 400,
      );
      expect(shrunk, greaterThan(1.7));
    });

    test('sample size at exactly leagueBaselineShrinkageK halves the '
        'distance to the global baseline', () {
      final shrunk = FootballEngineInputService.leagueAwareBaseline(
        globalBaseline: 1.35,
        leagueAvg: 1.9,
        leagueContextSampleSize:
            FootballEngineInputService.leagueBaselineShrinkageK,
      );
      expect(shrunk, closeTo(1.35 + 0.5 * (1.9 - 1.35), 0.001));
    });
  });
}
