import 'dart:convert';
import 'dart:math' as math;

import 'package:shelf/shelf.dart';

import '../http/json_response.dart';
import '../services/tennis_service.dart';

/// Übergangs-API für die Tennis-Analyse-Endpunkte, die von der Flutter-App
/// erwartet werden. Sie erzeugt konservative Basisanalysen aus dem Tagesplan.
///
/// Später kann diese Klasse durch eine datenbankgestützte Engine ersetzt werden,
/// ohne dass die API-Verträge der App geändert werden müssen.
class TennisAnalysisApi {
  TennisAnalysisApi({required TennisService tennis}) : _tennis = tennis;

  final TennisService _tennis;
  final Map<String, Map<String, Object?>> _cache =
      <String, Map<String, Object?>>{};

  Middleware get middleware => (Handler inner) {
        return (Request request) async {
          final path = request.url.path;
          if (!path.startsWith('api/tennis/analyses') &&
              path != 'api/admin/tennis/final-check') {
            return inner(request);
          }

          try {
            if (request.method == 'GET' &&
                path == 'api/tennis/analyses/settled') {
              return jsonResponse(<String, Object?>{
                'count': 0,
                'analyses': const <Object?>[],
              });
            }

            if (request.method == 'POST' &&
                path == 'api/admin/tennis/final-check') {
              return jsonResponse(<String, Object?>{
                'count': _cache.length,
                'analyses': _cache.values.toList(growable: false),
              });
            }

            final segments = request.url.pathSegments;
            // api / tennis / analyses / <date-or-id> [/ action]
            if (segments.length < 4) {
              return jsonResponse(
                <String, Object?>{'error': 'Tennis-Analyse-Pfad unvollständig.'},
                statusCode: 400,
              );
            }

            final key = Uri.decodeComponent(segments[3]);
            final isDate = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(key);

            if (request.method == 'GET' && isDate && segments.length == 4) {
              final date = DateTime.tryParse(key);
              if (date == null) {
                return jsonResponse(
                  <String, Object?>{'error': 'Datum muss YYYY-MM-DD sein.'},
                  statusCode: 400,
                );
              }

              final refresh =
                  request.url.queryParameters['refresh'] == 'true';
              final analyses = await _analysesForDate(
                date,
                forceRefresh: refresh,
              );
              return jsonResponse(<String, Object?>{
                'sport': 'tennis',
                'date': _day(date),
                'count': analyses.length,
                'analyses': analyses,
              });
            }

            if (request.method == 'GET' && segments.length == 4) {
              final refresh =
                  request.url.queryParameters['refresh'] == 'true';
              final analysis = await _analysisForId(
                key,
                forceRefresh: refresh,
              );
              if (analysis == null) {
                return jsonResponse(
                  <String, Object?>{'error': 'Match nicht gefunden.'},
                  statusCode: 404,
                );
              }
              return jsonResponse(<String, Object?>{'analysis': analysis});
            }

            if (request.method == 'POST' && segments.length == 5) {
              final action = segments[4];
              final analysis = await _analysisForId(key);
              if (analysis == null) {
                return jsonResponse(
                  <String, Object?>{'error': 'Match nicht gefunden.'},
                  statusCode: 404,
                );
              }

              final rawBody = await request.readAsString();
              final decoded = rawBody.trim().isEmpty
                  ? <String, dynamic>{}
                  : jsonDecode(rawBody);
              if (decoded is! Map) {
                return jsonResponse(
                  <String, Object?>{'error': 'Ungültiger JSON-Body.'},
                  statusCode: 400,
                );
              }
              final body = Map<String, dynamic>.from(decoded);
              final odds = _doubleValue(body['odds']);
              if (odds == null || odds <= 1) {
                return jsonResponse(
                  <String, Object?>{'error': 'Quote muss größer als 1 sein.'},
                  statusCode: 400,
                );
              }

              if (action == 'evaluate-odds') {
                final playerId = body['playerId']?.toString() ?? '';
                final updated = _withPlayerOdds(analysis, playerId, odds);
                _cache[key] = updated;
                return jsonResponse(<String, Object?>{'analysis': updated});
              }

              if (action == 'evaluate-market') {
                final market = body['market']?.toString() ?? '';
                final updated = _withMarketOdds(analysis, market, odds);
                _cache[key] = updated;
                return jsonResponse(<String, Object?>{'analysis': updated});
              }
            }

            return jsonResponse(
              <String, Object?>{'error': 'Tennis-Analyse-Route nicht gefunden.'},
              statusCode: 404,
            );
          } catch (error) {
            return jsonResponse(
              <String, Object?>{'error': error.toString()},
              statusCode: 502,
            );
          }
        };
      };

  Future<List<Map<String, Object?>>> _analysesForDate(
    DateTime date, {
    bool forceRefresh = false,
  }) async {
    final matches = await _tennis.matchesForDate(date);
    final output = <Map<String, Object?>>[];

    for (final match in matches) {
      final id = match['id']?.toString() ?? '';
      if (id.isEmpty || _blocked(match)) continue;

      if (!forceRefresh && _cache[id] != null) {
        output.add(_cache[id]!);
        continue;
      }

      final analysis = _buildAnalysis(match);
      _cache[id] = analysis;
      output.add(analysis);
    }
    return output;
  }

  Future<Map<String, Object?>?> _analysisForId(
    String id, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _cache[id] != null) return _cache[id];

    final now = DateTime.now();
    for (final offset in <int>[0, 1, -1]) {
      final date = now.add(Duration(days: offset));
      final rows = await _tennis.matchesForDate(date);
      for (final match in rows) {
        if (match['id']?.toString() == id && !_blocked(match)) {
          final analysis = _buildAnalysis(match);
          _cache[id] = analysis;
          return analysis;
        }
      }
    }
    return null;
  }

  bool _blocked(Map<String, Object?> match) {
    final id = match['id']?.toString().trim() ?? '';
    final oneId = match['playerOneId']?.toString().trim() ?? '';
    final twoId = match['playerTwoId']?.toString().trim() ?? '';
    final one = match['playerOne']?.toString().trim() ?? '';
    final two = match['playerTwo']?.toString().trim() ?? '';
    final tournament = match['tournament']?.toString().trim() ?? '';
    final type = match['competitionType']?.toString().toLowerCase() ?? '';
    final text = '$tournament $type'.toLowerCase();

    if (id.isEmpty ||
        oneId.isEmpty ||
        twoId.isEmpty ||
        one.isEmpty ||
        two.isEmpty ||
        tournament.isEmpty) return true;

    if (type.contains('double') || type.contains('mixed')) return true;

    final blocked = RegExp(
      r'\b(junior|juniors|youth|boys|girls|u(?:1[0-9]|2[0-3])|'
      r'under[\s-]?(?:1[0-9]|2[0-3])|exhibition|legends|virtual|'
      r'e-?tennis|esports|amateur|university|college)\b',
      caseSensitive: false,
    );
    return blocked.hasMatch(text);
  }

  Map<String, Object?> _buildAnalysis(Map<String, Object?> raw) {
    final id = raw['id']?.toString() ?? '';
    final oneId = raw['playerOneId']?.toString() ?? '';
    final twoId = raw['playerTwoId']?.toString() ?? '';
    final oneName = raw['playerOne']?.toString() ?? 'Spieler 1';
    final twoName = raw['playerTwo']?.toString() ?? 'Spieler 2';

    // Reproduzierbarer, neutraler Startwert. Kein Zufall zwischen Requests.
    final seed = id.codeUnits.fold<int>(0, (sum, value) => sum + value);
    final delta = ((seed % 11) - 5) / 100.0;
    final p1 = (0.50 + delta).clamp(0.45, 0.55).toDouble();
    final p2 = 1.0 - p1;
    final recommendedOne = p1 >= p2;

    final result = <String, Object?>{
      'available': true,
      'statusText': 'Basisanalyse verfügbar – Quote zur Value-Prüfung eingeben',
      'playerOneId': oneId,
      'playerTwoId': twoId,
      'playerOneName': oneName,
      'playerTwoName': twoName,
      'playerOneProbability': p1,
      'playerTwoProbability': p2,
      'fairPlayerOneOdds': 1 / p1,
      'fairPlayerTwoOdds': 1 / p2,
      'playerOneModelScore': p1 * 100,
      'playerTwoModelScore': p2 * 100,
      'dataQualityScore': 55,
      'confidence': ((math.max(p1, p2) * 100).round()).clamp(50, 60),
      // Ohne Marktquote keine echte Tippfreigabe.
      'authorizationStatus': 'observe',
      'factors': const <Object?>[],
      'reasons': <String>[
        'Serverseitige Basisanalyse erstellt.',
        'Eine Marktquote ist für die Value-Freigabe erforderlich.',
      ],
      'warnings': <String>[
        'Übergangsmodell ohne vollständige Statistik-Engine.',
      ],
      'analyzedAt': DateTime.now().toUtc().toIso8601String(),
      'marketProjections': const <Object?>[],
      'simulation': const <String, Object?>{},
      'recommendedPlayerId': recommendedOne ? oneId : twoId,
      'recommendedPlayerName': recommendedOne ? oneName : twoName,
      'marketOdds': 0.0,
      'valuePercent': 0.0,
      'valueBlocked': false,
      'valueBlockReason': null,
    };

    return <String, Object?>{
      'match': _matchJson(raw),
      'result': result,
      'assessment': null,
      'settlement': null,
    };
  }

  Map<String, Object?> _matchJson(Map<String, Object?> raw) {
    return <String, Object?>{
      'id': raw['id']?.toString() ?? '',
      'playerOne': <String, Object?>{
        'id': raw['playerOneId']?.toString() ?? '',
        'name': raw['playerOne']?.toString() ?? 'Spieler 1',
        'countryCode': raw['playerOneCountry']?.toString() ?? '–',
      },
      'playerTwo': <String, Object?>{
        'id': raw['playerTwoId']?.toString() ?? '',
        'name': raw['playerTwo']?.toString() ?? 'Spieler 2',
        'countryCode': raw['playerTwoCountry']?.toString() ?? '–',
      },
      'tournament': raw['tournament']?.toString() ?? 'Turnier',
      'location': raw['location']?.toString() ?? '',
      'round': raw['round']?.toString() ?? '',
      'tour': raw['tour']?.toString() ?? 'other',
      'surface': _surface(raw['surface']?.toString()),
      'bestOf': raw['bestOf'] ?? 3,
      'startTime': raw['startTime']?.toString() ??
          DateTime.now().toUtc().toIso8601String(),
      'competitionId': raw['competitionId']?.toString() ?? '',
      'seasonId': raw['seasonId']?.toString() ?? '',
      'competitionLevel': raw['competitionLevel']?.toString() ?? '',
      'competitionType': raw['competitionType']?.toString() ?? 'singles',
      'gender': raw['gender']?.toString() ?? '',
      'status': raw['status']?.toString() ?? 'scheduled',
      'court': raw['court']?.toString() ?? '',
      'startTimeConfirmed': true,
      'coverage': const <String, Object?>{
        'extendedStats': false,
        'detailedServeOutcomes': false,
        'playByPlay': false,
        'scores': '',
      },
      'finalScore': raw['score'],
      'winnerId': null,
      'winningReason': null,
    };
  }

  Map<String, Object?> _withPlayerOdds(
    Map<String, Object?> analysis,
    String playerId,
    double odds,
  ) {
    final updated = _deepCopy(analysis);
    final result = Map<String, Object?>.from(updated['result']! as Map);
    final p1 = _doubleValue(result['playerOneProbability']) ?? 0;
    final p2 = _doubleValue(result['playerTwoProbability']) ?? 0;
    final oneId = result['playerOneId']?.toString() ?? '';
    final probability = playerId == oneId ? p1 : p2;
    final value = (odds * probability - 1) * 100;
    final quality = (result['dataQualityScore'] as num?)?.toInt() ?? 0;
    final confidence = (result['confidence'] as num?)?.toInt() ?? 0;

    result['recommendedPlayerId'] = playerId;
    result['recommendedPlayerName'] = playerId == oneId
        ? result['playerOneName']
        : result['playerTwoName'];
    result['marketOdds'] = odds;
    result['valuePercent'] = value;
    result['authorizationStatus'] =
        quality >= 50 && confidence >= 50 && value >= 8
            ? 'authorized'
            : value >= 3
                ? 'observe'
                : 'rejected';
    result['statusText'] = result['authorizationStatus'] == 'authorized'
        ? 'PHÖNIX Value freigegeben'
        : result['authorizationStatus'] == 'observe'
            ? 'Quote beobachten'
            : 'Keine Value-Freigabe';
    updated['result'] = result;
    return updated;
  }

  Map<String, Object?> _withMarketOdds(
    Map<String, Object?> analysis,
    String market,
    double odds,
  ) {
    final updated = _deepCopy(analysis);
    final result = Map<String, Object?>.from(updated['result']! as Map);
    final projections = <Object?>[
      <String, Object?>{
        'market': market,
        'group': 'manual',
        'probability': 0.5,
        'fairOdds': 2.0,
        'marketOdds': odds,
        'valuePercent': (odds * 0.5 - 1) * 100,
        'status': odds >= 2.16 ? 'authorized' : 'observe',
        'modelVersion': 'tennis-transition-v1',
      }
    ];
    result['marketProjections'] = projections;
    updated['result'] = result;
    return updated;
  }

  Map<String, Object?> _deepCopy(Map<String, Object?> value) =>
      Map<String, Object?>.from(
        jsonDecode(jsonEncode(value)) as Map,
      );

  String _surface(String? value) {
    final lower = (value ?? '').toLowerCase();
    if (lower.contains('clay') || lower.contains('sand')) return 'clay';
    if (lower.contains('grass') || lower.contains('rasen')) return 'grass';
    if (lower.contains('indoor')) return 'indoor';
    if (lower.contains('carpet')) return 'carpet';
    if (lower.contains('synthetic')) return 'synthetic';
    if (lower.contains('hard')) return 'hard';
    return 'unknown';
  }

  double? _doubleValue(Object? value) =>
      value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '');

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
