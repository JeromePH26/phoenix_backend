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
    if (!isConfigured) throw StateError('API_FOOTBALL_KEY fehlt.');
    final day = _day(date);
    final uri = Uri.parse('$_baseUrl/fixtures').replace(queryParameters: {
      'date': day,
      'timezone': 'Europe/Berlin',
    });
    final response = await _client.get(uri, headers: {
      'x-apisports-key': apiKey,
      'accept': 'application/json',
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Football API HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw StateError('Ungültige Football-Antwort.');
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

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  void close() => _client.close();
}
