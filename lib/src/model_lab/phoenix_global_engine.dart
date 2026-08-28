import 'dart:math' as math;

import 'global_goals_v1_engine.dart';

/// Die eine globale PHÖNIX-Referenz für jede Fußballpartie.
///
/// Sie erzeugt ausschließlich erwartete Tore. Die nachgelagerte
/// Monte-Carlo-Simulation leitet daraus 1X2, Tor-, BTTS-, DNB-,
/// Doppelte-Chance- und Teamtor-Märkte konsistent aus *derselben*
/// Ergebnisverteilung ab. Es gibt damit keine getrennten Live-Modelle je
/// Markt. Liga-spezifische Engines können später nur diese Torerwartung für
/// ihre eigene Liga herausfordern, nie einzelne Markt-Wahrscheinlichkeiten.
class PhoenixGlobalEngine {
  const PhoenixGlobalEngine._();

  static const version = 'PHOENIX_GLOBAL_ENGINE_V1';

  static PhoenixGlobalEngineResult compute({
    required Map<String, Object?> availability,
    required String homeTeamId,
    required String awayTeamId,
    required double safeHomeFallback,
    required double safeAwayFallback,
    double? leagueAvgHomeGoalsPerGame,
    double? leagueAvgAwayGoalsPerGame,
    double homeContextDelta = 0,
    double awayContextDelta = 0,
  }) {
    final globalGoals = GlobalGoalsV1Engine.compute(
      availability: availability,
      homeTeamId: homeTeamId,
      awayTeamId: awayTeamId,
      leagueAvgHomeGoalsPerGame: leagueAvgHomeGoalsPerGame,
      leagueAvgAwayGoalsPerGame: leagueAvgAwayGoalsPerGame,
    );

    final usesGlobalFeatures =
        globalGoals.expectedHome != null && globalGoals.expectedAway != null;

    // Die Feature-Engine ist ein nützlicher eigener Blick auf das Spiel, aber
    // sie darf bei fehlenden xG-, Kader- und Schussdaten nicht eine gesamte
    // Marktmeinung überstimmen. Zuerst wird sie daher konservativ gegen die
    // bereits geglättete Liga-Basis zurückgeführt. Anschließend kalibrieren
    // wir die *eine* Torverteilung gegen den entviggten 1X2-Konsens. Somit
    // bleiben 1X2, Tore, BTTS und Teamtore weiterhin exakt konsistent.
    final featureHome = globalGoals.expectedHome ?? safeHomeFallback;
    final featureAway = globalGoals.expectedAway ?? safeAwayFallback;
    const featureWeight = 0.55;
    final conservativeHome = usesGlobalFeatures
        ? _blend(safeHomeFallback, featureHome, featureWeight)
        : safeHomeFallback;
    final conservativeAway = usesGlobalFeatures
        ? _blend(safeAwayFallback, featureAway, featureWeight)
        : safeAwayFallback;

    final consensus = _MarketConsensus.fromAvailability(availability);
    final calibration = _calibrateToMarket(
      home: conservativeHome,
      away: conservativeAway,
      consensus: consensus,
      // Ohne echte xG ist der vollständige Buchmacher-Konsens der bessere
      // Anker. Mit echtem xG darf das Modell etwas mehr Eigengewicht haben.
      marketWeight: availability['realXgAvailable'] == true ? 0.58 : 0.72,
    );
    final baseHome = calibration.home;
    final baseAway = calibration.away;

    return PhoenixGlobalEngineResult(
      expectedHome: (baseHome + homeContextDelta).clamp(0.20, 3.80).toDouble(),
      expectedAway: (baseAway + awayContextDelta).clamp(0.20, 3.80).toDouble(),
      baseHome: baseHome,
      baseAway: baseAway,
      source: calibration.applied
          ? 'global_goals_v1_market_calibrated'
          : usesGlobalFeatures
              ? 'global_goals_v1_conservative'
              : 'global_safe_fallback',
      usesGlobalFeatures: usesGlobalFeatures,
      homeFeatureCoverage: globalGoals.homeFeatureCoverage,
      awayFeatureCoverage: globalGoals.awayFeatureCoverage,
      marketCalibration: calibration.toJson(),
    );
  }

  static double _blend(double base, double value, double weight) =>
      base + (value - base) * weight;

  /// Sucht die nächstliegende unabhängige Poisson-Verteilung, die sowohl die
  /// eigenen Daten als auch den entviggten Quoten-Konsens erklärt. Eine
  /// Kalibrierung auf Torerwartungen statt auf einzelnen Tipps verhindert
  /// Widersprüche wie "Heimsieg schwach", aber "1X hoch".
  static _Calibration _calibrateToMarket({
    required double home,
    required double away,
    required _MarketConsensus consensus,
    required double marketWeight,
  }) {
    if (!consensus.has1X2) return _Calibration.notApplied(home, away);

    final model = _PoissonMarkets.fromExpectedGoals(home, away);
    final targetHome = _blend(model.homeWin, consensus.homeWin!, marketWeight);
    final targetDraw = _blend(model.draw, consensus.draw!, marketWeight);
    final targetAway = _blend(model.awayWin, consensus.awayWin!, marketWeight);
    final targetOver25 = consensus.over25 == null
        ? null
        : _blend(model.over25, consensus.over25!, marketWeight);
    final targetBttsYes = consensus.bttsYes == null
        ? null
        : _blend(model.bttsYes, consensus.bttsYes!, marketWeight);

    var bestHome = home;
    var bestAway = away;
    var bestScore = double.infinity;
    // 0.05 reicht für eine feinere Kalibrierung als die sichtbare Anzeige;
    // bei einem Tages-Scan sind es nur rund 5.000 deterministische Kandidaten
    // je Spiel, keine API-Requests und keine Zufalls-Simulationen.
    for (var homeStep = 4; homeStep <= 76; homeStep++) {
      final candidateHome = homeStep / 20;
      for (var awayStep = 4; awayStep <= 76; awayStep++) {
        final candidateAway = awayStep / 20;
        final candidate = _PoissonMarkets.fromExpectedGoals(
          candidateHome,
          candidateAway,
        );
        var score = 2.5 * math.pow(candidate.homeWin - targetHome, 2) +
            2.0 * math.pow(candidate.draw - targetDraw, 2) +
            2.5 * math.pow(candidate.awayWin - targetAway, 2);
        if (targetOver25 != null) {
          score += 1.4 * math.pow(candidate.over25 - targetOver25, 2);
        }
        if (targetBttsYes != null) {
          score += 1.2 * math.pow(candidate.bttsYes - targetBttsYes, 2);
        }
        // Kleine Regularisierung: Der Markt ist Anker, keine harte Kopie.
        score += 0.12 * math.pow(candidateHome - home, 2);
        score += 0.12 * math.pow(candidateAway - away, 2);
        if (score < bestScore) {
          bestScore = score.toDouble();
          bestHome = candidateHome;
          bestAway = candidateAway;
        }
      }
    }

    return _Calibration(
      home: bestHome,
      away: bestAway,
      applied: true,
      marketWeight: marketWeight,
      consensus: consensus,
    );
  }
}

class PhoenixGlobalEngineResult {
  const PhoenixGlobalEngineResult({
    required this.expectedHome,
    required this.expectedAway,
    required this.baseHome,
    required this.baseAway,
    required this.source,
    required this.usesGlobalFeatures,
    required this.homeFeatureCoverage,
    required this.awayFeatureCoverage,
    required this.marketCalibration,
  });

  final double expectedHome;
  final double expectedAway;
  final double baseHome;
  final double baseAway;
  final String source;
  final bool usesGlobalFeatures;
  final Map<String, Object?> homeFeatureCoverage;
  final Map<String, Object?> awayFeatureCoverage;
  final Map<String, Object?> marketCalibration;
}

class _Calibration {
  const _Calibration({
    required this.home,
    required this.away,
    required this.applied,
    this.marketWeight,
    this.consensus,
  });

  factory _Calibration.notApplied(double home, double away) =>
      _Calibration(home: home, away: away, applied: false);

  final double home;
  final double away;
  final bool applied;
  final double? marketWeight;
  final _MarketConsensus? consensus;

  Map<String, Object?> toJson() => {
        'applied': applied,
        if (marketWeight != null) 'marketWeight': marketWeight,
        if (consensus != null) ...consensus!.toJson(),
      };
}

class _MarketConsensus {
  const _MarketConsensus({
    this.homeWin,
    this.draw,
    this.awayWin,
    this.over25,
    this.bttsYes,
    required this.bookmakers,
  });

  final double? homeWin;
  final double? draw;
  final double? awayWin;
  final double? over25;
  final double? bttsYes;
  final int bookmakers;

  bool get has1X2 => homeWin != null && draw != null && awayWin != null;

  static _MarketConsensus fromAvailability(Map<String, Object?> availability) {
    final rows = availability['oddsData'];
    if (rows is! List) return const _MarketConsensus(bookmakers: 0);
    final home = <double>[];
    final draw = <double>[];
    final away = <double>[];
    final over25 = <double>[];
    final under25 = <double>[];
    final bttsYes = <double>[];
    final bttsNo = <double>[];
    var bookmakerCount = 0;

    for (final row in rows.whereType<Map>()) {
      final bookmakers = row['bookmakers'];
      if (bookmakers is! List) continue;
      for (final rawBookmaker in bookmakers.whereType<Map>()) {
        bookmakerCount++;
        final bets = rawBookmaker['bets'];
        if (bets is! List) continue;
        for (final rawBet in bets.whereType<Map>()) {
          final name = _normalise(rawBet['name']);
          final values = rawBet['values'];
          if (values is! List || _isPartialTime(name)) continue;
          for (final rawValue in values.whereType<Map>()) {
            final label = _normalise(rawValue['value']);
            final odd = _number(rawValue['odd']);
            if (odd == null || odd <= 1 || odd > 25) continue;
            if (_isMatchWinner(name)) {
              if (label == 'home' || label == '1') home.add(odd);
              if (label == 'draw' || label == 'x') draw.add(odd);
              if (label == 'away' || label == '2') away.add(odd);
            } else if (_isGoalsOverUnder(name) && _isLine(label, 2.5)) {
              if (label.startsWith('over')) over25.add(odd);
              if (label.startsWith('under')) under25.add(odd);
            } else if (_isBtts(name)) {
              if (label == 'yes') bttsYes.add(odd);
              if (label == 'no') bttsNo.add(odd);
            }
          }
        }
      }
    }

    final homeOdd = _median(home);
    final drawOdd = _median(draw);
    final awayOdd = _median(away);
    final overOdd = _median(over25);
    final underOdd = _median(under25);
    final yesOdd = _median(bttsYes);
    final noOdd = _median(bttsNo);
    return _MarketConsensus(
      homeWin: _devig(homeOdd, [homeOdd, drawOdd, awayOdd]),
      draw: _devig(drawOdd, [homeOdd, drawOdd, awayOdd]),
      awayWin: _devig(awayOdd, [homeOdd, drawOdd, awayOdd]),
      over25: _devig(overOdd, [overOdd, underOdd]),
      bttsYes: _devig(yesOdd, [yesOdd, noOdd]),
      bookmakers: bookmakerCount,
    );
  }

  Map<String, Object?> toJson() => {
        'bookmakers': bookmakers,
        if (homeWin != null) 'homeWin': homeWin,
        if (draw != null) 'draw': draw,
        if (awayWin != null) 'awayWin': awayWin,
        if (over25 != null) 'over25': over25,
        if (bttsYes != null) 'bttsYes': bttsYes,
      };

  static bool _isPartialTime(String name) =>
      name.contains('half') ||
      name.contains('period') ||
      name.contains('1st') ||
      name.contains('2nd');
  static bool _isMatchWinner(String name) =>
      name.contains('match winner') || name == '1x2' || name == 'winner';
  static bool _isGoalsOverUnder(String name) =>
      name.contains('over under') || name.contains('goals over under');
  static bool _isBtts(String name) =>
      name.contains('both teams score') || name.contains('btts');
  static bool _isLine(String label, double line) {
    final match = RegExp(r'(\\d+)[.,](\\d+)').firstMatch(label);
    if (match == null) return false;
    final parsed = double.tryParse('${match.group(1)}.${match.group(2)}');
    return parsed != null && (parsed - line).abs() < 0.01;
  }

  static String _normalise(Object? value) => value
      .toString()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9.,]+'), ' ')
      .trim();
  static double? _number(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    values.sort();
    final middle = values.length ~/ 2;
    return values.length.isOdd
        ? values[middle]
        : (values[middle - 1] + values[middle]) / 2;
  }

  static double? _devig(double? selected, List<double?> all) {
    if (selected == null ||
        selected <= 1 ||
        all.any((odd) => odd == null || odd <= 1)) {
      return null;
    }
    final inverseSum = all.fold<double>(0, (sum, odd) => sum + 1 / odd!);
    return inverseSum <= 0 ? null : (1 / selected) / inverseSum;
  }
}

class _PoissonMarkets {
  const _PoissonMarkets({
    required this.homeWin,
    required this.draw,
    required this.awayWin,
    required this.over25,
    required this.bttsYes,
  });

  final double homeWin;
  final double draw;
  final double awayWin;
  final double over25;
  final double bttsYes;

  factory _PoissonMarkets.fromExpectedGoals(double home, double away) {
    final homeP = _probabilities(home);
    final awayP = _probabilities(away);
    var homeWin = 0.0;
    var draw = 0.0;
    var awayWin = 0.0;
    var under25 = 0.0;
    for (var h = 0; h < homeP.length; h++) {
      for (var a = 0; a < awayP.length; a++) {
        final probability = homeP[h] * awayP[a];
        if (h > a) homeWin += probability;
        if (h == a) draw += probability;
        if (h < a) awayWin += probability;
        if (h + a <= 2) under25 += probability;
      }
    }
    final mass = homeWin + draw + awayWin;
    return _PoissonMarkets(
      homeWin: homeWin / mass,
      draw: draw / mass,
      awayWin: awayWin / mass,
      over25: 1 - under25,
      bttsYes: (1 - homeP.first) * (1 - awayP.first),
    );
  }

  static List<double> _probabilities(double lambda) {
    final probabilities = <double>[math.exp(-lambda)];
    for (var goals = 1; goals <= 12; goals++) {
      probabilities.add(probabilities.last * lambda / goals);
    }
    return probabilities;
  }
}
