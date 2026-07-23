import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class _TennisCacheEntry {
  const _TennisCacheEntry({required this.payload, required this.expiresAt});

  final Map<String, dynamic> payload;
  final DateTime expiresAt;
}

class _ProviderHttpResponse {
  const _ProviderHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

class TennisService {
  TennisService({
    required this.apiKey,
    required this.accessLevel,
    required this.language,
    http.Client? client,
    this.minimumRequestInterval = const Duration(milliseconds: 1100),
  }) : _client = client ?? http.Client(),
       _useSystemCurl = client == null;

  static const String _baseUrl = 'https://api.sportradar.com/tennis';

  final String apiKey;
  final String accessLevel;
  final String language;
  final Duration minimumRequestInterval;
  final http.Client _client;
  final bool _useSystemCurl;

  final Map<String, _TennisCacheEntry> _cache = <String, _TennisCacheEntry>{};
  final Map<String, Future<Map<String, dynamic>>> _flights =
      <String, Future<Map<String, dynamic>>>{};

  Future<void> _requestQueue = Future<void>.value();
  DateTime? _lastRequestAt;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// Liefert den vollständigen Tennis-Spielplan. Eine Matchliste wird nicht
  /// nach Datenqualität, Engine-Freigabe oder Tipp gefiltert. Auch Doppel und
  /// Mixed können deshalb in der normalen Spielübersicht erscheinen.
  Future<List<Map<String, Object?>>> matchesForDate(DateTime date) async {
    final day = _day(date);
    final decoded = await providerRequest(
      path: '/schedules/$day/summaries.json',
    );
    final summaries = decoded['summaries'];
    if (summaries is! List) return const <Map<String, Object?>>[];

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

      var one = competitors.first;
      var two = competitors[1];
      for (final competitor in competitors) {
        final qualifier = competitor['qualifier']?.toString().toLowerCase();
        if (qualifier == 'home') one = competitor;
        if (qualifier == 'away') two = competitor;
      }

      values.add(<String, Object?>{
        'id': sportEvent['id']?.toString() ?? '',
        'startTime': sportEvent['start_time']?.toString() ?? '',
        'status': status['status']?.toString() ?? 'scheduled',
        'tournament':
            competition['name']?.toString() ?? season['name']?.toString() ?? '',
        'tour': _tour(competition),
        'surface': season['surface']?.toString() ?? 'unknown',
        'round': round['name']?.toString() ?? round['number']?.toString() ?? '',
        'bestOf':
            _intValue(sportEvent['best_of']) ??
            _intValue(context['best_of']) ??
            3,
        'competitionType': competition['type']?.toString() ?? '',
        'gender': competition['gender']?.toString() ?? '',
        'playerOneId': one['id']?.toString() ?? '',
        'playerOne': one['name']?.toString() ?? '',
        'playerOneCountry': one['country_code']?.toString() ?? '',
        'playerTwoId': two['id']?.toString() ?? '',
        'playerTwo': two['name']?.toString() ?? '',
        'playerTwoCountry': two['country_code']?.toString() ?? '',
        'score': _score(status),
      });
    }

    values.removeWhere((row) => (row['id']?.toString() ?? '').isEmpty);
    values.sort(
      (a, b) => (a['startTime']?.toString() ?? '').compareTo(
        b['startTime']?.toString() ?? '',
      ),
    );
    return values;
  }

  /// Zentraler, begrenzter Sportradar-Zugriff für die Flutter-App.
  /// Der geheime API-Key verlässt Railway niemals.
  Future<Map<String, dynamic>> providerRequest({required String path}) {
    if (!isConfigured) {
      throw StateError('SPORTRADAR_TENNIS_API_KEY fehlt.');
    }

    final normalizedPath = _normalizeProviderPath(path);
    _assertAllowedProviderPath(normalizedPath);

    final cacheKey = '$accessLevel|$language|$normalizedPath';
    final now = DateTime.now();
    final cached = _cache[cacheKey];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return Future<Map<String, dynamic>>.value(cached.payload);
    }

    final running = _flights[cacheKey];
    if (running != null) return running;

    late final Future<Map<String, dynamic>> tracked;
    tracked = _queuedProviderGet(normalizedPath)
        .then((payload) {
          _cache[cacheKey] = _TennisCacheEntry(
            payload: payload,
            expiresAt: DateTime.now().add(_cacheDuration(normalizedPath)),
          );
          _removeExpiredCacheEntries();
          return payload;
        })
        .whenComplete(() {
          if (identical(_flights[cacheKey], tracked)) {
            _flights.remove(cacheKey);
          }
        });

    _flights[cacheKey] = tracked;
    return tracked;
  }

  String _normalizeProviderPath(String rawPath) {
    var value = rawPath.trim();
    try {
      // Abwärtskompatibel mit älteren App-Versionen, die Sportradar-URNs
      // innerhalb des Query-Parameters bereits percent-encoded senden.
      value = Uri.decodeComponent(value);
    } catch (_) {
      throw ArgumentError('Ungültige Kodierung im Tennis-Provider-Pfad.');
    }
    if (value.isEmpty) {
      throw ArgumentError('Tennis-Provider-Pfad fehlt.');
    }
    if (!value.startsWith('/')) value = '/$value';

    final lower = value.toLowerCase();
    if (value.length > 240 ||
        value.contains('\\') ||
        value.contains('..') ||
        value.contains('?') ||
        value.contains('#') ||
        lower.contains('%2f') ||
        lower.contains('%5c')) {
      throw ArgumentError('Ungültiger Tennis-Provider-Pfad.');
    }

    return value;
  }

  void _assertAllowedProviderPath(String path) {
    const id = r'[A-Za-z0-9:_-]+';
    final allowed = <RegExp>[
      RegExp(r'^/schedules/\d{4}-\d{2}-\d{2}/summaries\.json$'),
      RegExp(
        '^/competitors/$id/profile[.]json'
        r'$',
      ),
      RegExp(
        '^/competitors/$id/summaries[.]json'
        r'$',
      ),
      RegExp(
        '^/competitors/$id/versus/$id/summaries[.]json'
        r'$',
      ),
      RegExp(r'^/rankings\.json$'),
      RegExp(
        '^/seasons/$id/info[.]json'
        r'$',
      ),
    ];

    if (!allowed.any((pattern) => pattern.hasMatch(path))) {
      throw ArgumentError('Tennis-Provider-Pfad ist nicht freigegeben: $path');
    }
  }

  Future<Map<String, dynamic>> _queuedProviderGet(String path) {
    final completer = Completer<Map<String, dynamic>>();

    _requestQueue = _requestQueue.catchError((Object _) {}).then((_) async {
      try {
        final last = _lastRequestAt;
        if (last != null) {
          final elapsed = DateTime.now().difference(last);
          if (elapsed < minimumRequestInterval) {
            await Future<void>.delayed(minimumRequestInterval - elapsed);
          }
        }

        final payload = await _providerGet(path);
        completer.complete(payload);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    return completer.future;
  }

  Future<Map<String, dynamic>> _providerGet(String path) async {
    final uri = Uri.parse('$_baseUrl/$accessLevel/v3/$language$path');

    final response = await _performProviderGet(uri);
    _lastRequestAt = DateTime.now();

    if (response.statusCode == 401 || response.statusCode == 403) {
      final requestId =
          response.headers['x-request-id'] ??
          response.headers['x-amzn-requestid'] ??
          response.headers['x-correlation-id'] ??
          'unbekannt';
      final safeBody = response.body
          .replaceAll(apiKey, '[redacted]')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final preview = safeBody.length > 300
          ? '${safeBody.substring(0, 300)}…'
          : safeBody;
      throw StateError(
        'Sportradar Tennis HTTP ${response.statusCode}; '
        'requestId=$requestId; response=$preview',
      );
    }
    if (response.statusCode == 429) {
      throw StateError('Sportradar-Tennis-Anfragelimit erreicht.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Sportradar Tennis HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw StateError('Ungültige Tennis-Antwort.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<_ProviderHttpResponse> _performProviderGet(Uri uri) async {
    if (!_useSystemCurl) {
      final response = await _client
          .get(
            uri,
            headers: <String, String>{
              'accept': 'application/json',
              'x-api-key': apiKey,
            },
          )
          .timeout(const Duration(seconds: 35));
      return _ProviderHttpResponse(
        statusCode: response.statusCode,
        body: response.body,
        headers: response.headers,
      );
    }

    final headerResponse = await _performSystemCurl(uri);
    if (headerResponse.statusCode != 401 && headerResponse.statusCode != 403) {
      return headerResponse;
    }

    // Some Sportradar trial subscriptions still authenticate through the
    // legacy api_key query parameter although the current docs show a header.
    return _performSystemCurl(uri, keyInQuery: true);
  }

  Future<_ProviderHttpResponse> _performSystemCurl(
    Uri uri, {
    bool keyInQuery = false,
  }) async {
    final requestUri = keyInQuery
        ? uri.replace(
            queryParameters: <String, String>{
              ...uri.queryParameters,
              'api_key': apiKey,
            },
          )
        : uri;

    // Sportradar accepts this exact cURL request from the Railway host but
    // rejects Dart's TLS/HTTP fingerprint with 403. Keep the arguments equal
    // to Sportradar's documented and verified request form.
    final process = await Process.start('curl', <String>[
      '--silent',
      '--show-error',
      '--ipv4',
      '--max-time',
      '35',
      '--write-out',
      r'\n%{http_code}',
      '--header',
      'accept: application/json',
      if (!keyInQuery) ...<String>['--header', 'x-api-key: $apiKey'],
      requestUri.toString(),
    ], runInShell: false);

    final outputFuture = utf8.decoder.bind(process.stdout).join();
    final errorFuture = utf8.decoder.bind(process.stderr).join();
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    final output = await outputFuture;
    final error = await errorFuture;
    if (exitCode != 0) {
      final safeError = error.replaceAll(apiKey, '[redacted]').trim();
      throw StateError('Sportradar curl fehlgeschlagen: $safeError');
    }

    final separator = output.lastIndexOf('\n');
    if (separator < 0) {
      throw StateError('Ungültige Sportradar-curl-Antwort.');
    }
    final statusCode = int.tryParse(output.substring(separator + 1).trim());
    if (statusCode == null) {
      throw StateError('Ungültiger Sportradar-HTTP-Status.');
    }
    return _ProviderHttpResponse(
      statusCode: statusCode,
      body: output.substring(0, separator),
    );
  }

  Duration _cacheDuration(String path) {
    if (path.startsWith('/schedules/')) return const Duration(minutes: 3);
    if (path == '/rankings.json') return const Duration(hours: 6);
    if (path.endsWith('/profile.json')) return const Duration(hours: 12);
    if (path.contains('/versus/')) return const Duration(hours: 8);
    if (path.endsWith('/summaries.json')) return const Duration(hours: 2);
    return const Duration(hours: 12);
  }

  void _removeExpiredCacheEntries() {
    final now = DateTime.now();
    _cache.removeWhere((_, entry) => !now.isBefore(entry.expiresAt));

    const maximumEntries = 500;
    if (_cache.length <= maximumEntries) return;

    final oldestFirst = _cache.entries.toList()
      ..sort((a, b) => a.value.expiresAt.compareTo(b.value.expiresAt));
    final removeCount = _cache.length - maximumEntries;
    for (final entry in oldestFirst.take(removeCount)) {
      _cache.remove(entry.key);
    }
  }

  String _tour(Map<String, dynamic> competition) {
    final text =
        '${competition['name'] ?? ''} '
                '${competition['category'] ?? ''}'
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
      ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
      : const <Map<String, dynamic>>[];

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  void close() {
    _cache.clear();
    _flights.clear();
    _client.close();
  }
}
