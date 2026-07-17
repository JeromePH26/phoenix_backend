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

  Future<Map<String, Object?>> matchDetails(String fixtureId) async {
    final normalizedId = fixtureId.trim();
    if (normalizedId.isEmpty || int.tryParse(normalizedId) == null) {
      throw ArgumentError('fixtureId muss numerisch sein.');
    }

    final fixtureRows = await _getResponseList(
      '/fixtures',
      {
        'id': normalizedId,
        'timezone': 'Europe/Berlin',
      },
    );

    if (fixtureRows.isEmpty) {
      throw StateError('Spiel $normalizedId wurde nicht gefunden.');
    }

    final rawFixture = fixtureRows.first;
    final fixture = _map(rawFixture['fixture']);
    final league = _map(rawFixture['league']);
    final teams = _map(rawFixture['teams']);
    final goals = _map(rawFixture['goals']);
    final score = _map(rawFixture['score']);
    final home = _map(teams['home']);
    final away = _map(teams['away']);

    final homeTeamId = home['id']?.toString() ?? '';
    final awayTeamId = away['id']?.toString() ?? '';

    final results = await Future.wait([
      _safeSection(
        'lineups',
        () => _getResponseList(
          '/fixtures/lineups',
          {'fixture': normalizedId},
        ),
      ),
      _safeSection(
        'statistics',
        () => _getResponseList(
          '/fixtures/statistics',
          {'fixture': normalizedId},
        ),
      ),
      _safeSection(
        'players',
        () => _getResponseList(
          '/fixtures/players',
          {'fixture': normalizedId},
        ),
      ),
      _safeSection(
        'injuries',
        () => _getResponseList(
          '/injuries',
          {'fixture': normalizedId},
        ),
      ),
      _safeSection(
        'odds',
        () => _getResponseList(
          '/odds',
          {'fixture': normalizedId},
        ),
      ),
      if (homeTeamId.isNotEmpty && awayTeamId.isNotEmpty)
        _safeSection(
          'h2h',
          () => _getResponseList(
            '/fixtures/headtohead',
            {
              'h2h': '$homeTeamId-$awayTeamId',
              'last': '10',
              'timezone': 'Europe/Berlin',
            },
          ),
        )
      else
        Future.value(
          const _SectionResult(
            name: 'h2h',
            data: <Map<String, Object?>>[],
            error: 'Team-IDs fehlen.',
          ),
        ),
    ]);

    final sections = <String, Object?>{};
    final errors = <String, String>{};

    for (final result in results) {
      sections[result.name] = result.data;
      if (result.error != null) {
        errors[result.name] = result.error!;
      }
    }

    return <String, Object?>{
      'id': normalizedId,
      'fixture': <String, Object?>{
        'kickoff': fixture['date']?.toString() ?? '',
        'timestamp': fixture['timestamp'],
        'timezone': fixture['timezone']?.toString() ?? '',
        'referee': fixture['referee']?.toString() ?? '',
        'status': _map(fixture['status']),
        'venue': _map(fixture['venue']),
      },
      'league': <String, Object?>{
        'id': league['id']?.toString() ?? '',
        'name': league['name']?.toString() ?? '',
        'country': league['country']?.toString() ?? '',
        'logo': league['logo']?.toString() ?? '',
        'flag': league['flag']?.toString() ?? '',
        'season': league['season'],
        'round': league['round']?.toString() ?? '',
      },
      'teams': <String, Object?>{
        'home': _mapTeam(home),
        'away': _mapTeam(away),
      },
      'goals': goals,
      'score': score,
      ...sections,
      'dataAvailability': <String, Object?>{
        'lineups': _hasItems(sections['lineups']),
        'statistics': _hasItems(sections['statistics']),
        'players': _hasItems(sections['players']),
        'playerImages': _containsPlayerImages(sections['players']),
        'injuries': _hasItems(sections['injuries']),
        'odds': _hasItems(sections['odds']),
        'h2h': _hasItems(sections['h2h']),
      },
      if (errors.isNotEmpty) 'errors': errors,
    };
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

  Future<_SectionResult> _safeSection(
    String name,
    Future<List<Map<String, Object?>>> Function() loader,
  ) async {
    try {
      return _SectionResult(name: name, data: await loader());
    } catch (error) {
      return _SectionResult(
        name: name,
        data: const <Map<String, Object?>>[],
        error: error.toString(),
      );
    }
  }

  Map<String, Object?> _mapTeam(Map<String, dynamic> team) =>
      <String, Object?>{
        'id': team['id']?.toString() ?? '',
        'name': team['name']?.toString() ?? '',
        'logo': team['logo']?.toString() ?? '',
        'winner': team['winner'],
      };

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  bool _hasItems(Object? value) => value is List && value.isNotEmpty;

  bool _containsPlayerImages(Object? value) {
    if (value is! List) return false;

    for (final teamEntry in value.whereType<Map>()) {
      final players = teamEntry['players'];
      if (players is! List) continue;

      for (final playerEntry in players.whereType<Map>()) {
        final player = playerEntry['player'];
        if (player is Map) {
          final photo = player['photo']?.toString() ?? '';
          if (photo.isNotEmpty) return true;
        }
      }
    }

    return false;
  }

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  void close() => _client.close();
}

class _SectionResult {
  const _SectionResult({
    required this.name,
    required this.data,
    this.error,
  });

  final String name;
  final List<Map<String, Object?>> data;
  final String? error;
}
