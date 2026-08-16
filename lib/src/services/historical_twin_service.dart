import 'dart:math' as math;

import '../database/database.dart';

/// Historical Twins V1.
///
/// Findet vergangene Spiele, deren PRE-MATCH-Situation einem heutigen
/// PHÖNIX-Fixture ähnlich war, und liefert eine reine Zusatzinformation.
///
/// WICHTIG: Diese Klasse liest ausschließlich Pre-Match-Daten (sowohl vom
/// historischen als auch vom aktuellen Spiel) und schreibt nirgendwo in die
/// PHÖNIX-Engine zurück. Sie hat keinerlei Einfluss auf Analyse,
/// Monte-Carlo, faire Quote, Value oder Tipp - das ist technisch
/// sichergestellt, indem dieser Service ausschließlich lesend arbeitet und
/// von keinem Engine-/Simulations-/Value-Service aufgerufen wird.
class HistoricalTwinService {
  HistoricalTwinService({required this.database});

  final PhoenixDatabase database;

  static const double similarityThreshold = 70.0;
  static const double minDataCoveragePercent = 60.0;
  static const int minComponents = 3;
  static const int maxResults = 50;

  Future<Map<String, Object?>> findTwins(String fixtureId) async {
    final match = await database.footballMatchForTwin(fixtureId);
    if (match == null) {
      return _emptyResponse(reason: 'fixture_not_found');
    }

    final rawJson = match['raw_json'];
    final rawMap = rawJson is Map ? Map<String, Object?>.from(rawJson) : <String, Object?>{};
    final engineInput = await database.latestFootballEngineInput(fixtureId);

    final live = HistoricalTwinLiveFeatures.fromSources(
      matchRow: match,
      rawJson: rawMap,
      engineInput: engineInput,
    );

    final candidates = await database.historicalTwinCandidates(
      eloDifference: live.eloDifferenceProxy,
    );

    final scored = <_ScoredTwin>[];
    for (final row in candidates) {
      final result = HistoricalTwinService.computeSimilarity(live, row);
      if (result == null) continue;
      if (result.componentsAvailable < minComponents) continue;
      if (result.coveragePercent < minDataCoveragePercent) continue;
      if (result.score < similarityThreshold) continue;
      scored.add(_ScoredTwin(row: row, result: result));
    }

    // Sortierung gemäß Vorgabe 12: Similarity DESC, Data Coverage DESC,
    // Datum DESC. Bewusst keine Liga-Bevorzugung.
    scored.sort((a, b) {
      final byScore = b.result.score.compareTo(a.result.score);
      if (byScore != 0) return byScore;
      final byCoverage = b.result.coveragePercent.compareTo(a.result.coveragePercent);
      if (byCoverage != 0) return byCoverage;
      final dateA = a.row['match_date'] as DateTime?;
      final dateB = b.row['match_date'] as DateTime?;
      if (dateA == null || dateB == null) return 0;
      return dateB.compareTo(dateA);
    });

    final top = scored.take(maxResults).toList();
    if (top.isEmpty) {
      return _emptyResponse(reason: 'no_similar_matches');
    }

    return {
      'found': true,
      'count': top.length,
      'averageSimilarity': _round1(
        top.map((t) => t.result.score).reduce((a, b) => a + b) / top.length,
      ),
      'bestSimilarity': _round1(top.first.result.score),
      'outcomes': _outcomeStatistics(top),
      'twins': top.map((t) => _twinJson(t)).toList(),
    };
  }

  Map<String, Object?> _emptyResponse({required String reason}) => {
        'found': false,
        'count': 0,
        'averageSimilarity': null,
        'bestSimilarity': null,
        'outcomes': null,
        'twins': const <Object?>[],
        'reason': reason,
      };

  Map<String, Object?> _twinJson(_ScoredTwin twin) {
    final row = twin.row;
    final date = row['match_date'] as DateTime?;
    return {
      'id': row['id'],
      'source': row['source'],
      'date': date == null
          ? null
          : '${date.year.toString().padLeft(4, '0')}-'
              '${date.month.toString().padLeft(2, '0')}-'
              '${date.day.toString().padLeft(2, '0')}',
      'division': row['division'],
      'homeTeam': row['home_team'],
      'awayTeam': row['away_team'],
      'homeGoals': row['home_goals'],
      'awayGoals': row['away_goals'],
      'similarityScore': _round1(twin.result.score),
      'dataCoveragePercent': _round1(twin.result.coveragePercent),
      'components': twin.result.componentScores,
    };
  }

  Map<String, Object?> _outcomeStatistics(List<_ScoredTwin> twins) {
    var homeWin = 0, draw = 0, awayWin = 0;
    var over25 = 0, under25 = 0, bttsYes = 0, bttsNo = 0;
    var homeGoalsSum = 0, awayGoalsSum = 0, decided = 0;

    for (final twin in twins) {
      final home = twin.row['home_goals'];
      final away = twin.row['away_goals'];
      if (home is! int || away is! int) continue;
      decided++;
      homeGoalsSum += home;
      awayGoalsSum += away;
      if (home > away) {
        homeWin++;
      } else if (home == away) {
        draw++;
      } else {
        awayWin++;
      }
      if (home + away > 2) {
        over25++;
      } else {
        under25++;
      }
      if (home > 0 && away > 0) {
        bttsYes++;
      } else {
        bttsNo++;
      }
    }

    if (decided == 0) return const {};

    return {
      'homeWin': _round1(homeWin / decided * 100),
      'draw': _round1(draw / decided * 100),
      'awayWin': _round1(awayWin / decided * 100),
      'over25': _round1(over25 / decided * 100),
      'under25': _round1(under25 / decided * 100),
      'bttsYes': _round1(bttsYes / decided * 100),
      'bttsNo': _round1(bttsNo / decided * 100),
      'averageHomeGoals': _round1(homeGoalsSum / decided),
      'averageAwayGoals': _round1(awayGoalsSum / decided),
      'averageTotalGoals': _round1((homeGoalsSum + awayGoalsSum) / decided),
      'sample': decided,
    };
  }

  /// Berechnet die gewichtete Gesamtähnlichkeit (0-100 %) zwischen der
  /// aktuellen PHÖNIX-Pre-Match-Situation und einem historischen Match.
  ///
  /// KEIN Zugriff auf das tatsächliche Ergebnis des historischen Spiels -
  /// [row] enthält nur bereits leakage-frei berechnete Pre-Match-Felder
  /// (siehe bin/import_historical_twins.dart). home_goals/away_goals werden
  /// hier absichtlich nicht gelesen.
  static HistoricalTwinSimilarityResult? computeSimilarity(HistoricalTwinLiveFeatures live, Map<String, Object?> row) {
    final features = row['features'];
    final featureMap = features is Map ? Map<String, Object?>.from(features) : <String, Object?>{};
    final homeOverall = _asMap(featureMap['homeOverall']);
    final awayOverall = _asMap(featureMap['awayOverall']);
    final homeHomeProfile = _asMap(featureMap['homeHomeProfile']);
    final awayAwayProfile = _asMap(featureMap['awayAwayProfile']);

    final components = <String, double>{};

    // A. Relatives Kräfteverhältnis - 25%. Historisch aus Elo-Differenz
    // (klassische Elo-Erwartungswert-Formel), live aus dem PHÖNIX-eigenen
    // Torraten-Erwartungswert (kein Elo verfügbar - siehe Vorgabe 14/13).
    final histEloDiff = _num(row['elo_difference']);
    if (live.homeStrengthProbability != null && histEloDiff != null) {
      final histProbability = eloToProbability(histEloDiff);
      components['relativeStrength'] =
          probabilitySimilarity(live.homeStrengthProbability!, histProbability);
    }

    // B. Form - 20%. Für PHÖNIX-Live-Fixtures aktuell nicht verfügbar
    // (siehe Abschlussbericht) - Komponente bleibt dann ausgelassen.
    if (live.form5Home != null && live.form5Away != null) {
      final histForm5Home = _num(row['form5_home']);
      final histForm5Away = _num(row['form5_away']);
      if (histForm5Home != null && histForm5Away != null) {
        final homeSim = numericSimilarity(live.form5Home!, histForm5Home, 8.0);
        final awaySim = numericSimilarity(live.form5Away!, histForm5Away, 8.0);
        components['form'] = (homeSim + awaySim) / 2;
      }
    }

    // C. Marktprofil - 20%. Für PHÖNIX-Live-Fixtures aktuell nicht
    // reusable gespeichert (nur eine Verfügbarkeits-Bool, keine Werte) -
    // siehe Abschlussbericht.
    if (live.homeWinProbability != null) {
      final histHomeProb = _num(row['normalized_home_probability']);
      if (histHomeProb != null) {
        components['market'] = numericSimilarity(
          live.homeWinProbability!,
          histHomeProb,
          40.0,
        );
      }
    }

    // D. Torprofil - 15%. Aus vorherigen Spielen (historisch: rolling
    // "overall" Fenster; live: Durchschnitt aus Heim-/Auswärts-Split, da
    // PHÖNIX kein separates Gesamt-Fenster führt).
    final liveHomeGoalProfile = live.homeGoalProfile;
    final liveAwayGoalProfile = live.awayGoalProfile;
    if (liveHomeGoalProfile != null && liveAwayGoalProfile != null) {
      final homeSim = goalProfileSimilarity(liveHomeGoalProfile, homeOverall);
      final awaySim = goalProfileSimilarity(liveAwayGoalProfile, awayOverall);
      if (homeSim != null && awaySim != null) {
        components['goalProfile'] = (homeSim + awaySim) / 2;
      }
    }

    // E. Heim-/Auswärtsprofil - 10%. Direkt vergleichbar: PHÖNIX führt
    // homeGoalsForAverageHome/AgainstHome bzw. awayGoalsForAverageAway/
    // AgainstAway (siehe FootballEngineInputService).
    if (live.homeHomeGoalProfile != null && live.awayAwayGoalProfile != null) {
      final homeSim = goalProfileSimilarity(live.homeHomeGoalProfile!, homeHomeProfile);
      final awaySim = goalProfileSimilarity(live.awayAwayGoalProfile!, awayAwayProfile);
      if (homeSim != null && awaySim != null) {
        components['homeAwayProfile'] = (homeSim + awaySim) / 2;
      }
    }

    // F. Absolutes Spielniveau - 10%. Ohne eigenes Elo aktuell nicht
    // verfügbar für PHÖNIX-Live-Fixtures (siehe Vorgabe 14).
    if (live.absoluteLevelProxy != null) {
      final histLevel = _num(row['absolute_elo_level']);
      if (histLevel != null) {
        components['absoluteLevel'] =
            numericSimilarity(live.absoluteLevelProxy!, histLevel, 400.0);
      }
    }

    if (components.isEmpty) return null;

    final weights = <String, double>{
      'relativeStrength': 25,
      'form': 20,
      'market': 20,
      'goalProfile': 15,
      'homeAwayProfile': 10,
      'absoluteLevel': 10,
    };

    var availableWeight = 0.0;
    var weightedScore = 0.0;
    for (final entry in components.entries) {
      final weight = weights[entry.key]!;
      availableWeight += weight;
      weightedScore += weight * entry.value;
    }

    final score = weightedScore / availableWeight;
    final coverage = availableWeight; // Summe der 100%-Gewichte = Coverage.
    final historicalOwnCoverage = _num(row['data_coverage_percent']) ?? 100;
    // Data Coverage ist das Minimum aus "wie viele Komponenten konnten für
    // DIESEN Vergleich überhaupt berechnet werden" und "wie vollständig war
    // das historische Match selbst" - ein Twin mit dünnen eigenen Daten
    // kann keine 100%-Vergleichs-Coverage vortäuschen.
    final effectiveCoverage = coverage < historicalOwnCoverage ? coverage : historicalOwnCoverage;

    return HistoricalTwinSimilarityResult(
      score: score,
      coveragePercent: effectiveCoverage,
      componentsAvailable: components.length,
      componentScores: components.map((k, v) => MapEntry(k, _round1(v))),
    );
  }

  static double? goalProfileSimilarity(HistoricalTwinGoalProfile live, Map<String, Object?> historical) {
    final histScored = _num(historical['goalsScoredAvg']);
    final histConceded = _num(historical['goalsConcededAvg']);
    if (histScored == null || histConceded == null) return null;
    final scoredSim = numericSimilarity(live.scoredAvg, histScored, 2.2);
    final concededSim = numericSimilarity(live.concededAvg, histConceded, 2.2);
    return (scoredSim + concededSim) / 2;
  }

  /// 100 % bei identischem Wert, linear fallend auf 0 % bei [scale]
  /// Differenz. [scale] ist bewusst pro Merkmalstyp unterschiedlich groß
  /// (z. B. Torschnitt vs. Elo), damit "ähnlich" fachlich sinnvoll bleibt.
  static double numericSimilarity(double a, double b, double scale) {
    final diff = (a - b).abs();
    final ratio = (diff / scale).clamp(0.0, 1.0);
    return (1 - ratio) * 100;
  }

  static double probabilitySimilarity(double liveProbability, double historicalProbability) {
    final diffPercentagePoints = (liveProbability - historicalProbability).abs() * 100;
    return (100 - diffPercentagePoints * 2).clamp(0.0, 100.0);
  }

  /// Klassische Elo-Erwartungswert-Formel: wandelt eine Elo-Differenz in
  /// eine Heimsieg-Wahrscheinlichkeit (0-1) um, damit sie mit dem
  /// torraten-basierten Live-Proxy verglichen werden kann.
  static double eloToProbability(double eloDifference) {
    return 1 / (1 + math.pow(10, -eloDifference / 400));
  }

  static Map<String, Object?> _asMap(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  static double? _num(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static double _round1(double value) => double.parse(value.toStringAsFixed(1));
}

class HistoricalTwinGoalProfile {
  const HistoricalTwinGoalProfile({required this.scoredAvg, required this.concededAvg});
  final double scoredAvg;
  final double concededAvg;
}

class HistoricalTwinLiveFeatures {
  const HistoricalTwinLiveFeatures({
    this.homeStrengthProbability,
    this.homeWinProbability,
    this.form5Home,
    this.form5Away,
    this.homeGoalProfile,
    this.awayGoalProfile,
    this.homeHomeGoalProfile,
    this.awayAwayGoalProfile,
    this.absoluteLevelProxy,
    this.eloDifferenceProxy,
  });

  final double? homeStrengthProbability;
  final double? homeWinProbability;
  final double? form5Home;
  final double? form5Away;
  final HistoricalTwinGoalProfile? homeGoalProfile;
  final HistoricalTwinGoalProfile? awayGoalProfile;
  final HistoricalTwinGoalProfile? homeHomeGoalProfile;
  final HistoricalTwinGoalProfile? awayAwayGoalProfile;
  final double? absoluteLevelProxy;
  final double? eloDifferenceProxy;

  factory HistoricalTwinLiveFeatures.fromSources({
    required Map<String, Object?> matchRow,
    required Map<String, Object?> rawJson,
    required Map<String, Object?>? engineInput,
  }) {
    final raw = engineInput != null && engineInput['raw'] is Map
        ? Map<String, Object?>.from(engineInput['raw'] as Map)
        : <String, Object?>{};

    double? number(Object? value) {
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    final homeForHome = number(raw['homeGoalsForAverageHome']);
    final homeAgainstHome = number(raw['homeGoalsAgainstAverageHome']);
    final awayForAway = number(raw['awayGoalsForAverageAway']);
    final awayAgainstAway = number(raw['awayGoalsAgainstAverageAway']);

    HistoricalTwinGoalProfile? homeHome;
    if (homeForHome != null && homeAgainstHome != null) {
      homeHome = HistoricalTwinGoalProfile(scoredAvg: homeForHome, concededAvg: homeAgainstHome);
    }
    HistoricalTwinGoalProfile? awayAway;
    if (awayForAway != null && awayAgainstAway != null) {
      awayAway = HistoricalTwinGoalProfile(scoredAvg: awayForAway, concededAvg: awayAgainstAway);
    }

    // PHÖNIX führt aktuell keine separaten Gesamt- (Heim+Auswärts
    // kombiniert) Rolling-Fenster - als Näherung wird das jeweilige
    // Heim-/Auswärts-Split-Profil auch für den Torprofil-Vergleich (D)
    // verwendet. Deutlich als Näherung im Abschlussbericht dokumentiert.
    final homeOverallProxy = homeHome;
    final awayOverallProxy = awayAway;

    double? homeStrengthProbability;
    final normalized = engineInput != null && engineInput['normalized'] is Map
        ? Map<String, Object?>.from(engineInput['normalized'] as Map)
        : <String, Object?>{};
    final expectedHome = number(normalized['goalRateExpectedHome']);
    final expectedAway = number(normalized['goalRateExpectedAway']);
    double? eloDifferenceProxy;
    if (expectedHome != null && expectedAway != null && (expectedHome + expectedAway) > 0) {
      homeStrengthProbability = expectedHome / (expectedHome + expectedAway);
      // Grobe Rück-Umrechnung in eine Elo-Differenz-Größenordnung, nur für
      // die SQL-Vorfilterung (siehe historicalTwinCandidates) - keine echte
      // Elo, daher bewusst eine großzügige Toleranz beim Aufrufer.
      eloDifferenceProxy = (homeStrengthProbability - 0.5) * 800;
    }

    return HistoricalTwinLiveFeatures(
      homeStrengthProbability: homeStrengthProbability,
      homeWinProbability: null, // keine gespeicherten Marktquoten - siehe Abschlussbericht
      form5Home: null, // kein gespeicherter Formwert - siehe Abschlussbericht
      form5Away: null,
      homeGoalProfile: homeOverallProxy,
      awayGoalProfile: awayOverallProxy,
      homeHomeGoalProfile: homeHome,
      awayAwayGoalProfile: awayAway,
      absoluteLevelProxy: null, // kein Elo - siehe Vorgabe 14
      eloDifferenceProxy: eloDifferenceProxy,
    );
  }
}

class HistoricalTwinSimilarityResult {
  const HistoricalTwinSimilarityResult({
    required this.score,
    required this.coveragePercent,
    required this.componentsAvailable,
    required this.componentScores,
  });

  final double score;
  final double coveragePercent;
  final int componentsAvailable;
  final Map<String, double> componentScores;
}

class _ScoredTwin {
  const _ScoredTwin({required this.row, required this.result});
  final Map<String, Object?> row;
  final HistoricalTwinSimilarityResult result;
}
