import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../database/database.dart';
import '../services/football_service.dart';
import '../services/tennis_service.dart';
import 'json_response.dart';

/// Zentrale Schutz- und Filterebene für die App-Endpunkte.
///
/// Funktionen:
/// - Fußball nur aus manuell gewhitelisteten Ligen.
/// - Kompatibler `/api/tips/today`-Endpunkt.
/// - Berliner Tagesdatum.
/// - Tennis-Jugendturniere, uninteressante Wettbewerbe und unvollständige
///   Datensätze werden vor der Ausgabe entfernt.
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

          final tennisDate = _tennisMatchDate(path);
          if (request.method == 'GET' && tennisDate != null) {
            return _tennisMatches(tennisDate);
          }

          final footballDate = _footballMatchDate(path);
          if (request.method == 'GET' && footballDate != null) {
            return _footballMatches(footballDate);
          }

          return inner(request);
        };
      };

  Future<Response> _tennisMatches(DateTime date) async {
    try {
      final rawMatches = await tennis.matchesForDate(date);
      final matches = rawMatches.where(_isInterestingTennisMatch).toList();

      return jsonResponse({
        'sport': 'tennis',
        'date': _day(date),
        'filtered': true,
        'rawCount': rawMatches.length,
        'count': matches.length,
        'excludedCount': rawMatches.length - matches.length,
        'matches': matches,
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 502);
    }
  }

  /// Tennis-Mindeststandard:
  /// Ein Match wird nur ausgegeben, wenn Wettbewerb, Startzeit, beide Spieler
  /// und eindeutige Spieler-/Match-IDs vorhanden sind.
  bool _hasMinimumTennisData(Map<String, Object?> match) {
    final id = _text(match['id']);
    final startTime = _text(match['startTime']);
    final tournament = _text(match['tournament']);
    final playerOne = _text(match['playerOne']);
    final playerTwo = _text(match['playerTwo']);
    final playerOneId = _text(match['playerOneId']);
    final playerTwoId = _text(match['playerTwoId']);

    if (id.isEmpty ||
        tournament.isEmpty ||
        playerOne.isEmpty ||
        playerTwo.isEmpty ||
        playerOneId.isEmpty ||
        playerTwoId.isEmpty) {
      return false;
    }

    final parsedStart = DateTime.tryParse(startTime);
    if (parsedStart == null) return false;

    return true;
  }

  bool _isInterestingTennisMatch(Map<String, Object?> match) {
    if (!_hasMinimumTennisData(match)) return false;

    final searchable = [
      _text(match['tournament']),
      _text(match['tour']),
      _text(match['competitionType']),
      _text(match['round']),
      _text(match['gender']),
    ].join(' ').toLowerCase();

    if (_isYouthTennis(searchable)) return false;
    if (_containsBlacklistedTennisToken(searchable)) return false;

    // Optionaler Tour-Filter:
    // Beispiel Railway:
    // TENNIS_ALLOWED_TOURS=atp,wta,challenger
    final allowedTours = _csvEnvironment('TENNIS_ALLOWED_TOURS');
    if (allowedTours.isNotEmpty) {
      final tour = _text(match['tour']).toLowerCase();
      if (!allowedTours.contains(tour)) return false;
    }

    return true;
  }

  bool _isYouthTennis(String value) {
    final patterns = <RegExp>[
      RegExp(r'\bu[\s-]?(?:10|11|12|13|14|15|16|17|18|19|20|21|23)\b'),
      RegExp(r'\bunder[\s-]?(?:10|11|12|13|14|15|16|17|18|19|20|21|23)\b'),
      RegExp(r'\bjuniors?\b'),
      RegExp(r'\byouth\b'),
      RegExp(r'\bjunioren\b'),
      RegExp(r'\bnachwuchs\b'),
      RegExp(r'\bboys?\b'),
      RegExp(r'\bgirls?\b'),
      RegExp(r'\bteens?\b'),
    ];

    return patterns.any((pattern) => pattern.hasMatch(value));
  }

  bool _containsBlacklistedTennisToken(String value) {
    const defaults = <String>{
      'exhibition',
      'exhibition matches',
      'legends',
      'senior tour',
      'virtual tennis',
      'esports',
      'e-tennis',
      'fantasy',
      'battle of',
      'national league',
      'club league',
      'university',
      'college',
      'amateur',
    };

    final configured = _csvEnvironment('TENNIS_TOURNAMENT_BLACKLIST');
    final blacklist = <String>{...defaults, ...configured};

    return blacklist.any(
      (token) => token.isNotEmpty && value.contains(token.toLowerCase()),
    );
  }

  Set<String> _csvEnvironment(String key) {
    final raw = Platform.environment[key]?.trim() ?? '';
    if (raw.isEmpty) return const <String>{};

    return raw
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  Future<Response> _footballMatches(DateTime date) async {
    // Die App liest den Spielplan primär aus dem eigenen, beim Tages-Scan
    // angelegten Cache. Das verhindert, dass API-Limits plötzlich Spiele aus
    // der Übersicht entfernen oder für alle Nutzer eine neue Provider-Abfrage
    // auslösen.
    final cached = await database.cachedWhitelistedFootballMatchesForDate(date);
    if (cached.isNotEmpty) {
      return jsonResponse({
        'sport': 'football',
        'date': _day(date),
        'whitelistOnly': true,
        'source': 'database_cache',
        'count': cached.length,
        'matches': cached,
      });
    }

    try {
      final matches = await football.matchesForDate(date);
      final allowed = await _onlyWhitelisted(matches);

      for (final match in allowed) {
        final fixtureId = _text(match['id']);
        if (fixtureId.isEmpty) continue;
        await database.upsertFootballMatchFromPayload(
          fixtureId: fixtureId,
          payload: match,
        );
      }

      return jsonResponse({
        'sport': 'football',
        'date': _day(date),
        'whitelistOnly': true,
        'count': allowed.length,
        'matches': allowed,
      });
    } catch (error) {
      // Ein leerer Cache ist nur beim allerersten Aufruf möglich. Danach
      // bleibt der gespeicherte Spielplan auch bei Provider-Ausfällen stabil.
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

      // Eine Tennis-Tipp-Pipeline ist serverseitig noch nicht vollständig
      // vorhanden. Deshalb wird eine echte leere Liste statt null geliefert.
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
      return const <Map<String, Object?>>[];
    }

    final leagueIds = matches
        .map((match) => _text(match['leagueId']))
        .where((id) => id.isNotEmpty)
        .toSet();

    // Eine einzige Abfrage für alle Ligen dieser Antwort statt einer
    // sequenziellen DB-Anfrage pro Spiel (manual_status hängt nicht von der
    // Saison ab, daher genügt league_id als Schlüssel).
    final statuses = await database.footballLeagueManualStatuses(leagueIds);

    return matches.where((match) {
      final leagueId = _text(match['leagueId']);
      final season = _integer(match['season']);
      if (leagueId.isEmpty || season == null || season <= 0) return false;

      final manualStatus = statuses[leagueId]?.trim().toLowerCase() ?? '';
      return manualStatus == 'whitelist';
    }).toList();
  }

  DateTime? _tennisMatchDate(String path) {
    if (path == 'api/tennis/matches/today') return _berlinNow();

    const prefix = 'api/tennis/matches/';
    if (!path.startsWith(prefix)) return null;

    final value = path.substring(prefix.length);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
    return DateTime.tryParse(value);
  }

  DateTime? _footballMatchDate(String path) {
    if (path == 'api/football/matches/today') return _berlinNow();

    const prefix = 'api/football/matches/';
    if (!path.startsWith(prefix)) return null;

    final value = path.substring(prefix.length);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
    return DateTime.tryParse(value);
  }

  String _text(Object? value) => value?.toString().trim() ?? '';

  int? _integer(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  DateTime _berlinNow() {
    final utc = DateTime.now().toUtc();
    final year = utc.year;
    final dstStart = _lastSundayUtc(year, 3, 1);
    final dstEnd = _lastSundayUtc(year, 10, 1);
    final isSummerTime = !utc.isBefore(dstStart) && utc.isBefore(dstEnd);
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
