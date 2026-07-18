import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';

import '../database/database.dart';

class GeminiContextService {
  GeminiContextService({
    required this.database,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final PhoenixDatabase database;
  final http.Client _client;

  String get apiKey => Platform.environment['GEMINI_API_KEY']?.trim() ?? '';

  String get model =>
      Platform.environment['GEMINI_MODEL']?.trim().isNotEmpty == true
          ? Platform.environment['GEMINI_MODEL']!.trim()
          : 'gemini-3.1-flash-lite';

  Future<Map<String, Object?>> verifyPhaseTwoMatches({
    required int phaseTwoScanRunId,
    int limit = 20,
  }) async {
    final candidates = await database.geminiPhaseTwoCandidates(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit.clamp(1, 20),
    );

    final results = <Map<String, Object?>>[];
    var applied = 0;
    var fallbackUsed = 0;
    var failed = 0;

    for (final candidate in candidates) {
      final result = await _resolveCandidate(
        phaseTwoScanRunId: phaseTwoScanRunId,
        candidate: candidate,
      );
      results.add(result);

      if (result['applied'] == true) applied++;
      if (result['fallbackUsed'] == true) fallbackUsed++;
      if (result['status'] == 'failed') failed++;
    }

    return {
      'status': 'completed',
      'phase': 3,
      'provider': 'gemini',
      'processed': results.length,
      'applied': applied,
      'fallbackUsed': fallbackUsed,
      'failed': failed,
      'results': results,
    };
  }

  Future<Map<String, Object?>> _resolveCandidate({
    required int phaseTwoScanRunId,
    required Map<String, Object?> candidate,
  }) async {
    final fixtureId = candidate['fixture_id']?.toString() ?? '';

    try {
      if (apiKey.isEmpty) {
        throw StateError('GEMINI_API_KEY fehlt.');
      }

      return await _verifyCandidate(
        phaseTwoScanRunId: phaseTwoScanRunId,
        candidate: candidate,
      );
    } catch (error) {
      final fallback = await _latestVerifiedFallback(
        fixtureId: fixtureId,
        currentPhaseTwoScanRunId: phaseTwoScanRunId,
      );

      if (fallback != null) {
        final previousResult = _jsonMap(fallback['context_result']);
        final previousContext = _map(previousResult['context']);
        final sourceRunId = _integer(fallback['phase_two_scan_run_id']);

        final restoredContext = <String, Object?>{
          ...previousContext,
          'provider': 'gemini',
          'model': fallback['model']?.toString() ?? model,
          'applied': previousContext['applied'] == true,
          'contextSource': 'fallback_previous_verified',
          'contextSourceScanRunId': sourceRunId,
          'fallbackUsed': true,
          'fallbackReason': error.toString(),
        };

        await database.saveFootballAiContextCheck(
          phaseTwoScanRunId: phaseTwoScanRunId,
          fixtureId: fixtureId,
          model: fallback['model']?.toString() ?? model,
          responseId: fallback['response_id']?.toString(),
          status: 'completed',
          contextResult: {
            'fixtureId': fixtureId,
            'provider': 'gemini',
            'context': restoredContext,
          },
        );

        return {
          'fixtureId': fixtureId,
          'status': 'completed',
          'applied': restoredContext['applied'] == true,
          'fallbackUsed': true,
          'contextSourceScanRunId': sourceRunId,
        };
      }

      final failedContext = <String, Object?>{
        'verificationStatus': 'unclear',
        'reliability': 0,
        'homeContextScore': 0,
        'awayContextScore': 0,
        'homeGoalDelta': 0.0,
        'awayGoalDelta': 0.0,
        'confidenceDelta': 0,
        'lineupStatus': 'not_available',
        'critical': false,
        'requiresReanalysis': false,
        'facts': <Object?>[],
        'summary': 'Gemini-Kontext war für diesen Lauf nicht verfügbar.',
        'sourceUrls': <Object?>[],
        'provider': 'gemini',
        'model': model,
        'applied': false,
        'contextSource': 'unavailable',
        'contextSourceScanRunId': phaseTwoScanRunId,
        'fallbackUsed': false,
        'error': error.toString(),
      };

      await database.saveFootballAiContextCheck(
        phaseTwoScanRunId: phaseTwoScanRunId,
        fixtureId: fixtureId,
        model: model,
        status: 'failed',
        contextResult: {
          'fixtureId': fixtureId,
          'provider': 'gemini',
          'context': failedContext,
        },
      );

      return {
        'fixtureId': fixtureId,
        'status': 'failed',
        'applied': false,
        'fallbackUsed': false,
        'error': error.toString(),
      };
    }
  }

  Future<Map<String, Object?>?> _latestVerifiedFallback({
    required String fixtureId,
    required int currentPhaseTwoScanRunId,
  }) async {
    if (fixtureId.isEmpty) return null;

    final db = await database.connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          phase_two_scan_run_id,
          fixture_id,
          model,
          response_id,
          status,
          context_result,
          created_at
        FROM football_ai_context_checks
        WHERE fixture_id = @fixture_id
          AND phase_two_scan_run_id <> @scan_run_id
          AND status = 'completed'
          AND COALESCE(
            context_result #>> '{context,applied}',
            'false'
          ) = 'true'
          AND context_result #>> '{context,verificationStatus}'
              IN ('verified', 'partial')
          AND created_at >= NOW() - INTERVAL '12 hours'
        ORDER BY created_at DESC
        LIMIT 1
      '''),
      parameters: {
        'fixture_id': fixtureId,
        'scan_run_id': currentPhaseTwoScanRunId,
      },
    );

    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>> _verifyCandidate({
    required int phaseTwoScanRunId,
    required Map<String, Object?> candidate,
  }) async {
    final fixtureId = candidate['fixture_id']?.toString() ?? '';
    final payload = _map(candidate['payload']);
    final availability = _map(candidate['availability']);

    final prompt = '''
Du prüfst aktuelle, belastbare Kontextfakten für die PHÖNIX-Fußballanalyse.

HARTE REGELN:
- Berechne keine Wettwahrscheinlichkeit, keine faire Quote und kein Value.
- Erfinde keine Verletzungen, Sperren, Aufstellungen, Taktiken oder Quellen.
- Nutze bevorzugt offizielle Vereins-, Liga- und Wettbewerbsquellen.
- Nutze nur Informationen, die zeitlich zum bevorstehenden Spiel passen.
- Prüfe, ob ein Punkt bereits in den strukturierten API-Daten enthalten ist.
- Bereits abgedeckte Informationen dürfen nicht doppelt gewichtet werden.
- Die Toranpassung je Team darf nur zwischen -0.20 und +0.20 liegen.
- Der Confidence-Einfluss darf nur zwischen -10 und +5 liegen.
- Bei unsicherer Quellenlage setzt du verificationStatus auf unclear und alle Deltas auf 0.

Spiel: ${payload['homeTeam']} gegen ${payload['awayTeam']}
Liga/Wettbewerb: ${payload['league']}
Land: ${payload['country']}
Anstoß: ${payload['kickoff']}
Datenqualität: ${candidate['data_quality']}
API-Verletzungsdatensätze: ${availability['injuriesCount']}
API-Aufstellungen verfügbar: ${availability['lineups']}

Prüfe insbesondere:
1. Ausfälle, Sperren, Rückkehrer, Rotation und voraussichtliche Aufstellungen.
2. Formationen und taktische Rollen.
3. Pressingintensität, Pressinghöhe und Pressingauslöser.
4. Gegenpressing und Pressingresistenz.
5. Tiefer/mittlerer/hoher Block und defensive Kompaktheit.
6. Umschaltspiel, Konterabsicherung und Restverteidigung.
7. Breite, Halbräume, Flügelüberladungen und zentrale Präsenz.
8. Standards offensiv und defensiv.
9. Spieltempo und erwartetes Matchbild.
10. Titel-, Aufstiegs-, Abstiegs-, K.-o.-, Derby- oder Must-win-Kontext.
11. Müdigkeit, Reisebelastung, enge Terminfolge und Trainerwechsel.

Gib nur belegbare, für dieses Spiel relevante Faktoren zurück.
''';

    final schema = {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'verificationStatus': {
          'type': 'string',
          'enum': ['verified', 'partial', 'unclear'],
        },
        'reliability': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        'homeContextScore': {
          'type': 'integer',
          'minimum': -100,
          'maximum': 100,
        },
        'awayContextScore': {
          'type': 'integer',
          'minimum': -100,
          'maximum': 100,
        },
        'homeGoalDelta': {
          'type': 'number',
          'minimum': -0.20,
          'maximum': 0.20,
        },
        'awayGoalDelta': {
          'type': 'number',
          'minimum': -0.20,
          'maximum': 0.20,
        },
        'confidenceDelta': {
          'type': 'integer',
          'minimum': -10,
          'maximum': 5,
        },
        'lineupStatus': {
          'type': 'string',
          'enum': ['confirmed', 'expected_only', 'not_available'],
        },
        'critical': {'type': 'boolean'},
        'requiresReanalysis': {'type': 'boolean'},
        'facts': {
          'type': 'array',
          'maxItems': 10,
          'items': {
            'type': 'object',
            'additionalProperties': false,
            'properties': {
              'category': {
                'type': 'string',
                'enum': [
                  'injury',
                  'suspension',
                  'return',
                  'rotation',
                  'fatigue',
                  'motivation',
                  'travel',
                  'formation',
                  'pressing',
                  'press_resistance',
                  'defensive_block',
                  'transition',
                  'width_halfspaces',
                  'set_pieces',
                  'tempo',
                  'tactics',
                  'weather',
                  'coach',
                  'lineup',
                  'other'
                ],
              },
              'team': {'type': 'string'},
              'summary': {'type': 'string', 'maxLength': 260},
              'importance': {
                'type': 'string',
                'enum': ['high', 'medium', 'low', 'unknown'],
              },
              'alreadyCoveredByStructuredData': {'type': 'boolean'},
              'sourceUrl': {'type': 'string'},
            },
            'required': [
              'category',
              'team',
              'summary',
              'importance',
              'alreadyCoveredByStructuredData',
              'sourceUrl'
            ],
          },
        },
        'summary': {'type': 'string', 'maxLength': 800},
        'sourceUrls': {
          'type': 'array',
          'maxItems': 10,
          'items': {'type': 'string'},
        },
      },
      'required': [
        'verificationStatus',
        'reliability',
        'homeContextScore',
        'awayContextScore',
        'homeGoalDelta',
        'awayGoalDelta',
        'confidenceDelta',
        'lineupStatus',
        'critical',
        'requiresReanalysis',
        'facts',
        'summary',
        'sourceUrls'
      ],
    };

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/interactions',
    );

    final response = await _client
        .post(
          uri,
          headers: {
            'x-goog-api-key': apiKey,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'model': model,
            'input': prompt,
            'tools': [
              {'type': 'google_search'},
            ],
            'response_format': {
              'type': 'text',
              'mime_type': 'application/json',
              'schema': schema,
            },
          }),
        )
        .timeout(const Duration(seconds: 120));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Gemini ${response.statusCode}: ${response.body}',
        uri: uri,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Ungültige Gemini-Antwort.');
    }

    final responseMap = Map<String, Object?>.from(decoded);
    final outputText = _extractOutputText(responseMap);
    final parsed = jsonDecode(outputText);
    if (parsed is! Map) {
      throw const FormatException('Gemini lieferte kein JSON-Objekt.');
    }

    final context = Map<String, Object?>.from(parsed);
    final reliability = _integer(context['reliability']).clamp(0, 100);
    final verificationStatus =
        context['verificationStatus']?.toString() ?? 'unclear';
    final reliableEnough =
        reliability >= 60 && verificationStatus != 'unclear';

    context['reliability'] = reliability;
    context['homeGoalDelta'] = reliableEnough
        ? ((_number(context['homeGoalDelta']) ?? 0)
            .clamp(-0.20, 0.20)
            .toDouble())
        : 0.0;
    context['awayGoalDelta'] = reliableEnough
        ? ((_number(context['awayGoalDelta']) ?? 0)
            .clamp(-0.20, 0.20)
            .toDouble())
        : 0.0;
    context['confidenceDelta'] = reliableEnough
        ? _integer(context['confidenceDelta']).clamp(-10, 5)
        : 0;
    context['provider'] = 'gemini';
    context['model'] = model;
    context['applied'] = reliableEnough;
    context['contextSource'] = 'current_scan';
    context['contextSourceScanRunId'] = phaseTwoScanRunId;
    context['fallbackUsed'] = false;

    final citationUrls = <String>{};
    _collectUrls(responseMap, citationUrls);
    final modelUrls = context['sourceUrls'];
    if (modelUrls is List) {
      for (final rawUrl in modelUrls) {
        final value = rawUrl?.toString().trim() ?? '';
        if (value.startsWith('http')) citationUrls.add(value);
      }
    }
    context['sourceUrls'] = citationUrls.take(10).toList();

    await database.saveFootballAiContextCheck(
      phaseTwoScanRunId: phaseTwoScanRunId,
      fixtureId: fixtureId,
      model: model,
      responseId: responseMap['id']?.toString(),
      status: 'completed',
      contextResult: {
        'fixtureId': fixtureId,
        'provider': 'gemini',
        'context': context,
        'rawUsage': responseMap['usage'],
      },
    );

    return {
      'fixtureId': fixtureId,
      'status': 'completed',
      'applied': reliableEnough,
      'fallbackUsed': false,
    };
  }

  String _extractOutputText(Map<String, Object?> response) {
    final direct = response['output_text']?.toString();
    if (direct != null && direct.trim().isNotEmpty) {
      return _stripCodeFence(direct);
    }

    final texts = <String>[];

    void walk(Object? value) {
      if (value is Map) {
        final type = value['type']?.toString();
        final text = value['text'];
        if ((type == 'text' || type == 'output_text') && text is String) {
          texts.add(text);
        }
        for (final child in value.values) {
          walk(child);
        }
      } else if (value is List) {
        for (final child in value) {
          walk(child);
        }
      }
    }

    walk(response);

    if (texts.isEmpty) {
      throw const FormatException('Gemini-Antwort enthält keinen Text.');
    }

    return _stripCodeFence(texts.last);
  }

  String _stripCodeFence(String value) {
    var text = value.trim();
    if (text.startsWith('```')) {
      text = text.replaceFirst(RegExp(r'^```(?:json)?\s*'), '');
      text = text.replaceFirst(RegExp(r'\s*```$'), '');
    }
    return text.trim();
  }

  void _collectUrls(Object? value, Set<String> result) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key.toString().toLowerCase() == 'url') {
          final url = entry.value?.toString().trim() ?? '';
          if (url.startsWith('http')) result.add(url);
        }
        _collectUrls(entry.value, result);
      }
    } else if (value is List) {
      for (final item in value) {
        _collectUrls(item, result);
      }
    }
  }

  Map<String, Object?> _jsonMap(Object? value) {
    if (value is Map) return Map<String, Object?>.from(value);
    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    }
    return <String, Object?>{};
  }

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  int _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
