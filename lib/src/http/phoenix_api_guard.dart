import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../database/database.dart';
import '../services/football_service.dart';
import '../services/tennis_service.dart';
import 'json_response.dart';

/// Ergänzt die bestehenden API-Routen um:
/// - einen kompatiblen `/api/tips/today`-Endpunkt,
/// - eine strikte Fußball-Liga-Whitelist,
/// - ein korrektes Berliner Datum für den Tennis-Spielplan.
///
/// Die normale Routenklasse kann dadurch unverändert bleiben.
class PhoenixApiGuard {
  PhoenixApiGuard({
    required this.database,
    required this.football,
    required this.tennis,
  });

  final PhoenixDatabase database;
  final FootballService football;
  final TennisService tennis;

  Middleware get middleware => (Handler inner) {
        return (Request request) async {
          final path = request.url.path;

          if (request.method == 'GET' && path == 'api/tips/today') {
            return _tipsToday(request, inner);
          }

          if (request.method == 'GET' &&
              path == 'api/tennis/matches/today') {
            return _tennisToday();
          }

          final footballDate = _footballMatchDate(path);
          if (request.method == 'GET' && footballDate != null) {
            return _footballMatches(footballDate);
          }

          return inner(request);
        };
      };

  Future<Response> _tennisToday() async {
    try {
      final date = _berlinNow();
      final matches = await tennis.matchesForDate(date);
      return jsonResponse({
        'sport': 'tennis',
        'date': _day(date),
        'count': matches.length,
        'matches': matches,
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 502);
    }
  }

  Future<Response> _footballMatches(DateTime date) async {
    try {
      final matches = await football.matchesForDate(date);
      final allowed = await _onlyWhitelisted(matches);

      return jsonResponse({
        'sport': 'football',
        'date': _day(date),
        'whitelistOnly': true,
        'count': allowed.length,
        'matches': allowed,
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 502);
    }
  }

  Future<Response> _tipsToday(Request original, Handler inner) async {
    try {
      final date = _berlinNow();
      final analysisUri = original.requestedUri.replace(
        path: '/api/football/analyses/today',
        queryParameters: const {'minimumQuality': '0'},
      );

      final analysisRequest = Request(
        'GET',
        analysisUri,
        headers: original.headers,
        context: original.context,
      );

      final response = await inner(analysisRequest);
      final body = await response.readAsString();

      List<Map<String, Object?>> footballTips = const [];

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['matches'] is List) {
          final rows = (decoded['matches'] as List)
              .whereType<Map>()
              .map((row) => Map<String, Object?>.from(row))
              .toList();

          footballTips = await _onlyWhitelisted(rows);
        }
      }

      // Für Tennis existiert im Backend derzeit noch keine vollständige
      // Analyse-Pipeline. Deshalb wird eine echte leere Liste statt null
      // geliefert. So kann die App sauber rendern, ohne falsche Tipps zu erfinden.
      const tennisTips = <Map<String, Object?>>[];

      return jsonResponse({
        'date': _day(date),
        'football': footballTips,
        'tennis': tennisTips,
        'tips': <Map<String, Object?>>[
          ...footballTips.map(
            (tip) => <String, Object?>{'sport': 'football', ...tip},
          ),
        ],
        'count': footballTips.length + tennisTips.length,
        'footballCount': footballTips.length,
        'tennisCount': tennisTips.length,
        'whitelistOnly': true,
        'status': footballTips.isEmpty
            ? 'Keine freigegebenen analysierten Tipps vorhanden.'
            : 'Serverseitige Tipps geladen.',
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<List<Map<String, Object?>>> _onlyWhitelisted(
    List<Map<String, Object?>> matches,
  ) async {
    if (!database.isConfigured) {
      // Ohne Datenbank gibt es keine verlässliche Whitelist.
      return const <Map<String, Object?>>[];
    }

    final allowed = <Map<String, Object?>>[];

    for (final match in matches) {
      final leagueId = match['leagueId']?.toString().trim() ?? '';
      final season = _integer(match['season']);

      if (leagueId.isEmpty || season == null || season <= 0) {
        continue;
      }

      final profile = await database.leagueProfile(leagueId, season);
      final manualStatus =
          profile?['manual_status']?.toString().trim().toLowerCase() ?? '';

      if (manualStatus == 'whitelist') {
        allowed.add(match);
      }
    }

    return allowed;
  }

  DateTime? _footballMatchDate(String path) {
    if (path == 'api/football/matches/today') {
      return _berlinNow();
    }

    const prefix = 'api/football/matches/';
    if (!path.startsWith(prefix)) return null;

    final value = path.substring(prefix.length);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
    return DateTime.tryParse(value);
  }

  int? _integer(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  DateTime _berlinNow() {
    final utc = DateTime.now().toUtc();
    final year = utc.year;
    final dstStart = _lastSundayUtc(year, 3, 1);
    final dstEnd = _lastSundayUtc(year, 10, 1);
    final isSummerTime =
        !utc.isBefore(dstStart) && utc.isBefore(dstEnd);

    return utc.add(Duration(hours: isSummerTime ? 2 : 1));
  }

  DateTime _lastSundayUtc(int year, int month, int hour) {
    final lastDay = DateTime.utc(year, month + 1, 0, hour);
    final daysBack = lastDay.weekday % 7;
    return lastDay.subtract(Duration(days: daysBack));
  }

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
