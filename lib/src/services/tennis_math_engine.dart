import 'dart:math';

class TennisSurfaceStats {
  const TennisSurfaceStats({
    required this.firstServeIn,
    required this.firstServeWon,
    required this.secondServeWon,
    required this.breakPointsSaved,
    required this.breakPointsConverted,
    required this.sampleMatches,
    this.surfaceElo = 1500,
    this.averageOpponentSurfaceElo = 1500,
  });

  final double firstServeIn;
  final double firstServeWon;
  final double secondServeWon;
  final double breakPointsSaved;
  final double breakPointsConverted;
  final int sampleMatches;
  final double surfaceElo;
  final double averageOpponentSurfaceElo;

  factory TennisSurfaceStats.fromJson(Map<String, Object?> json) {
    double p(String key) {
      final raw = json[key];
      final value = raw is num
          ? raw.toDouble()
          : double.tryParse(raw?.toString().replaceAll(',', '.') ?? '') ?? 0;
      return value > 1 ? value / 100 : value;
    }

    double n(String key, double fallback) {
      final raw = json[key];
      return raw is num
          ? raw.toDouble()
          : double.tryParse(raw?.toString() ?? '') ?? fallback;
    }

    int i(String key) {
      final raw = json[key];
      return raw is int
          ? raw
          : raw is num
              ? raw.round()
              : int.tryParse(raw?.toString() ?? '') ?? 0;
    }

    return TennisSurfaceStats(
      firstServeIn: p('firstServeIn'),
      firstServeWon: p('firstServeWon'),
      secondServeWon: p('secondServeWon'),
      breakPointsSaved: p('breakPointsSaved'),
      breakPointsConverted: p('breakPointsConverted'),
      sampleMatches: i('sampleMatches'),
      surfaceElo: n('surfaceElo', 1500),
      averageOpponentSurfaceElo: n('averageOpponentSurfaceElo', 1500),
    );
  }
}

class TennisMathEngine {
  const TennisMathEngine();

  static const modelVersion = 'tennis_markov_surface_v1';

  Map<String, Object?> analyze({
    required TennisSurfaceStats playerA,
    required TennisSurfaceStats playerB,
    required int bestOf,
    int simulations = 100000,
    int seed = 42,
  }) {
    final a = _adjust(playerA);
    final b = _adjust(playerB);
    final serveA = _coupledServePoint(a, b);
    final serveB = _coupledServePoint(b, a);
    final safeBestOf = bestOf == 5 ? 5 : 3;
    final runs = simulations.clamp(10000, 100000);
    final random = Random(seed);
    var winsA = 0;

    for (var i = 0; i < runs; i++) {
      if (_simulateMatch(serveA, serveB, safeBestOf, random)) winsA++;
    }

    final rawA = winsA / runs;
    final uncertainty = _uncertainty(playerA, playerB, rawA);

    return {
      'modelVersion': modelVersion,
      'servePointProbA': _round(serveA),
      'servePointProbB': _round(serveB),
      'holdRateA': _round(_gameWinProbability(serveA)),
      'holdRateB': _round(_gameWinProbability(serveB)),
      'rawMatchProbA': _round(rawA),
      'rawMatchProbB': _round(1 - rawA),
      'simulationCount': runs,
      'dataQuality': _quality(playerA, playerB),
      'modelUncertainty': _round(uncertainty),
      'stabilityScore': _stability(serveA, serveB, safeBestOf, rawA),
    };
  }

  TennisSurfaceStats _adjust(TennisSurfaceStats s) {
    const prior = 12.0;
    final sample = s.sampleMatches.clamp(0, 100).toDouble();
    final elo = ((s.surfaceElo - s.averageOpponentSurfaceElo) / 4000)
        .clamp(-0.03, 0.03);
    double shrink(double value, double tour) =>
        ((value.clamp(0.01, 0.99) * sample + tour * prior) / (sample + prior))
            .clamp(0.01, 0.99);

    return TennisSurfaceStats(
      firstServeIn: shrink(s.firstServeIn, 0.62),
      firstServeWon: (shrink(s.firstServeWon, 0.70) + elo).clamp(0.30, 0.95),
      secondServeWon:
          (shrink(s.secondServeWon, 0.51) + elo / 2).clamp(0.20, 0.85),
      breakPointsSaved: shrink(s.breakPointsSaved, 0.61),
      breakPointsConverted: shrink(s.breakPointsConverted, 0.40),
      sampleMatches: s.sampleMatches,
      surfaceElo: s.surfaceElo,
      averageOpponentSurfaceElo: s.averageOpponentSurfaceElo,
    );
  }

  double _servePoint(TennisSurfaceStats s) {
    final base = s.firstServeIn * s.firstServeWon +
        (1 - s.firstServeIn) * s.secondServeWon;
    final clutch = (s.breakPointsSaved - 0.61) * 0.025;
    return (base + clutch).clamp(0.45, 0.80);
  }

  double _returnPoint(TennisSurfaceStats s) =>
      (0.35 + (s.breakPointsConverted - 0.40) * 0.08).clamp(0.20, 0.55);

  double _coupledServePoint(TennisSurfaceStats server, TennisSurfaceStats receiver) =>
      ((_servePoint(server) + (1 - _returnPoint(receiver))) / 2)
          .clamp(0.45, 0.80);

  double _gameWinProbability(double p) {
    final q = 1 - p;
    final preDeuce = pow(p, 4) * (1 + 4 * q + 10 * pow(q, 2));
    final reachDeuce = 20 * pow(p, 3) * pow(q, 3);
    final fromDeuce = (p * p) / (p * p + q * q);
    return (preDeuce + reachDeuce * fromDeuce).toDouble().clamp(0.0, 1.0);
  }

  bool _simulateMatch(double serveA, double serveB, int bestOf, Random random) {
    final needed = bestOf ~/ 2 + 1;
    var setsA = 0;
    var setsB = 0;
    var aServesFirst = random.nextBool();
    while (setsA < needed && setsB < needed) {
      final set = _simulateSet(serveA, serveB, aServesFirst, random);
      set.$1 ? setsA++ : setsB++;
      aServesFirst = set.$2;
    }
    return setsA > setsB;
  }

  (bool, bool) _simulateSet(
    double serveA,
    double serveB,
    bool aServesFirst,
    Random random,
  ) {
    var gamesA = 0;
    var gamesB = 0;
    var aServing = aServesFirst;
    while (true) {
      if (gamesA == 6 && gamesB == 6) {
        return (_tiebreak(serveA, serveB, aServing, random), !aServing);
      }
      final serverWon = _game(aServing ? serveA : serveB, random);
      if (aServing == serverWon) {
        gamesA++;
      } else {
        gamesB++;
      }
      aServing = !aServing;
      if ((gamesA >= 6 || gamesB >= 6) && (gamesA - gamesB).abs() >= 2) {
        return (gamesA > gamesB, aServing);
      }
    }
  }

  bool _game(double serverPoint, Random random) {
    var server = 0;
    var receiver = 0;
    while (true) {
      random.nextDouble() < serverPoint ? server++ : receiver++;
      if ((server >= 4 || receiver >= 4) && (server - receiver).abs() >= 2) {
        return server > receiver;
      }
    }
  }

  bool _tiebreak(double serveA, double serveB, bool aFirst, Random random) {
    var a = 0;
    var b = 0;
    var index = 0;
    while (true) {
      final aServing = index == 0
          ? aFirst
          : (((index - 1) ~/ 2).isEven ? !aFirst : aFirst);
      final aWins = aServing
          ? random.nextDouble() < serveA
          : random.nextDouble() >= serveB;
      aWins ? a++ : b++;
      index++;
      if ((a >= 7 || b >= 7) && (a - b).abs() >= 2) return a > b;
    }
  }

  int _quality(TennisSurfaceStats a, TennisSurfaceStats b) {
    final sample = ((min(a.sampleMatches, 30) + min(b.sampleMatches, 30)) / 60 * 55).round();
    final values = [
      a.firstServeIn, a.firstServeWon, a.secondServeWon,
      a.breakPointsSaved, a.breakPointsConverted,
      b.firstServeIn, b.firstServeWon, b.secondServeWon,
      b.breakPointsSaved, b.breakPointsConverted,
    ];
    final completeness = (values.where((v) => v > 0).length / 10 * 35).round();
    return (sample + completeness + 10).clamp(0, 100);
  }

  double _uncertainty(TennisSurfaceStats a, TennisSurfaceStats b, double p) {
    final sample = max(4, min(a.sampleMatches, b.sampleMatches)).toDouble();
    return (sqrt(p * (1 - p) / sample) +
            (20 - min(20, min(a.sampleMatches, b.sampleMatches))) / 500)
        .clamp(0.02, 0.15);
  }

  int _stability(double serveA, double serveB, int bestOf, double baseline) {
    var same = 0;
    for (var i = 0; i < 10; i++) {
      final random = Random(9000 + i);
      var wins = 0;
      for (var n = 0; n < 2500; n++) {
        if (_simulateMatch(
          (serveA + (i.isEven ? 0.005 : -0.005)).clamp(0.45, 0.80),
          (serveB + (i % 3 == 0 ? 0.005 : -0.005)).clamp(0.45, 0.80),
          bestOf,
          random,
        )) wins++;
      }
      if (((wins / 2500) >= 0.5) == (baseline >= 0.5)) same++;
    }
    return same * 10;
  }

  double _round(double value) => double.parse(value.toStringAsFixed(6));
}
