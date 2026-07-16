import 'dart:convert';

import 'package:http/http.dart' as http;

class PhoenixServerApi {
  PhoenixServerApi({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  Future<Map<String, dynamic>> health() => _get('/health');

  Future<List<Map<String, dynamic>>> footballMatchesToday() async {
    final body = await _get('/api/football/matches/today');
    return _mapList(body['matches']);
  }

  Future<List<Map<String, dynamic>>> tennisMatchesToday() async {
    final body = await _get('/api/tennis/matches/today');
    return _mapList(body['matches']);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await _client.get(Uri.parse('$baseUrl$path'));
    final decoded = jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map ? decoded['error'] : null;
      throw StateError(message?.toString() ?? 'Serverfehler ${response.statusCode}');
    }
    if (decoded is! Map) throw StateError('Ungültige Serverantwort.');
    return Map<String, dynamic>.from(decoded);
  }

  List<Map<String, dynamic>> _mapList(Object? value) => value is List
      ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
      : const [];

  void close() => _client.close();
}
