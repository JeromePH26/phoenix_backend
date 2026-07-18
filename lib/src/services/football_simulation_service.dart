import 'dart:math';

import '../database/database.dart';

class FootballSimulationService {
  FootballSimulationService({required this.database});

  final PhoenixDatabase database;

  static const modelVersion = 'phoenix_monte_carlo_v2_stability';

  Future<Map<String, Object?>> run({
    required int phaseTwoScanRunId,
    int limit = 20,
    int simulations = 100000,
  }) async {
    final safeSimulations = simulations.clamp(10000, 100000);
    final rows = await database.engineInputsForSimulation(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit,
    );

    final outputs = <Map<String, Object?>>[];

    for (final row in rows) {
      final fixtureId = _string(row['fixture_id']);
      final input = _map(row['normalized_input']);
      final normalized = _map(input['normalized']);

      if (input['engineReady'] != true) {
        outputs.add({
          'fixtureId': fixtureId,
          'status': 'skipped',
          'reason': 'engine_not_ready',
        });
        continue;
      }

      final homeLambda = _number(normalized['goalRateExpectedHome']);
      final awayLambda = _number(normalized['goalRateExpectedAway']);
      if (homeLambda == null || awayLambda == null) continue;

      final result = _simulate(
        input: input,
        baseHomeLambda: homeLambda,
        baseAwayLambda: awayLambda,
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
      'phase': 5,
      'phaseTwoScanRunId': phaseTwoScanRunId,
      'modelVersion': modelVersion,
      'simulationsPerMatch': safeSimulations,
      'processed': outputs.length,
      'results': outputs,
    };
  }

  Map<String, Object?> _simulate({
    required Map<String, Object?> input,
    required double baseHomeLambda,
    required double baseAwayLambda,
    required int simulations,
  }) {
    const blockCount = 10;
    final blockSize = simulations ~/ blockCount;
    final random = Random(_stableSeed(_string(input['fixtureId']), simulations));
    final normalized = _map(input['normalized']);

    final homeVariance =
        (_number(normalized['homeAttackVariance']) ?? 0.15).clamp(0.05, 0.45);
    final awayVariance =
        (_number(normalized['awayAttackVariance']) ?? 0.15).clamp(0.05, 0.45);
    final tempoVariance =
        (_number(normalized['tempoVariance']) ?? 0.10).clamp(0.03, 0.35);

    final total = _Counter();
    final blocks = <Map<String, double>>[];
    final scoreCounts = <String, int>{};

    for (var block = 0; block < blockCount; block++) {
      final counter = _Counter();

      for (var i = 0; i < blockSize; i++) {
        final commonTempo = _logNormalMultiplier(random, tempoVariance);
        final homeForm = _logNormalMultiplier(random, homeVariance);
        final awayForm = _logNormalMultiplier(random, awayVariance);

        final homeLambda =
            (baseHomeLambda * commonTempo * homeForm).clamp(0.05, 6.0);
        final awayLambda =
            (baseAwayLambda * commonTempo * awayForm).clamp(0.05, 6.0);

        final homeGoals = _samplePoisson(homeLambda, random);
        final awayGoals = _samplePoisson(awayLambda, random);

        counter.add(homeGoals, awayGoals);
        total.add(homeGoals, awayGoals);

        final score = '$homeGoals:$awayGoals';
        scoreCounts[score] = (scoreCounts[score] ?? 0) + 1;
      }

      blocks.add(counter.percentages(blockSize));
    }

    final probabilities = total.percentages(blockSize * blockCount);
    final stability = <String, Object?>{};
    for (final key in probabilities.keys) {
      final values = blocks.map((block) => block[key] ?? 0).toList();
      stability[key] = {
        'minimum': _round(values.reduce(min)),
        'maximum': _round(values.reduce(max)),
        'range': _round(values.reduce(max) - values.reduce(min)),
        'standardDeviation': _round(_stdDev(values)),
        'label': _stabilityLabel(values.reduce(max) - values.reduce(min)),
      };
    }

    final topScores = scoreCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final fairOdds = <String, Object?>{
      for (final entry in probabilities.entries)
        entry.key: entry.value <= 0 ? null : _round(100 / entry.value),
    };

    return {
      'fixtureId': input['fixtureId'],
      'homeTeam': input['homeTeam'],
      'awayTeam': input['awayTeam'],
      'league': input['league'],
      'kickoff': input['kickoff'],
      'dataQuality': input['dataQuality'],
      'modelVersion': modelVersion,
      'simulations': blockSize * blockCount,
      'blocks': blockCount,
      'goalExpectations': {
        'home': _round(baseHomeLambda),
        'away': _round(baseAwayLambda),
        'total': _round(baseHomeLambda + baseAwayLambda),
        'realXgAvailable': input['realXgAvailable'] == true,
      },
      'probabilities': probabilities,
      'fairOdds': fairOdds,
      'stability': stability,
      'topScores': topScores.take(8).map((entry) {
        return {
          'score': entry.key,
          'probability':
              _round(entry.value / (blockSize * blockCount) * 100),
        };
      }).toList(),
      'phaseFour': input['phaseFour'],
      'warnings': input['warnings'],
    };
  }

  int _samplePoisson(double lambda, Random random) {
    final limit = exp(-lambda);
    var product = 1.0;
    var count = 0;
    do {
      count++;
      product *= random.nextDouble();
    } while (product > limit && count < 16);
    return count - 1;
  }

  double _logNormalMultiplier(Random random, double sigma) {
    final u1 = max(random.nextDouble(), 1e-12);
    final u2 = random.nextDouble();
    final normal = sqrt(-2 * log(u1)) * cos(2 * pi * u2);
    return exp(normal * sigma - 0.5 * sigma * sigma);
  }

  double _stdDev(List<double> values) {
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance =
        values.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) /
            values.length;
    return sqrt(variance);
  }

  String _stabilityLabel(double range) {
    if (range <= 1.5) return 'sehr_stabil';
    if (range <= 3.0) return 'stabil';
    if (range <= 5.0) return 'mittel';
    return 'instabil';
  }

  int _stableSeed(String fixtureId, int simulations) =>
      '$fixtureId:$simulations:$modelVersion'.codeUnits.fold(
            17,
            (value, element) => (value * 31 + element) & 0x7fffffff,
          );

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  String _string(Object? value) => value?.toString().trim() ?? '';

  double _round(double value) =>
      double.parse(value.toStringAsFixed(2));
}

class _Counter {
  int homeWin = 0;
  int draw = 0;
  int awayWin = 0;
  int over15 = 0;
  int under15 = 0;
  int over25 = 0;
  int under25 = 0;
  int over35 = 0;
  int under35 = 0;
  int bttsYes = 0;
  int bttsNo = 0;

  void add(int home, int away) {
    if (home > away) {
      homeWin++;
    } else if (home == away) {
      draw++;
    } else {
      awayWin++;
    }

    final total = home + away;
    total >= 2 ? over15++ : under15++;
    total >= 3 ? over25++ : under25++;
    total >= 4 ? over35++ : under35++;
    home > 0 && away > 0 ? bttsYes++ : bttsNo++;
  }

  Map<String, double> percentages(int count) {
    double p(int value) => value / count * 100;
    return {
      'homeWin': p(homeWin),
      'draw': p(draw),
      'awayWin': p(awayWin),
      'doubleChance1X': p(homeWin + draw),
      'doubleChanceX2': p(draw + awayWin),
      'doubleChance12': p(homeWin + awayWin),
      'over15': p(over15),
      'under15': p(under15),
      'over25': p(over25),
      'under25': p(under25),
      'over35': p(over35),
      'under35': p(under35),
      'bttsYes': p(bttsYes),
      'bttsNo': p(bttsNo),
    };
  }
}
