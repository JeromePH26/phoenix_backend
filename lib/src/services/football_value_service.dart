
import '../database/database.dart';
import 'football_service.dart';

class FootballValueService {
  FootballValueService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  static const modelVersion = 'value_check_v2_market_guard';

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

      if (selection['qualifiesForTip'] != true || marketKey.isEmpty) {
        final updated = <String, Object?>{
          ...selection,
          'modelVersion': modelVersion,
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
            'reason': 'Keine PHÖNIX-Einschätzung über 60 % vorhanden.',
          },
          'display': {
            ..._map(selection['display']),
            'showPhoenixTip': false,
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

      final rawOdds = await football.oddsForFixture(fixtureId);
      final oddsSummary = _oddsForMarket(
        rawOdds,
        marketKey,
      );

      final marketOdds = oddsSummary.best;
      final marketReferenceOdds = oddsSummary.median;

      final hasRequiredData = fairOdds != null &&
          fairOdds > 1 &&
          marketOdds != null &&
          marketOdds > 1 &&
          marketReferenceOdds != null &&
          marketReferenceOdds > 1;

      final valuePercent = hasRequiredData
          ? _round(((marketOdds! / fairOdds!) - 1) * 100)
          : null;

      final fairMarketDeviationPercent = hasRequiredData
          ? _round(
              ((marketReferenceOdds! - fairOdds!).abs() /
                      marketReferenceOdds) *
                  100,
            )
          : null;

      final minimumOddsPassed =
          marketOdds != null && marketOdds >= minimumMarketOdds;
      final minimumValuePassed =
          valuePercent != null && valuePercent >= minimumValuePercent;
      final maximumValuePassed = valuePercent != null &&
          valuePercent <= maximumAutomaticValuePercent;
      final marketGuardPassed = fairMarketDeviationPercent != null &&
          fairMarketDeviationPercent <=
              maximumFairMarketDeviationPercent;

      final isValueTip = hasRequiredData &&
          minimumOddsPassed &&
          minimumValuePassed &&
          maximumValuePassed &&
          marketGuardPassed;

      final updated = <String, Object?>{
        ...selection,
        'modelVersion': modelVersion,
        'value': {
          'status': hasRequiredData ? 'checked' : 'odds_unavailable',
          'marketOdds': marketOdds,
          'marketReferenceOdds': marketReferenceOdds,
          'bookmakerQuotesFound': oddsSummary.count,
          'fairOdds': fairOdds,
          'minimumMarketOdds': minimumMarketOdds,
          'minimumValuePercent': minimumValuePercent,
          'maximumAutomaticValuePercent': maximumAutomaticValuePercent,
          'maximumFairMarketDeviationPercent':
              maximumFairMarketDeviationPercent,
          'valuePercent': valuePercent,
          'fairMarketDeviationPercent': fairMarketDeviationPercent,
          'minimumOddsPassed': minimumOddsPassed,
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

    final best = found.last;
    final middle = found.length ~/ 2;
    final median = found.length.isOdd
        ? found[middle]
        : (found[middle - 1] + found[middle]) / 2;

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
            _containsAny(valueLabel, ['home', '1', 'home win']);
      case 'draw':
        return fullTimeMarket &&
            _isMatchWinner(betName) &&
            _containsAny(valueLabel, ['draw', 'x']);
      case 'awayWin':
        return fullTimeMarket &&
            _isMatchWinner(betName) &&
            _containsAny(valueLabel, ['away', '2', 'away win']);
      case 'homeOrDraw':
        return fullTimeMarket &&
            _isDoubleChanceMarket(betName) &&
            _containsAny(valueLabel, [
              '1x',
              'home or draw',
              'home/draw',
              'heim oder unentschieden',
            ]);
      case 'drawOrAway':
        return fullTimeMarket &&
            _isDoubleChanceMarket(betName) &&
            _containsAny(valueLabel, [
              'x2',
              'draw or away',
              'draw/away',
              'unentschieden oder auswarts',
            ]);
      case 'homeOrAway':
        return fullTimeMarket &&
            _isDoubleChanceMarket(betName) &&
            _containsAny(valueLabel, [
              '12',
              'home or away',
              'home/away',
            ]);
      case 'over15':
        return fullTimeMarket &&
            _isExactGoalsOverUnderMarket(betName) &&
            _isExactLine(valueLabel, over: true, line: 1.5);
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

  bool _isDoubleChanceMarket(String value) =>
      value.contains('double chance');

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
    final normalized = value
        .replaceAll(',', '.')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final prefix = over ? 'over' : 'under';
    return normalized == '$prefix ${line.toStringAsFixed(1)}';
  }

  bool _isBttsMarket(String value) =>
      value == 'both teams score' ||
      value == 'both teams to score' ||
      value == 'btts';

  bool _isSuspiciousOdds({
    required String marketKey,
    required double odds,
  }) {
    if (const {
      'over15',
      'over25',
      'under25',
      'under35',
      'bttsYes',
      'bttsNo',
      'homeOrDraw',
      'drawOrAway',
      'homeOrAway',
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

  double _round(double value) =>
      double.parse(value.toStringAsFixed(2));

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
