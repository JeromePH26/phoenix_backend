import '../database/database.dart';
import 'football_service.dart';

class FootballValueService {
  FootballValueService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  static const modelVersion = 'value_check_v1';

  Future<Map<String, Object?>> check({
    required int phaseTwoScanRunId,
    int limit = 1,
    double minimumMarketOdds = 1.40,
    double minimumValuePercent = 5.0,
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
      final marketOdds = _bestOddsForMarket(
        rawOdds,
        marketKey,
      );

      final hasRequiredData =
          fairOdds != null &&
          fairOdds > 0 &&
          marketOdds != null &&
          marketOdds > 0;

      final valuePercent = hasRequiredData
          ? _round(((marketOdds! / fairOdds!) - 1) * 100)
          : null;

      final minimumOddsPassed =
          marketOdds != null && marketOdds >= minimumMarketOdds;
      final minimumValuePassed =
          valuePercent != null && valuePercent >= minimumValuePercent;
      final isValueTip = minimumOddsPassed && minimumValuePassed;

      final updated = <String, Object?>{
        ...selection,
        'modelVersion': modelVersion,
        'value': {
          'status': hasRequiredData ? 'checked' : 'odds_unavailable',
          'marketOdds': marketOdds,
          'fairOdds': fairOdds,
          'minimumMarketOdds': minimumMarketOdds,
          'minimumValuePercent': minimumValuePercent,
          'valuePercent': valuePercent,
          'minimumOddsPassed': minimumOddsPassed,
          'minimumValuePassed': minimumValuePassed,
          'isValueTip': isValueTip,
          'reason': _reason(
            hasRequiredData: hasRequiredData,
            minimumOddsPassed: minimumOddsPassed,
            minimumValuePassed: minimumValuePassed,
          ),
        },
        'display': {
          ..._map(selection['display']),
          'showPhoenixTip': true,
          'showValueTip': isValueTip,
        },
      };

      await database.saveFootballMarketSelection(
        phaseTwoScanRunId: phaseTwoScanRunId,
        fixtureId: fixtureId,
        modelVersion: modelVersion,
        selection: updated,
      );

      outputs.add(updated);
    }

    return {
      'status': 'completed',
      'phaseTwoScanRunId': phaseTwoScanRunId,
      'modelVersion': modelVersion,
      'processed': outputs.length,
      'results': outputs,
    };
  }

  double? _bestOddsForMarket(
    List<Map<String, Object?>> rows,
    String marketKey,
  ) {
    double? best;

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
              if (best == null || odd > best) {
                best = odd;
              }
            }
          }
        }
      }
    }

    return best == null ? null : _round(best);
  }

  bool _matches({
    required String marketKey,
    required String betName,
    required String valueLabel,
  }) {
    switch (marketKey) {
      case 'homeWin':
        return _isMatchWinner(betName) &&
            (valueLabel == 'home' ||
                valueLabel == '1' ||
                valueLabel.contains('home'));
      case 'draw':
        return _isMatchWinner(betName) &&
            (valueLabel == 'draw' ||
                valueLabel == 'x' ||
                valueLabel.contains('draw'));
      case 'awayWin':
        return _isMatchWinner(betName) &&
            (valueLabel == 'away' ||
                valueLabel == '2' ||
                valueLabel.contains('away'));
      case 'over25':
        return _isGoalsMarket(betName) &&
            (valueLabel.contains('over 2.5') ||
                valueLabel.contains('over 2,5'));
      case 'under25':
        return _isGoalsMarket(betName) &&
            (valueLabel.contains('under 2.5') ||
                valueLabel.contains('under 2,5'));
      case 'bttsYes':
        return _isBttsMarket(betName) &&
            (valueLabel == 'yes' ||
                valueLabel == 'ja' ||
                valueLabel.contains('yes'));
      case 'bttsNo':
        return _isBttsMarket(betName) &&
            (valueLabel == 'no' ||
                valueLabel == 'nein' ||
                valueLabel.contains('no'));
      default:
        return false;
    }
  }

  bool _isMatchWinner(String value) =>
      value.contains('match winner') ||
      value == 'winner' ||
      value.contains('1x2');

  bool _isGoalsMarket(String value) =>
      value.contains('goals over/under') ||
      value.contains('over/under') ||
      value.contains('total goals');

  bool _isBttsMarket(String value) =>
      value.contains('both teams score') ||
      value.contains('both teams to score') ||
      value.contains('btts');

  String _reason({
    required bool hasRequiredData,
    required bool minimumOddsPassed,
    required bool minimumValuePassed,
  }) {
    if (!hasRequiredData) {
      return 'Keine passende Buchmacherquote für diesen Markt gefunden.';
    }
    if (!minimumOddsPassed) {
      return 'Die Buchmacherquote liegt unter der Mindestquote.';
    }
    if (!minimumValuePassed) {
      return 'Der Quotenvorteil liegt unter dem Mindestvalue.';
    }
    return 'Mindestquote und Mindestvalue sind erfüllt.';
  }

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
