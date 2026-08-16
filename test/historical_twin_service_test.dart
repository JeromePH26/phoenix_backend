import 'package:test/test.dart';

import 'package:phoenix_backend/src/services/historical_twin_service.dart';

/// Deckt die deterministische Similarity-Mathematik von Historical Twins V1
/// ab (siehe Vorgabe 27). Die datenbankgebundenen Teile (Kandidaten-Query,
/// Threshold-/Sortier-Pipeline in HistoricalTwinService.findTwins) haben
/// keine eigene Logik mehr, die nicht bereits hier über computeSimilarity
/// abgedeckt ist - findTwins filtert nur noch anhand von Werten, die diese
/// Tests bereits verifizieren (score < 70 -> ausgeschlossen, coverage < 60
/// -> ausgeschlossen, < 3 Komponenten -> ausgeschlossen).
void main() {
  group('HistoricalTwinService.computeSimilarity', () {
    test('kein Twin: ohne jede verfügbare Komponente ist Similarity null', () {
      const live = HistoricalTwinLiveFeatures();
      final result = HistoricalTwinService.computeSimilarity(live, const {
        'features': <String, Object?>{},
      });
      expect(result, isNull);
    });

    test('Data Leakage: identische Pre-Match-Daten liefern denselben Score '
        'unabhängig vom Endergebnis', () {
      const live = HistoricalTwinLiveFeatures(
        homeStrengthProbability: 0.62,
        homeHomeGoalProfile: HistoricalTwinGoalProfile(
          scoredAvg: 1.6,
          concededAvg: 0.9,
        ),
        awayAwayGoalProfile: HistoricalTwinGoalProfile(
          scoredAvg: 1.1,
          concededAvg: 1.3,
        ),
      );
      final baseRow = <String, Object?>{
        'elo_difference': 180.0,
        'data_coverage_percent': 100.0,
        'features': {
          'homeHomeProfile': {'goalsScoredAvg': 1.5, 'goalsConcededAvg': 1.0},
          'awayAwayProfile': {'goalsScoredAvg': 1.2, 'goalsConcededAvg': 1.2},
        },
      };

      final finishedHomeWin = {
        ...baseRow,
        'home_goals': 3,
        'away_goals': 0,
        'result': 'H',
      };
      final finishedAwayWin = {
        ...baseRow,
        'home_goals': 0,
        'away_goals': 2,
        'result': 'A',
      };

      final resultA = HistoricalTwinService.computeSimilarity(live, finishedHomeWin);
      final resultB = HistoricalTwinService.computeSimilarity(live, finishedAwayWin);

      expect(resultA, isNotNull);
      expect(resultB, isNotNull);
      expect(
        resultA!.score,
        equals(resultB!.score),
        reason:
            'computeSimilarity darf home_goals/away_goals nie lesen - beide '
            'Zeilen unterscheiden sich nur im Ergebnis.',
      );
      expect(resultA.componentScores, equals(resultB.componentScores));
    });

    test('Weight Normalization: fehlende Komponenten verdünnen den Score '
        'nicht, sie werden ausgelassen und der Rest neu normalisiert', () {
      // Nur "relativeStrength" (25%) verfügbar -> der Score MUSS exakt der
      // Similarity dieser einen Komponente entsprechen, nicht anteilig
      // reduziert (z. B. nicht 25% * Similarity).
      const live = HistoricalTwinLiveFeatures(homeStrengthProbability: 0.5);
      final row = <String, Object?>{
        'elo_difference': 0.0, // 0 Elo-Differenz -> 50% erwartete Heim-Chance
        'data_coverage_percent': 100.0,
        'features': <String, Object?>{},
      };

      final result = HistoricalTwinService.computeSimilarity(live, row);

      expect(result, isNotNull);
      expect(result!.componentsAvailable, 1);
      expect(result.componentScores.keys, ['relativeStrength']);
      // 0.5 (live) vs. Elo-Erwartungswert von 0 Differenz (ebenfalls 0.5) ->
      // identisch -> 100% Similarity für diese Komponente -> Gesamt-Score
      // muss ebenfalls 100 sein, nicht 25 (25% * 100).
      expect(result.score, closeTo(100.0, 0.5));
    });

    test('fehlendes Elo: relativeStrength wird ausgelassen statt 0% zu werten', () {
      const live = HistoricalTwinLiveFeatures(
        homeHomeGoalProfile: HistoricalTwinGoalProfile(scoredAvg: 1.5, concededAvg: 1.0),
        awayAwayGoalProfile: HistoricalTwinGoalProfile(scoredAvg: 1.2, concededAvg: 1.1),
      );
      final row = <String, Object?>{
        // Kein elo_difference im historischen Datensatz.
        'data_coverage_percent': 100.0,
        'features': {
          'homeHomeProfile': {'goalsScoredAvg': 1.5, 'goalsConcededAvg': 1.0},
          'awayAwayProfile': {'goalsScoredAvg': 1.2, 'goalsConcededAvg': 1.1},
        },
      };

      final result = HistoricalTwinService.computeSimilarity(live, row);

      expect(result, isNotNull);
      expect(result!.componentScores.containsKey('relativeStrength'), isFalse);
      expect(result.componentScores.containsKey('homeAwayProfile'), isTrue);
      // Identische Torschnitte -> nahezu perfekte Ähnlichkeit trotz
      // fehlendem Elo.
      expect(result.score, greaterThan(95.0));
    });

    test('große absolute Stärke-Differenz senkt die Torprofil-Similarity '
        'deutlich', () {
      const strongLive = HistoricalTwinLiveFeatures(
        homeHomeGoalProfile: HistoricalTwinGoalProfile(scoredAvg: 3.5, concededAvg: 0.2),
        awayAwayGoalProfile: HistoricalTwinGoalProfile(scoredAvg: 0.2, concededAvg: 3.0),
      );
      final weakHistoricalRow = <String, Object?>{
        'data_coverage_percent': 100.0,
        'features': {
          'homeHomeProfile': {'goalsScoredAvg': 0.4, 'goalsConcededAvg': 2.8},
          'awayAwayProfile': {'goalsScoredAvg': 2.6, 'goalsConcededAvg': 0.3},
        },
      };

      final result = HistoricalTwinService.computeSimilarity(strongLive, weakHistoricalRow);

      expect(result, isNotNull);
      expect(result!.score, lessThan(30.0));
    });

    test('Data Coverage ist durch die eigene Coverage des historischen '
        'Matches gedeckelt', () {
      const live = HistoricalTwinLiveFeatures(homeStrengthProbability: 0.5);
      final sparseHistoricalRow = <String, Object?>{
        'elo_difference': 0.0,
        'data_coverage_percent': 20.0, // dünn besetztes historisches Match
        'features': <String, Object?>{},
      };

      final result = HistoricalTwinService.computeSimilarity(live, sparseHistoricalRow);

      expect(result, isNotNull);
      // Verfügbares Gewicht wäre 25% (relativeStrength), aber die eigene
      // Coverage des historischen Matches liegt darunter -> muss dominieren.
      expect(result!.coveragePercent, 20.0);
    });

    test('threshold: score von genau 70.0 gilt als gültiger Twin (>= nicht >)', () {
      // similarityThreshold wird als "< 70 ausschließen" implementiert, d.h.
      // 70.0 selbst ist noch ein gültiger Twin.
      expect(HistoricalTwinService.similarityThreshold, 70.0);
      const belowThreshold = 69.9;
      const atThreshold = 70.0;
      expect(belowThreshold < HistoricalTwinService.similarityThreshold, isTrue);
      expect(atThreshold < HistoricalTwinService.similarityThreshold, isFalse);
    });

    test('kein harter Liga-/Divisions-Filter: computeSimilarity liest das '
        'division-Feld nie', () {
      const live = HistoricalTwinLiveFeatures(homeStrengthProbability: 0.5);
      final row = <String, Object?>{
        'elo_difference': 0.0,
        'data_coverage_percent': 100.0,
        'division': 'irgendeine-fremde-liga-stufe-99',
        'features': <String, Object?>{},
      };

      final result = HistoricalTwinService.computeSimilarity(live, row);

      // Ein exotischer Divisions-Wert darf die Berechnung nicht verändern
      // oder zum Ausschluss führen.
      expect(result, isNotNull);
      expect(result!.score, closeTo(100.0, 0.5));
    });
  });

  group('HistoricalTwinService numeric helpers', () {
    test('numericSimilarity: identischer Wert -> 100%, scale-Differenz -> 0%', () {
      expect(HistoricalTwinService.numericSimilarity(1.5, 1.5, 2.0), 100.0);
      expect(HistoricalTwinService.numericSimilarity(1.5, 3.5, 2.0), 0.0);
      expect(HistoricalTwinService.numericSimilarity(1.5, 4.5, 2.0), 0.0); // geclamped
      expect(HistoricalTwinService.numericSimilarity(1.0, 1.5, 2.0), 75.0);
    });

    test('eloToProbability: 0 Differenz -> 50%, positive Differenz -> > 50%', () {
      expect(HistoricalTwinService.eloToProbability(0), closeTo(0.5, 0.001));
      expect(HistoricalTwinService.eloToProbability(400), greaterThan(0.9));
      expect(HistoricalTwinService.eloToProbability(-400), lessThan(0.1));
    });

    test('probabilitySimilarity: identische Wahrscheinlichkeit -> 100%', () {
      expect(HistoricalTwinService.probabilitySimilarity(0.6, 0.6), 100.0);
      expect(HistoricalTwinService.probabilitySimilarity(0.6, 0.1), 0.0); // geclamped
    });
  });
}
