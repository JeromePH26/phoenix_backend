import 'dart:convert';

import 'package:http/http.dart' as http;

class BaseballService {
  BaseballService({required this.apiKey, http.Client? client})
      : _client = client ?? http.Client();

  static const _baseUrl = 'https://v1.baseball.api-sports.io';
  static const _dailySafetyLimit = 90;

  final String apiKey;
  final http.Client _client;
  final Map<String, _BaseballCacheEntry> _cache = {};
  DateTime? _quotaDay;
  int _requestsToday = 0;

  bool get isConfigured => apiKey.trim().isNotEmpty;
  int get requestsToday => _requestsToday;

  Future<Map<String, dynamic>> mlbGames(String date) async {
    final cached = _cache[date];
    final now = DateTime.now().toUtc();
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return cached.payload;
    }
    if (!isConfigured) throw StateError('API_BASEBALL_KEY fehlt.');
    _resetQuotaIfNeeded(now);
    if (_requestsToday >= _dailySafetyLimit) {
      throw StateError(
          'Baseball-Tageslimit zum Schutz des Free-Tarifs erreicht.');
    }

    final uri = Uri.parse('$_baseUrl/games').replace(
      queryParameters: {'date': date},
    );
    _requestsToday++;
    final response = await _client.get(uri, headers: {
      'x-apisports-key': apiKey
    }).timeout(const Duration(seconds: 30));
    final decoded = jsonDecode(response.body);
    if (response.statusCode != 200 || decoded is! Map) {
      throw StateError(
          'Baseball-Anbieter antwortet mit ${response.statusCode}.');
    }
    final envelope = Map<String, dynamic>.from(decoded);
    final errors = envelope['errors'];
    if (errors is Map && errors.isNotEmpty) {
      throw StateError(errors.values.join(', '));
    }
    final rows = envelope['response'] is List
        ? (envelope['response'] as List)
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .where((row) {
            final league = row['league'];
            if (league is! Map) return false;
            return league['name']?.toString().trim().toUpperCase() == 'MLB';
          }).toList(growable: false)
        : const <Map<String, dynamic>>[];
    final payload = <String, dynamic>{
      'date': date,
      'league': 'MLB',
      'response': rows,
      'requestsUsedToday': _requestsToday,
      'dailySafetyLimit': _dailySafetyLimit,
    };
    final local = DateTime.now();
    final requested = DateTime.tryParse(date);
    final today = requested != null &&
        requested.year == local.year &&
        requested.month == local.month &&
        requested.day == local.day;
    _cache[date] = _BaseballCacheEntry(
      payload: payload,
      expiresAt: now
          .add(today ? const Duration(minutes: 30) : const Duration(hours: 12)),
    );
    return payload;
  }

  void _resetQuotaIfNeeded(DateTime now) {
    final day = DateTime.utc(now.year, now.month, now.day);
    if (_quotaDay != day) {
      _quotaDay = day;
      _requestsToday = 0;
    }
  }

  void close() => _client.close();
}

class _BaseballCacheEntry {
  const _BaseballCacheEntry({required this.payload, required this.expiresAt});
  final Map<String, dynamic> payload;
  final DateTime expiresAt;
}
