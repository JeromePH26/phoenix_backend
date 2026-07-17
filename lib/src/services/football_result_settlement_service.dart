import '../database/database.dart';
import 'football_service.dart';

class FootballResultSettlementService {
  FootballResultSettlementService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  Future<Map<String, Object?>> settle({
    required DateTime date,
  }) async {
    final matches = await football.matchesForDate(date);
    final pending = await database.pendingFootballTips(date: date);

    final matchById = <String, Map<String, Object?>>{};
    for (final raw in matches) {
      if (raw is! Map) continue;
      final match = Map<String, Object?>.from(raw);
      final fixture = _map(match['fixture']);
      final id =
          fixture['id']?.toString() ??
          match['id']?.toString() ??
          match['fixtureId']?.toString();
      if (id != null && id.isNotEmpty) {
        matchById[id] = match;
      }
    }

    var settled = 0;
    var skipped = 0;
    final results = <Map<String, Object?>>[];

    for (final tip in pending) {
      final fixtureId = tip['fixture_id']?.toString() ?? '';
      final match = matchById[fixtureId];
      if (match == null) {
        skipped++;
        continue;
      }

      final fixture = _map(match['fixture']);
      final status = _map(fixture['status']);
      final shortStatus =
          status['short']?.toString().toUpperCase() ??
          match['status']?.toString().toUpperCase() ??
          '';

      if (!_isFinished(shortStatus)) {
        skipped++;
        continue;
      }

      final goals = _map(match['goals']);
      final homeScore = _integer(
        goals['home'] ?? match['homeGoals'] ?? match['home_score'],
      );
      final awayScore = _integer(
        goals['away'] ?? match['awayGoals'] ?? match['away_score'],
      );

      final payload = _map(tip['payload']);
      final marketKey =
          tip['market_key']?.toString() ??
          payload['marketKey']?.toString() ??
          '';
      final marketLabel =
          tip['market_label']?.toString() ??
          payload['marketLabel']?.toString() ??
          '';

      final resultStatus = _grade(
        marketKey: marketKey,
        marketLabel: marketLabel,
        homeScore: homeScore,
        awayScore: awayScore,
      );

      if (resultStatus == 'unsupported') {
        skipped++;
        results.add({
          'fixtureId': fixtureId,
          'status': 'unsupported_market',
          'marketKey': marketKey,
          'marketLabel': marketLabel,
        });
        continue;
      }

      final units = _number(tip['assigned_units']) ?? 0;
      final odds =
          _number(tip['market_odds']) ??
          _number(payload['marketOdds']) ??
          0;

      final profitUnits = switch (resultStatus) {
        'won' => units > 0 && odds > 1 ? units * (odds - 1) : 0.0,
        'lost' => -units,
        _ => 0.0,
      };

      await database.settleFootballTip(
        phaseTwoScanRunId: _integer(tip['phase_two_scan_run_id']),
        fixtureId: fixtureId,
        homeScore: homeScore,
        awayScore: awayScore,
        resultStatus: resultStatus,
        profitUnits: profitUnits,
      );

      settled++;
      results.add({
        'fixtureId': fixtureId,
        'score': '$homeScore:$awayScore',
        'marketLabel': marketLabel,
        'resultStatus': resultStatus,
        'assignedUnits': units,
        'profitUnits': profitUnits,
      });
    }

    return {
      'status': 'completed',
      'date': date.toIso8601String().substring(0, 10),
      'pendingFound': pending.length,
      'settled': settled,
      'skipped': skipped,
      'results': results,
      'performance': await database.footballPerformanceSummary(),
    };
  }

  String _grade({
    required String marketKey,
    required String marketLabel,
    required int homeScore,
    required int awayScore,
  }) {
    final key = '$marketKey $marketLabel'
        .toLowerCase()
        .replaceAll(',', '.')
        .replaceAll('ü', 'u');

    final total = homeScore + awayScore;

    if (_containsAny(key, ['home_win', 'home win', 'heimsieg', '1x2_home'])) {
      return homeScore > awayScore ? 'won' : 'lost';
    }
    if (_containsAny(key, ['draw', 'unentschieden', '1x2_draw'])) {
      return homeScore == awayScore ? 'won' : 'lost';
    }
    if (_containsAny(key, ['away_win', 'away win', 'auswartssieg', '1x2_away'])) {
      return awayScore > homeScore ? 'won' : 'lost';
    }

    if (_containsAny(key, ['1x', 'home or draw', 'heim oder unentschieden'])) {
      return homeScore >= awayScore ? 'won' : 'lost';
    }
    if (_containsAny(key, ['x2', 'away or draw', 'auswarts oder unentschieden'])) {
      return awayScore >= homeScore ? 'won' : 'lost';
    }
    if (_containsAny(key, ['12', 'home or away'])) {
      return homeScore != awayScore ? 'won' : 'lost';
    }

    if (_containsAny(key, ['btts_yes', 'both teams to score yes', 'beide treffen ja'])) {
      return homeScore > 0 && awayScore > 0 ? 'won' : 'lost';
    }
    if (_containsAny(key, ['btts_no', 'both teams to score no', 'beide treffen nein'])) {
      return homeScore == 0 || awayScore == 0 ? 'won' : 'lost';
    }

    final overLine = _extractLine(key, [
      'over ',
      'over_',
      'uber ',
      'u ',
    ]);
    if (overLine != null && _containsAny(key, ['over', 'uber'])) {
      return total > overLine ? 'won' : total == overLine ? 'push' : 'lost';
    }

    final underLine = _extractLine(key, [
      'under ',
      'under_',
      'unter ',
    ]);
    if (underLine != null && _containsAny(key, ['under', 'unter'])) {
      return total < underLine ? 'won' : total == underLine ? 'push' : 'lost';
    }

    return 'unsupported';
  }

  double? _extractLine(String value, List<String> prefixes) {
    for (final prefix in prefixes) {
      final index = value.indexOf(prefix);
      if (index == -1) continue;
      final tail = value.substring(index + prefix.length);
      final match = RegExp(r'([0-9]+(?:\.[0-9]+)?)').firstMatch(tail);
      if (match != null) {
        return double.tryParse(match.group(1)!);
      }
    }
    return null;
  }

  bool _containsAny(String value, List<String> needles) =>
      needles.any(value.contains);

  bool _isFinished(String status) =>
      const {'FT', 'AET', 'PEN', 'AWD', 'WO'}.contains(status);

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  int _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
