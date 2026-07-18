import 'dart:math';

import '../database/database.dart';

class FootballSimulationService {
  FootballSimulationService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'poisson_monte_carlo_v2_context100k';

  Future<Map<String, Object?>> run({
    required int phaseTwoScanRunId,
    int limit = 1,
    int simulations = 100000,
  }) async {
    final rows = await database.engineInputsForSimulation(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit,
    );

    final outputs = <Map<String, Object?>>[];
    final safeSimulations = simulations.clamp(1000, 100000).toInt();

    for (final row in rows) {
      final fixtureId = _string(row['fixture_id']);
      final input = _map(row['normalized_input']);
      final normalized = _map(input['normalized']);

      final homeLambda = _number(normalized['goalRateExpectedHome']);
      final awayLambda = _number(normalized['goalRateExpectedAway']);

      if (homeLambda == null || awayLambda == null) {
        outputs.add({
          'fixtureId': fixtureId,
          'status': 'skipped',
          'reason': 'goal_expectation_missing',
        });
        continue;
      }

      final result = _simulate(
        input: input,
        homeLambda: homeLambda.clamp(0.05, 5.0),
        awayLambda: awayLambda.clamp(0.05, 5.0),
        simulations: safeSimulations,
      );

      await database.saveFootballSimulationResult(
        phaseTwoScanRunId: phaseTwoScanRunId,
        fixtureId: fixtureId,
        modelVersion: modelVersion,
        simulations: safeSimulations,
        result: result,
      );

      outputs.add(result);
    }

    return {
      'status': 'completed',
      'phaseTwoScanRunId': phaseTwoScanRunId,
      'modelVersion': modelVersion,
      'simulationsPerMatch': safeSimulations,
      'processed': outputs.length,
      'results': outputs,
    };
  }

  Map<String, Object?> _simulate({
    required Map<String, Object?> input,
    required double homeLambda,
    required double awayLambda,
    required int simulations,
  }) {
    final fixtureId = _string(input['fixtureId']);
    final random = Random(_stableSeed(fixtureId, simulations));

    var homeWins = 0;
    var draws = 0;
    var awayWins = 0;
    var over25 = 0;
    var under25 = 0;
    var bttsYes = 0;
    var bttsNo = 0;

    final scoreCounts = <String, int>{};

    for (var i = 0; i < simulations; i++) {
      final homeGoals = _samplePoisson(homeLambda, random);
      final awayGoals = _samplePoisson(awayLambda, random);

      if (homeGoals > awayGoals) {
        homeWins++;
      } else if (homeGoals == awayGoals) {
        draws++;
      } else {
        awayWins++;
      }

      if (homeGoals + awayGoals >= 3) {
        over25++;
      } else {
        under25++;
      }

      if (homeGoals > 0 && awayGoals > 0) {
        bttsYes++;
      } else {
        bttsNo++;
      }

      final score = '$homeGoals:$awayGoals';
      scoreCounts[score] = (scoreCounts[score] ?? 0) + 1;
    }

    final topScores = scoreCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final homeWinProbability = homeWins / simulations;
    final drawProbability = draws / simulations;
    final awayWinProbability = awayWins / simulations;
    final over25Probability = over25 / simulations;
    final under25Probability = under25 / simulations;
    final bttsYesProbability = bttsYes / simulations;
    final bttsNoProbability = bttsNo / simulations;

    return {
      'fixtureId': fixtureId,
      'homeTeam': _string(input['homeTeam']),
      'awayTeam': _string(input['awayTeam']),
      'league': _string(input['league']),
      'kickoff': _string(input['kickoff']),
      'modelVersion': modelVersion,
      'dataQuality': _int(input['dataQuality']),
      'simulations': simulations,
      'goalExpectations': {
        'home': _round(homeLambda),
        'away': _round(awayLambda),
        'total': _round(homeLambda + awayLambda),
        'sourceType': input['sourceType'],
        'realXgAvailable': input['realXgAvailable'] == true,
        'aiContextApplied': input['aiContextApplied'] == true,
        'lineupConfirmed': input['lineupConfirmed'] == true,
      },
      'aiContext': input['aiContext'],
      'confidenceDelta': _int(input['confidenceDelta']),
      'lineupConfirmed': input['lineupConfirmed'] == true,
      'probabilities': {
        'homeWin': _percent(homeWinProbability),
        'draw': _percent(drawProbability),
        'awayWin': _percent(awayWinProbability),
        'home': _percent(homeWinProbability),
        'away': _percent(awayWinProbability),
        'over25': _percent(over25Probability),
        'under25': _percent(under25Probability),
        'bttsYes': _percent(bttsYesProbability),
        'bttsNo': _percent(bttsNoProbability),
      },
      'fairOdds': {
        'homeWin': _fairOdds(homeWinProbability),
        'draw': _fairOdds(drawProbability),
        'awayWin': _fairOdds(awayWinProbability),
        'over25': _fairOdds(over25Probability),
        'under25': _fairOdds(under25Probability),
        'bttsYes': _fairOdds(bttsYesProbability),
        'bttsNo': _fairOdds(bttsNoProbability),
      },
      'topScorelines': topScores.take(5).map((entry) {
        return {
          'score': entry.key,
          'count': entry.value,
          'probability': _percent(entry.value / simulations),
        };
      }).toList(),
      'warnings': [
        if (input['realXgAvailable'] != true)
          'Simulation basiert noch auf Torquoten, nicht auf echtem xG/xGA.',
        if (input['aiContextApplied'] != true)
          'Keine ausreichend verlässliche KI-Kontextanpassung angewendet.',
        if (input['lineupConfirmed'] != true)
          'Die offizielle Startelf ist noch nicht bestätigt.',
      ],
    };
  }

  int _samplePoisson(double lambda, Random random) {
    final limit = exp(-lambda);
    var product = 1.0;
    var k = 0;

    do {
      k++;
      product *= random.nextDouble();
    } while (product > limit);

    return k - 1;
  }

  int _stableSeed(String fixtureId, int simulations) {
    var hash = 17;
    for (final unit in fixtureId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return (hash + simulations) & 0x7fffffff;
  }

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  double _percent(double value) =>
      double.parse((value * 100).toStringAsFixed(2));

  double? _fairOdds(double probability) {
    if (probability <= 0) return null;
    return double.parse((1 / probability).toStringAsFixed(2));
  }

  double _round(double value) =>
      double.parse(value.toStringAsFixed(3));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

