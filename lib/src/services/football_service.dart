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
    final rows = await _getResponseList(
      '/fixtures',
      {
        'date': _day(date),
        'timezone': 'Europe/Berlin',
      },
    );

    return rows
        .map(_mapFixtureSummary)
        .where((row) => (row['id'] as String).isNotEmpty)
        .toList();
  }

  Map<String, Object?> _mapFixtureSummary(Map<String, Object?> raw) {
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
      'season': league['season'],
      'round': league['round']?.toString() ?? '',
      'homeTeamId': home['id']?.toString() ?? '',
      'homeTeam': home['name']?.toString() ?? '',
      'homeLogo': home['logo']?.toString() ?? '',
      'awayTeamId': away['id']?.toString() ?? '',
      'awayTeam': away['name']?.toString() ?? '',
      'awayLogo': away['logo']?.toString() ?? '',
      'homeGoals': goals['home'],
      'awayGoals': goals['away'],
    };
  }


  Future<Map<String, Object?>> coverageForFixture({
    required String fixtureId,
    required String leagueId,
    required int season,
    required String homeTeamId,
    required String awayTeamId,
    Duration pauseBetweenCalls = const Duration(seconds: 7),
  }) async {
    final result = <String, Object?>{};

    Future<void> check(
      String key,
      String path,
      Map<String, String> query,
    ) async {
      try {
        final rows = await _getResponseList(path, query);
        result[key] = rows.isNotEmpty;
        result['${key}Count'] = rows.length;
      } catch (error) {
        result[key] = false;
        result['${key}Error'] = error.toString();
      }
      await Future<void>.delayed(pauseBetweenCalls);
    }

    await check('standings', '/standings', {
      'league': leagueId,
      'season': season.toString(),
    });
    await check('homeRecent', '/fixtures', {
      'team': homeTeamId,
      'season': season.toString(),
      'last': '5',
    });
    await check('awayRecent', '/fixtures', {
      'team': awayTeamId,
      'season': season.toString(),
      'last': '5',
    });
    await check('injuries', '/injuries', {'fixture': fixtureId});
    await check('odds', '/odds', {'fixture': fixtureId});
    await check('h2h', '/fixtures/headtohead', {
      'h2h': '$homeTeamId-$awayTeamId',
      'last': '5',
    });
    await check('lineups', '/fixtures/lineups', {'fixture': fixtureId});

    return result;
  }

  Future<List<Map<String, Object?>>> _getResponseList(
    String path,
    Map<String, String> queryParameters,
  ) async {
    if (!isConfigured) {
      throw StateError('API_FOOTBALL_KEY fehlt.');
    }

    final uri = Uri.parse('$_baseUrl$path').replace(
      queryParameters: queryParameters,
    );

    final response = await _client.get(
      uri,
      headers: {
        'x-apisports-key': apiKey,
        'accept': 'application/json',
      },
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Football API HTTP ${response.statusCode} bei $path.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw StateError('Ungültige Football-Antwort bei $path.');
    }

    final apiErrors = decoded['errors'];
    if (apiErrors is Map && apiErrors.isNotEmpty) {
      throw StateError('Football API Fehler bei $path: $apiErrors');
    }

    final rows = decoded['response'];
    if (rows is! List) return const <Map<String, Object?>>[];

    return rows
        .whereType<Map>()
        .map((raw) => Map<String, Object?>.from(raw))
        .toList();
  }

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  void close() => _client.close();
}
