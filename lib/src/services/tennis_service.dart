import 'dart:convert';

import 'package:http/http.dart' as http;

class TennisService {
  TennisService({
    required this.apiKey,
    required this.accessLevel,
    required this.language,
    http.Client? client,
  }) : _client = client ?? http.Client();

  static const _baseUrl = 'https://api.sportradar.com/tennis';
  final String apiKey;
  final String accessLevel;
  final String language;
  final http.Client _client;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<List<Map<String, Object?>>> matchesForDate(DateTime date) async {
    if (!isConfigured) {
      throw StateError('SPORTRADAR_TENNIS_API_KEY fehlt.');
    }
    final day = _day(date);
    final uri = Uri.parse(
      '$_baseUrl/$accessLevel/v3/$language/schedules/$day/summaries.json',
    ).replace(queryParameters: {'api_key': apiKey});
    final response = await _client.get(uri, headers: {
      'accept': 'application/json',
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Sportradar Tennis HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw StateError('Ungültige Tennis-Antwort.');
    final summaries = decoded['summaries'];
    if (summaries is! List) return const [];

    final values = <Map<String, Object?>>[];
    for (final raw in summaries.whereType<Map>()) {
      final row = Map<String, dynamic>.from(raw);
      final sportEvent = _map(row['sport_event']);
      final context = _map(sportEvent['sport_event_context']);
      final competition = _map(context['competition']);
      final season = _map(context['season']);
      final round = _map(context['round']);
      final status = _map(row['sport_event_status']);
      final competitors = _maps(sportEvent['competitors']);
      if (competitors.length < 2) continue;
      final one = competitors[0];
      final two = competitors[1];
      final type = competition['type']?.toString().toLowerCase() ?? '';
      if (type.contains('double') || type.contains('mixed')) continue;

      values.add(<String, Object?>{
        'id': sportEvent['id']?.toString() ?? '',
        'startTime': sportEvent['start_time']?.toString() ?? '',
        'status': status['status']?.toString() ?? 'scheduled',
        'tournament': competition['name']?.toString() ??
            season['name']?.toString() ??
            '',
        'tour': _tour(competition),
        'surface': season['surface']?.toString() ?? 'unknown',
        'round': round['name']?.toString() ?? round['number']?.toString() ?? '',
        'bestOf': _intValue(sportEvent['best_of']) ?? 3,
        'playerOneId': one['id']?.toString() ?? '',
        'playerOne': one['name']?.toString() ?? '',
        'playerOneCountry': one['country_code']?.toString() ?? '',
        'playerTwoId': two['id']?.toString() ?? '',
        'playerTwo': two['name']?.toString() ?? '',
        'playerTwoCountry': two['country_code']?.toString() ?? '',
        'score': _score(status),
      });
    }
    values.removeWhere((row) => (row['id'] as String).isEmpty);
    values.sort((a, b) =>
        (a['startTime'] as String).compareTo(b['startTime'] as String));
    return values;
  }

  String _tour(Map<String, dynamic> competition) {
    final text = '${competition['name'] ?? ''} ${competition['category'] ?? ''}'
        .toLowerCase();
    if (text.contains('wta')) return 'wta';
    if (text.contains('challenger')) return 'challenger';
    if (text.contains('itf')) return 'itf';
    if (text.contains('atp')) return 'atp';
    return 'other';
  }

  String? _score(Map<String, dynamic> status) {
    final home = status['home_score'];
    final away = status['away_score'];
    if (home == null || away == null) return null;
    return '$home:$away';
  }

  int? _intValue(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
      : const [];

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  void close() => _client.close();
}
