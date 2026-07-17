import 'dart:convert';

import 'package:http/http.dart' as http;

class FootballService {
  FootballService({required this.apiKey, http.Client? client})
      : _client = client ?? http.Client();

  static const _baseUrl = 'https://v3.football.api-sports.io';
  final String apiKey;
  final http.Client _client;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<List<Map<String, Object?>>> matchesForDate(DateTime date) async {
    final day = _day(date);
    final decoded = await _get('/fixtures', {
      'date': day,
      'timezone': 'Europe/Berlin',
    });
    final rows = decoded['response'];
    if (rows is! List) return const [];
    return rows.whereType<Map>().map((raw) {
      final row = Map<String, dynamic>.from(raw);
      final fixture = _map(row['fixture']);
      final league = _map(row['league']);
      final teams = _map(row['teams']);
      final goals = _map(row['goals']);
      final home = _map(teams['home']);
      final away = _map(teams['away']);
      final status = _map(fixture['status']);
      return <String, Object?>{
        'id': fixture['id']?.toString() ?? '',
        'kickoff': fixture['date']?.toString() ?? '',
        'status': status['short']?.toString() ?? 'NS',
        'leagueId': league['id']?.toString() ?? '',
        'league': league['name']?.toString() ?? '',
        'country': league['country']?.toString() ?? '',
        'leagueLogo': league['logo']?.toString() ?? '',
        'homeTeamId': home['id']?.toString() ?? '',
        'homeTeam': home['name']?.toString() ?? '',
        'homeLogo': home['logo']?.toString() ?? '',
        'awayTeamId': away['id']?.toString() ?? '',
        'awayTeam': away['name']?.toString() ?? '',
        'awayLogo': away['logo']?.toString() ?? '',
        'homeGoals': goals['home'],
        'awayGoals': goals['away'],
      };
    }).where((row) => (row['id'] as String).isNotEmpty).toList();
  }

  Future<Map<String, Object?>> liveSnapshot(String fixtureId) async {
    final normalized = fixtureId.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('fixtureId fehlt.');
    }

    final responses = await Future.wait([
      _get('/fixtures', {'id': normalized}),
      _get('/fixtures/events', {'fixture': normalized}),
      _get('/fixtures/statistics', {'fixture': normalized}),
    ]);

    final fixtureRows = _responseRows(responses[0]);
    if (fixtureRows.isEmpty) {
      throw StateError('Spiel wurde beim Datenanbieter nicht gefunden.');
    }

    final rawFixture = _map(fixtureRows.first);
    final fixture = _map(rawFixture['fixture']);
    final status = _map(fixture['status']);
    final league = _map(rawFixture['league']);
    final teams = _map(rawFixture['teams']);
    final home = _map(teams['home']);
    final away = _map(teams['away']);
    final goals = _map(rawFixture['goals']);

    final events = <Map<String, Object?>>[];
    for (final rawValue in _responseRows(responses[1])) {
      final raw = _map(rawValue);
      final time = _map(raw['time']);
      final team = _map(raw['team']);
      final player = _map(raw['player']);
      final assist = _map(raw['assist']);
      final type = raw['type']?.toString() ?? '';
      final detail = raw['detail']?.toString() ?? '';
      final comments = raw['comments']?.toString() ?? '';
      final minute = _integer(time['elapsed']) ?? 0;
      final extra = _integer(time['extra']) ?? 0;
      final teamId = team['id']?.toString() ?? '';
      final playerName = player['name']?.toString() ?? '';
      final assistName = assist['name']?.toString() ?? '';

      final eventType = _liveEventType(type, detail);
      events.add({
        'id': [
          minute,
          extra,
          teamId,
          type,
          detail,
          playerName,
        ].join('|'),
        'minute': minute,
        'extraMinute': extra,
        'type': eventType,
        'side': teamId == home['id']?.toString()
            ? 'home'
            : teamId == away['id']?.toString()
                ? 'away'
                : 'neutral',
        'title': _liveEventTitle(eventType, detail),
        'detail': comments.isNotEmpty
            ? comments
            : _liveEventDetail(
                eventType: eventType,
                detail: detail,
                player: playerName,
                assist: assistName,
              ),
        'player': playerName,
        'assist': assistName,
        'derived': false,
      });
    }

    events.sort((a, b) {
      final minute = (b['minute'] as int).compareTo(a['minute'] as int);
      if (minute != 0) return minute;
      return (b['extraMinute'] as int)
          .compareTo(a['extraMinute'] as int);
    });

    final statRows = _responseRows(responses[2]).map(_map).toList();

    Map<String, Object?> parseStats(String teamId) {
      Map<String, dynamic>? selected;
      for (final row in statRows) {
        final team = _map(row['team']);
        if (team['id']?.toString() == teamId) {
          selected = row;
          break;
        }
      }

      if (selected == null) return const <String, Object?>{};

      final values = <String, Object?>{};
      final statistics = selected['statistics'];
      if (statistics is List) {
        for (final rawValue in statistics) {
          final raw = _map(rawValue);
          final key = raw['type']
                  ?.toString()
                  .toLowerCase()
                  .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
                  .trim() ??
              '';
          values[key] = raw['value'];
        }
      }

      return {
        'possession': _decimal(values['ball possession']),
        'totalShots': _integer(values['total shots']),
        'shotsOnGoal': _integer(values['shots on goal']),
        'corners': _integer(values['corner kicks']),
        'yellowCards': _integer(values['yellow cards']),
        'redCards': _integer(values['red cards']),
        'dangerousAttacks': _integer(values['dangerous attacks']),
      };
    }

    return {
      'fixtureId': normalized,
      'league': league['name']?.toString() ?? '',
      'statusShort': status['short']?.toString() ?? '',
      'statusLong': status['long']?.toString() ?? '',
      'elapsed': _integer(status['elapsed']) ?? 0,
      'extra': _integer(status['extra']) ?? 0,
      'homeGoals': _integer(goals['home']) ?? 0,
      'awayGoals': _integer(goals['away']) ?? 0,
      'homeTeam': {
        'id': home['id']?.toString() ?? '',
        'name': home['name']?.toString() ?? '',
        'logo': home['logo']?.toString() ?? '',
      },
      'awayTeam': {
        'id': away['id']?.toString() ?? '',
        'name': away['name']?.toString() ?? '',
        'logo': away['logo']?.toString() ?? '',
      },
      'homeStats': parseStats(home['id']?.toString() ?? ''),
      'awayStats': parseStats(away['id']?.toString() ?? ''),
      'events': events,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'cacheSeconds': 15,
    };
  }

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async {
    if (!isConfigured) throw StateError('API_FOOTBALL_KEY fehlt.');

    final uri = Uri.parse('$_baseUrl$path').replace(
      queryParameters: query,
    );
    final response = await _client.get(uri, headers: {
      'x-apisports-key': apiKey,
      'accept': 'application/json',
    });

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Football API HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw StateError('Ungültige Football-Antwort.');
    }

    return Map<String, dynamic>.from(decoded);
  }

  List<dynamic> _responseRows(Map<String, dynamic> decoded) {
    final response = decoded['response'];
    return response is List ? response : const <dynamic>[];
  }

  String _liveEventType(String type, String detail) {
    final normalized = '$type $detail'.toLowerCase();
    if (normalized.contains('goal')) return 'goal';
    if (normalized.contains('yellow')) return 'yellowCard';
    if (normalized.contains('red')) return 'redCard';
    if (normalized.contains('subst')) return 'substitution';
    if (normalized.contains('var')) return 'varReview';
    return 'other';
  }

  String _liveEventTitle(String eventType, String detail) {
    return switch (eventType) {
      'goal' => 'TOR',
      'yellowCard' => 'Gelbe Karte',
      'redCard' => 'Rote Karte',
      'substitution' => 'Wechsel',
      'varReview' => 'VAR',
      _ => detail.trim().isEmpty ? 'Spielereignis' : detail,
    };
  }

  String _liveEventDetail({
    required String eventType,
    required String detail,
    required String player,
    required String assist,
  }) {
    if (eventType == 'goal') {
      if (player.isEmpty) return detail;
      if (assist.isEmpty) return player;
      return '$player · Assist: $assist';
    }
    if (player.isNotEmpty) return player;
    return detail;
  }

  int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    final normalized = value
        ?.toString()
        .replaceAll('%', '')
        .replaceAll(',', '.')
        .trim();
    return int.tryParse(normalized ?? '') ??
        double.tryParse(normalized ?? '')?.round();
  }

  double? _decimal(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(
      value
              ?.toString()
              .replaceAll('%', '')
              .replaceAll(',', '.')
              .trim() ??
          '',
    );
  }

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  void close() => _client.close();
}
