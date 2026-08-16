import 'dart:math';

import '../database/database.dart';

/// Creates one reproducible 2-leg combo for a scan date. It never combines
/// markets from the same fixture and caps the total quote at 2.20.
class FootballDailyComboService {
  const FootballDailyComboService({required this.database});

  final PhoenixDatabase database;

  Future<Map<String, Object?>?> buildAndSave({
    required DateTime date,
    required Iterable<Map<String, Object?>> analyses,
  }) async {
    final candidates = <_ComboCandidate>[];
    const eligibleMarketKeys = <String>{
      'homeWin',
      'draw',
      'awayWin',
      'over25',
      'under25',
      'bttsYes',
      'bttsNo',
      'homeOver15',
      'awayOver15',
    };
    for (final analysis in analyses) {
      final selection = _map(analysis['selection']);
      final matchId = _string(analysis['fixtureId']);
      if (matchId.isEmpty) continue;
      // Published analyses keep market quotes at the payload root. Older scan
      // payloads may still nest them below selection, so retain that fallback.
      final oddsByKey = {
        ..._map(selection['marketOddsByKey']),
        ..._map(analysis['marketOddsByKey']),
      };
      final confidence = _number(analysis['confidence'])?.round() ?? 0;
      final match =
          '${_string(analysis['homeTeam'])} – ${_string(analysis['awayTeam'])}';
      for (final raw in _list(selection['allMarkets'])) {
        final market = _map(raw);
        final key = _string(market['key']);
        final probability = _number(market['probability']) ?? 0;
        final fairOdds = _number(market['fairOdds']) ?? 0;
        final bookmakerOdds = _number(oddsByKey[key]) ?? 0;
        final usesModelOdds = bookmakerOdds <= 1;
        final odds = usesModelOdds ? fairOdds : bookmakerOdds;
        if (key.isEmpty ||
            !eligibleMarketKeys.contains(key) ||
            odds < 1.20 ||
            odds > 1.85 ||
            probability < .68 ||
            probability > .86 ||
            confidence < 60) {
          continue;
        }
        candidates.add(
          _ComboCandidate(
            fixtureId: matchId,
            match: match,
            marketKey: key,
            market: _string(market['label']),
            odds: odds,
            probability: probability,
            confidence: confidence,
            usesModelOdds: usesModelOdds,
          ),
        );
      }
    }

    _ComboCandidate? first;
    _ComboCandidate? second;
    var bestScore = double.infinity;
    for (var left = 0; left < candidates.length; left++) {
      for (var right = left + 1; right < candidates.length; right++) {
        final a = candidates[left];
        final b = candidates[right];
        if (a.fixtureId == b.fixtureId) continue;
        final odds = a.odds * b.odds;
        if (odds < 1.65 || odds > 2.20) continue;
        final averageConfidence = (a.confidence + b.confidence) / 2;
        final score = (log(odds / 2.0)).abs() +
            (100 - averageConfidence) / 1000 +
            (a.usesModelOdds || b.usesModelOdds ? .015 : 0);
        if (score < bestScore) {
          bestScore = score;
          first = a;
          second = b;
        }
      }
    }
    if (first == null || second == null) return null;

    final legs = [first, second];
    final combinedOdds = first.odds * second.odds;
    final combinedProbability = first.probability * second.probability;
    final usesModelOdds = legs.any((leg) => leg.usesModelOdds);
    final payload = <String, Object?>{
      'type': 'daily_combo',
      'date': date.toUtc().toIso8601String().substring(0, 10),
      'targetOdds': 2.0,
      'combinedOdds': _round(combinedOdds),
      'combinedProbability': _round(combinedProbability),
      'usesModelOdds': usesModelOdds,
      'legs': [for (final leg in legs) leg.toJson()],
    };
    await database.saveFootballDailyCombo(
      date: date,
      combinedOdds: combinedOdds,
      combinedProbability: combinedProbability,
      usesModelOdds: usesModelOdds,
      payload: payload,
    );
    return payload;
  }

  List<Object?> _list(Object? value) => value is List ? value : const [];
  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};
  String _string(Object? value) => value?.toString().trim() ?? '';
  double? _number(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  double _round(double value) => double.parse(value.toStringAsFixed(4));
}

class _ComboCandidate {
  const _ComboCandidate({
    required this.fixtureId,
    required this.match,
    required this.marketKey,
    required this.market,
    required this.odds,
    required this.probability,
    required this.confidence,
    required this.usesModelOdds,
  });

  final String fixtureId, match, marketKey, market;
  final double odds, probability;
  final int confidence;
  final bool usesModelOdds;

  Map<String, Object?> toJson() => {
        'fixtureId': fixtureId,
        'match': match,
        'marketKey': marketKey,
        'market': market,
        'odds': odds,
        'probability': probability,
        'confidence': confidence,
        'usesModelOdds': usesModelOdds,
      };
}
