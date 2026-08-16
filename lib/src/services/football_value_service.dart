import '../database/database.dart';
import 'football_service.dart';

class FootballValueService {
  FootballValueService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  static const modelVersion = 'value_check_v3_strict_full_time_odds';
  static const double maximumRecommendedOdds = 4.0;

  Future<Map<String, Object?>> check({
    required int phaseTwoScanRunId,
    int limit = 1,
    double minimumMarketOdds = 1.40,
    double minimumValuePercent = 5.0,
    double maximumAutomaticValuePercent = 25.0,
    double maximumFairMarketDeviationPercent = 25.0,
  }) async {
    final rows = await database.marketSelectionsForValue(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit,
    );

    final outputs = <Map<String, Object?>>[];

    for (final row in rows) {
      final fixtureId = _string(row['fixture_id']);
      final selection = _map(row['selection']);
      final phoenixTip = _map(selection['phoenixTip']);
      final marketKey = _string(phoenixTip['marketKey']);
      final fairOdds = _number(phoenixTip['fairOdds']);
      final rawOdds = await football.oddsForFixture(fixtureId);
      final marketOddsByKey = <String, Object?>{};
      final allMarkets = selection['allMarkets'];
      if (allMarkets is List) {
        for (final rawMarket in allMarkets.whereType<Map>()) {
          final key = _string(rawMarket['key']);
          if (key.isEmpty) continue;
          final best = _oddsForMarket(rawOdds, key).best;
          if (best != null && best > 1) marketOddsByKey[key] = best;
        }
      }

      if (selection['qualifiesForTip'] != true || marketKey.isEmpty) {
        final updated = <String, Object?>{
          ...selection,
          'modelVersion': modelVersion,
          'marketOddsByKey': marketOddsByKey,
          'value': {
            'status': 'no_estimate',
            'marketOdds': null,
            'marketReferenceOdds': null,
            'fairOdds': fairOdds,
            'minimumMarketOdds': minimumMarketOdds,
            'minimumValuePercent': minimumValuePercent,
            'maximumAutomaticValuePercent': maximumAutomaticValuePercent,
            'maximumFairMarketDeviationPercent':
                maximumFairMarketDeviationPercent,
            'valuePercent': null,
            'isValueTip': false,
            'reason':
                'Keine Wettfreigabe: Die Modellwahrscheinlichkeit liegt unter der Mindestschwelle.',
          },
          'display': {
            ..._map(selection['display']),
            // Die Analyse bleibt sichtbar, auch wenn das Spiel nicht für
            // einen Einsatz freigegeben ist. So entsteht im Detailbereich
            // keine leere Karte; die UI kann klar zwischen Einschätzung und
            // Value-/Wettfreigabe unterscheiden.
            'showPhoenixTip': true,
            'showValueTip': false,
          },
        };

        await _save(
          phaseTwoScanRunId: phaseTwoScanRunId,
          fixtureId: fixtureId,
          selection: updated,
        );
        outputs.add(updated);
        continue;
      }

      final oddsSummary = _oddsForMarket(
        rawOdds,
        marketKey,
      );

      final marketOdds = oddsSummary.best;
      final marketReferenceOdds = oddsSummary.median;

      // Für 1X2 wird der Market-Guard gegen eine entvigte Konsens-
      // Wahrscheinlichkeit geprüft statt gegen die rohe Medianquote: die
      // rohe Quote hat die Buchmacher-Marge (Overround) noch eingepreist,
      // wodurch ein Teil der erlaubten Abweichung von der Marge statt von
      // einer echten Modell-vs-Markt-Differenz verzehrt wird. homeWin/draw/
      // awayWin kommen aus denselben, schon geladenen Buchmacherquoten -
      // kein zusätzlicher API-Call nötig.
      final deviggedProbability = _devigged1X2Probability(
        rawOdds: rawOdds,
        marketKey: marketKey,
      );

      final hasRequiredData = fairOdds != null &&
          fairOdds > 1 &&
          marketOdds != null &&
          marketOdds > 1 &&
          marketReferenceOdds != null &&
          marketReferenceOdds > 1;

      final valuePercent =
          hasRequiredData ? _round(((marketOdds / fairOdds) - 1) * 100) : null;

      final fairMarketDeviationPercent = !hasRequiredData
          ? null
          : deviggedProbability != null
              ? _round(
                  (((1 / fairOdds) - deviggedProbability).abs() /
                          deviggedProbability) *
                      100,
                )
              : _round(
                  ((marketReferenceOdds - fairOdds).abs() /
                          marketReferenceOdds) *
                      100,
                );

      final minimumOddsPassed =
          marketOdds != null && marketOdds >= minimumMarketOdds;
      final recommendationOddsPassed = marketOdds != null &&
          marketOdds >= minimumMarketOdds &&
          marketOdds <= maximumRecommendedOdds;
      final minimumValuePassed =
          valuePercent != null && valuePercent >= minimumValuePercent;
      final maximumValuePassed =
          valuePercent != null && valuePercent <= maximumAutomaticValuePercent;
      final marketGuardPassed = fairMarketDeviationPercent != null &&
          fairMarketDeviationPercent <= maximumFairMarketDeviationPercent;

      final isValueTip = hasRequiredData &&
          minimumOddsPassed &&
          minimumValuePassed &&
          maximumValuePassed &&
          marketGuardPassed;

      final updated = <String, Object?>{
        ...selection,
        'modelVersion': modelVersion,
        'marketOddsByKey': marketOddsByKey,
        'value': {
          'status': hasRequiredData ? 'checked' : 'odds_unavailable',
          'marketOdds': marketOdds,
          'marketReferenceOdds': marketReferenceOdds,
          'bookmakerQuotesFound': oddsSummary.count,
          'deviggedMarketProbability': deviggedProbability,
          'fairOdds': fairOdds,
          'minimumMarketOdds': minimumMarketOdds,
          'maximumRecommendedOdds': maximumRecommendedOdds,
          'minimumValuePercent': minimumValuePercent,
          'maximumAutomaticValuePercent': maximumAutomaticValuePercent,
          'maximumFairMarketDeviationPercent':
              maximumFairMarketDeviationPercent,
          'valuePercent': valuePercent,
          'fairMarketDeviationPercent': fairMarketDeviationPercent,
          'minimumOddsPassed': minimumOddsPassed,
          'recommendationOddsPassed': recommendationOddsPassed,
          'minimumValuePassed': minimumValuePassed,
          'maximumValuePassed': maximumValuePassed,
          'marketGuardPassed': marketGuardPassed,
          'isValueTip': isValueTip,
          'reason': _reason(
            hasRequiredData: hasRequiredData,
            minimumOddsPassed: minimumOddsPassed,
            minimumValuePassed: minimumValuePassed,
            maximumValuePassed: maximumValuePassed,
            marketGuardPassed: marketGuardPassed,
          ),
        },
        'display': {
          ..._map(selection['display']),
          // Value darf eine interne Kennzahl bleiben. Der sichtbare
          // PHÖNIX-Tipp richtet sich nach Modell/Stabilität, wird aber nur
          // mit einer plausiblen Vollzeitquote freigegeben. Damit kann z. B.
          // eine 16.00 niemals als Standard-Tipp erscheinen.
          // Der PHÖNIX-Tipp ist die Modellaussage und darf nicht verschwinden,
          // wenn eine Quote fehlt oder vom Markt-Guard abgelehnt wird. Nur
          // `showValueTip` bedeutet eine tatsächlich geprüfte Wettfreigabe.
          'showPhoenixTip': true,
          'showValueTip': isValueTip,
        },
      };

      await _save(
        phaseTwoScanRunId: phaseTwoScanRunId,
        fixtureId: fixtureId,
        selection: updated,
      );
      outputs.add(updated);
    }

    return {
      'status': 'completed',
      'phaseTwoScanRunId': phaseTwoScanRunId,
      'modelVersion': modelVersion,
      'processed': outputs.length,
      'valueTips': outputs
          .where((row) => _map(row['value'])['isValueTip'] == true)
          .length,
      'results': outputs,
    };
  }

  Future<void> _save({
    required int phaseTwoScanRunId,
    required String fixtureId,
    required Map<String, Object?> selection,
  }) {
    return database.saveFootballMarketSelection(
      phaseTwoScanRunId: phaseTwoScanRunId,
      fixtureId: fixtureId,
      modelVersion: modelVersion,
      selection: selection,
    );
  }

  /// Entvigte 1X2-Konsenswahrscheinlichkeit für [marketKey] (nur homeWin/
  /// draw/awayWin - andere Märkte liefern weiterhin null und fallen auf den
  /// bisherigen rohquoten-basierten Vergleich zurück). Nimmt den Median je
  /// Ausgang aus denselben, schon geladenen Buchmacherquoten, rechnet in
  /// Wahrscheinlichkeiten um und normalisiert sie auf 100 %, damit die
  /// Buchmacher-Marge nicht mehr in den Market-Guard-Vergleich einfließt.
  double? _devigged1X2Probability({
    required List<Map<String, Object?>> rawOdds,
    required String marketKey,
  }) {
    const outcomes = ['homeWin', 'draw', 'awayWin'];
    if (!outcomes.contains(marketKey)) return null;

    final rawProbabilities = <String, double>{};
    for (final outcome in outcomes) {
      final median = _oddsForMarket(rawOdds, outcome).median;
      if (median == null || median <= 1) return null;
      rawProbabilities[outcome] = 1 / median;
    }

    final overround = rawProbabilities.values.fold<double>(
      0,
      (sum, value) => sum + value,
    );
    if (overround <= 0) return null;

    return rawProbabilities[marketKey]! / overround;
  }

  _OddsSummary _oddsForMarket(
    List<Map<String, Object?>> rows,
    String marketKey,
  ) {
    final found = <double>[];

    for (final row in rows) {
      final bookmakers = row['bookmakers'];
      if (bookmakers is! List) continue;

      for (final bookmakerRaw in bookmakers) {
        if (bookmakerRaw is! Map) continue;
        final bookmaker = Map<String, Object?>.from(bookmakerRaw);
        final bets = bookmaker['bets'];
        if (bets is! List) continue;

        for (final betRaw in bets) {
          if (betRaw is! Map) continue;
          final bet = Map<String, Object?>.from(betRaw);
          final betName = _normalize(_string(bet['name']));
          final values = bet['values'];
          if (values is! List) continue;

          for (final valueRaw in values) {
            if (valueRaw is! Map) continue;
            final value = Map<String, Object?>.from(valueRaw);
            final label = _normalize(_string(value['value']));
            final odd = _number(value['odd']);
            if (odd == null || odd <= 1) continue;

            if (_matches(
              marketKey: marketKey,
              betName: betName,
              valueLabel: label,
            )) {
              if (_isSuspiciousOdds(
                marketKey: marketKey,
                odds: odd,
              )) {
                continue;
              }
              found.add(odd);
            }
          }
        }
      }
    }

    if (found.isEmpty) return const _OddsSummary();
    found.sort();

    final middle = found.length ~/ 2;
    final median = found.length.isOdd
        ? found[middle]
        : (found[middle - 1] + found[middle]) / 2;

    // Ein einzelner verspätet aktualisierter Buchmacher kann eine völlig
    // abweichende Quote liefern. Sie darf nicht als angebliche "beste Quote"
    // in der App landen. Der höchste Wert innerhalb von 12 % des Marktmedians
    // bleibt sichtbar, echte Ausreißer werden verworfen.
    final plausible =
        found.where((odd) => odd <= median * 1.12).toList(growable: false);
    final best = plausible.isEmpty ? median : plausible.last;

    return _OddsSummary(
      best: _round(best),
      median: _round(median),
      count: found.length,
    );
  }

  bool _matches({
    required String marketKey,
    required String betName,
    required String valueLabel,
  }) {
    final fullTimeMarket = _isFullTimeMarket(betName);

    switch (marketKey) {
      case 'homeWin':
        return fullTimeMarket &&
            _isMatchWinner(betName) &&
            _isMatchWinnerSelection(valueLabel, outcome: 'home');
      case 'draw':
        return fullTimeMarket &&
            _isMatchWinner(betName) &&
            _isMatchWinnerSelection(valueLabel, outcome: 'draw');
      case 'awayWin':
        return fullTimeMarket &&
            _isMatchWinner(betName) &&
            _isMatchWinnerSelection(valueLabel, outcome: 'away');
      case 'homeOrDraw':
      case 'dc1x':
        return fullTimeMarket &&
            _isDoubleChanceMarket(betName) &&
            _containsAny(valueLabel, [
              '1x',
              'home or draw',
              'home/draw',
              'heim oder unentschieden',
            ]);
      case 'drawOrAway':
      case 'dcX2':
        return fullTimeMarket &&
            _isDoubleChanceMarket(betName) &&
            _containsAny(valueLabel, [
              'x2',
              'draw or away',
              'draw/away',
              'unentschieden oder auswarts',
            ]);
      case 'homeOrAway':
      case 'dc12':
        return fullTimeMarket &&
            _isDoubleChanceMarket(betName) &&
            _containsAny(valueLabel, [
              '12',
              'home or away',
              'home/away',
            ]);
      case 'over05':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: true, line: 0.5);
      case 'under05':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: false, line: 0.5);
      case 'over15':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: true, line: 1.5);
      case 'under15':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: false, line: 1.5);
      case 'over25':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: true, line: 2.5);
      case 'under25':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: false, line: 2.5);
      case 'under35':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: false, line: 3.5);
      case 'over35':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: true, line: 3.5);
      case 'over45':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: true, line: 4.5);
      case 'under45':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: false, line: 4.5);
      case 'over55':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: true, line: 5.5);
      case 'under55':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: false, line: 5.5);
      case 'dnbHome':
        return fullTimeMarket &&
            _isDrawNoBetMarket(betName) &&
            _isDrawNoBetSelection(valueLabel, home: true);
      case 'dnbAway':
        return fullTimeMarket &&
            _isDrawNoBetMarket(betName) &&
            _isDrawNoBetSelection(valueLabel, home: false);
      case 'ehHomeMinus1':
        return fullTimeMarket &&
            _isEuropeanHandicap(betName) &&
            _isEuropeanHandicapValue(valueLabel, side: 'home', line: -1);
      case 'ehDrawMinus1':
        return fullTimeMarket &&
            _isEuropeanHandicap(betName) &&
            _isEuropeanHandicapValue(valueLabel, side: 'draw', line: -1);
      case 'ehAwayPlus1':
        return fullTimeMarket &&
            _isEuropeanHandicap(betName) &&
            _isEuropeanHandicapValue(valueLabel, side: 'away', line: 1);
      case 'ehHomeMinus2':
        return fullTimeMarket &&
            _isEuropeanHandicap(betName) &&
            _isEuropeanHandicapValue(valueLabel, side: 'home', line: -2);
      case 'ehDrawMinus2':
        return fullTimeMarket &&
            _isEuropeanHandicap(betName) &&
            _isEuropeanHandicapValue(valueLabel, side: 'draw', line: -2);
      case 'ehAwayPlus2':
        return fullTimeMarket &&
            _isEuropeanHandicap(betName) &&
            _isEuropeanHandicapValue(valueLabel, side: 'away', line: 2);
      case 'combo1xUnder35':
        return _isCombination(
          betName,
          valueLabel,
          result: '1x',
          total: 'under 3.5',
        );
      case 'comboX2Under35':
        return _isCombination(
          betName,
          valueLabel,
          result: 'x2',
          total: 'under 3.5',
        );
      case 'combo1xOver15':
        return _isCombination(
          betName,
          valueLabel,
          result: '1x',
          total: 'over 1.5',
        );
      case 'comboX2Over15':
        return _isCombination(
          betName,
          valueLabel,
          result: 'x2',
          total: 'over 1.5',
        );
      case 'comboHomeOver15':
        return _isCombination(
          betName,
          valueLabel,
          result: 'home',
          total: 'over 1.5',
        );
      case 'comboAwayOver15':
        return _isCombination(
          betName,
          valueLabel,
          result: 'away',
          total: 'over 1.5',
        );
      case 'bttsYes':
        return fullTimeMarket &&
            _isBttsMarket(betName) &&
            _containsAny(valueLabel, ['yes', 'ja']);
      case 'bttsNo':
        return fullTimeMarket &&
            _isBttsMarket(betName) &&
            _containsAny(valueLabel, ['no', 'nein']);
      default:
        return false;
    }
  }

  bool _isFullTimeMarket(String betName) {
    final blocked = <String>[
      '1st half',
      'first half',
      '2nd half',
      'second half',
      'half time',
      'halftime',
      'team total',
      'home team total',
      'away team total',
      'asian',
      'exact',
      'correct score',
      'goal range',
      'corners',
      'cards',
    ];

    if (blocked.any(betName.contains)) return false;

    return betName.contains('full time') ||
        betName.contains('match') ||
        betName.contains('double chance') ||
        betName.contains('draw no bet') ||
        betName.contains('european handicap') ||
        (betName.contains('result') && betName.contains('total')) ||
        betName == 'dnb' ||
        betName == 'goals over/under' ||
        betName == 'over/under' ||
        betName == 'both teams score' ||
        betName == 'both teams to score' ||
        betName == 'match winner' ||
        betName == 'winner' ||
        betName == '1x2';
  }

  bool _isMatchWinner(String value) =>
      value == 'match winner' ||
      value == 'winner' ||
      value == '1x2' ||
      value == 'full time result' ||
      value == 'match result';

  bool _isMatchWinnerSelection(String value, {required String outcome}) {
    final normalized = value.trim();
    return switch (outcome) {
      'home' =>
        const {'home', 'home team', 'home win', '1'}.contains(normalized),
      'draw' => const {'draw', 'x'}.contains(normalized),
      'away' =>
        const {'away', 'away team', 'away win', '2'}.contains(normalized),
      _ => false,
    };
  }

  bool _isDoubleChanceMarket(String value) => value.contains('double chance');

  bool _isDrawNoBetMarket(String value) =>
      value.contains('draw no bet') || value == 'dnb';

  bool _isDrawNoBetSelection(String value, {required bool home}) {
    final normalized = value.toLowerCase().trim();
    return home
        ? normalized == 'home' || normalized == 'home team' || normalized == '1'
        : normalized == 'away' ||
            normalized == 'away team' ||
            normalized == '2';
  }

  bool _isExactGoalsOverUnderMarket(String value) =>
      value == 'goals over/under' ||
      value == 'over/under' ||
      value == 'full time goals over/under' ||
      value == 'match goals over/under' ||
      value == 'total goals';

  bool _isExactLine(
    String value, {
    required bool over,
    required double line,
  }) {
    final normalized =
        value.replaceAll(',', '.').replaceAll(RegExp(r'\s+'), ' ').trim();

    final prefix = over ? 'over' : 'under';
    return normalized == '$prefix ${line.toStringAsFixed(1)}';
  }

  bool _isBttsMarket(String value) =>
      value == 'both teams score' ||
      value == 'both teams to score' ||
      value == 'btts';

  bool _isEuropeanHandicap(String value) =>
      value.contains('handicap') && !value.contains('asian');

  bool _isEuropeanHandicapValue(
    String value, {
    required String side,
    required int line,
  }) {
    final normalized = value
        .toLowerCase()
        .replaceAll(',', '.')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final sideMatches = switch (side) {
      'home' => RegExp(r'(^|\s)(home|1)(?=\s|$)').hasMatch(normalized),
      'away' => RegExp(r'(^|\s)(away|2)(?=\s|$)').hasMatch(normalized),
      'draw' => RegExp(r'(^|\s)(draw|x)(?=\s|$)').hasMatch(normalized),
      _ => false,
    };
    if (!sideMatches) return false;
    final signedLine = line > 0 ? '+$line' : '$line';
    return normalized.contains(signedLine);
  }

  bool _isCombination(
    String betName,
    String valueLabel, {
    required String result,
    required String total,
  }) {
    if (!_isFullTimeMarket(betName)) return false;
    final joined = '$betName $valueLabel'.replaceAll(',', '.');
    final suitableMarket = joined.contains('result') ||
        joined.contains('double chance') ||
        joined.contains('total');
    if (!suitableMarket || !joined.contains(total)) return false;
    return switch (result) {
      '1x' => joined.contains('1x') || joined.contains('home or draw'),
      'x2' => joined.contains('x2') || joined.contains('draw or away'),
      'home' => joined.contains('home') || joined.contains('1 and'),
      'away' => joined.contains('away') || joined.contains('2 and'),
      _ => false,
    };
  }

  bool _isSuspiciousOdds({
    required String marketKey,
    required double odds,
  }) {
    if (const {
      'over15',
      'over05',
      'under05',
      'under15',
      'over25',
      'under25',
      'over35',
      'under35',
      'over45',
      'under45',
      'over55',
      'under55',
      'bttsYes',
      'bttsNo',
      'homeOrDraw',
      'drawOrAway',
      'homeOrAway',
      'dc1x',
      'dc12',
      'dcX2',
      'dnbHome',
      'dnbAway',
    }.contains(marketKey)) {
      return odds > 5.00;
    }

    return odds > 20.00;
  }

  String _reason({
    required bool hasRequiredData,
    required bool minimumOddsPassed,
    required bool minimumValuePassed,
    required bool maximumValuePassed,
    required bool marketGuardPassed,
  }) {
    if (!hasRequiredData) {
      return 'Keine passende Buchmacherquote für diesen Markt gefunden.';
    }
    if (!minimumOddsPassed) {
      return 'Die Buchmacherquote liegt unter der Mindestquote.';
    }
    if (!minimumValuePassed) {
      return 'Der Quotenvorteil liegt unter 5 % Value.';
    }
    if (!maximumValuePassed) {
      return 'Value über 25 % ist auffällig und wird nicht automatisch freigegeben.';
    }
    if (!marketGuardPassed) {
      return 'Die faire Quote weicht zu stark vom Marktmittel ab.';
    }
    return 'Mindestens 5 % Value und Markt-Plausibilitätsprüfung erfüllt.';
  }

  bool _containsAny(String value, List<String> needles) =>
      needles.any((needle) => value == needle || value.contains(needle));

  String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  double _round(double value) => double.parse(value.toStringAsFixed(2));

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';
}

class _OddsSummary {
  const _OddsSummary({
    this.best,
    this.median,
    this.count = 0,
  });

  final double? best;
  final double? median;
  final int count;
}
