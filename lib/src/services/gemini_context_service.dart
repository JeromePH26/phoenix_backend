import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

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
    if (apiKey.isEmpty) {
      throw StateError('GEMINI_API_KEY fehlt.');
    }

    final candidates = await database.geminiPhaseTwoCandidates(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit.clamp(1, 20),
    );

    final results = <Map<String, Object?>>[];
    for (final candidate in candidates) {
      results.add(await _verifyCandidate(
        phaseTwoScanRunId: phaseTwoScanRunId,
        candidate: candidate,
      ));
    }

    return {
      'status': 'completed',
      'phase': 3,
      'provider': 'gemini',
      'processed': results.length,
      'results': results,
    };
  }

  Future<Map<String, Object?>> _verifyCandidate({
    required int phaseTwoScanRunId,
    required Map<String, Object?> candidate,
  }) async {
    final fixtureId = candidate['fixture_id']?.toString() ?? '';
    final payload = _map(candidate['payload']);
    final availability = _map(candidate['availability']);

    final prompt = '''
Du prüfst aktuelle Nachrichten und Kontextfakten für die PHÖNIX-Fußballanalyse.

WICHTIG:
- Berechne keine Wettwahrscheinlichkeit, keine faire Quote und kein Value.
- Erfinde keine Verletzungen, Sperren, Aufstellungen oder Quellen.
- Nutze bevorzugt offizielle Vereins-, Liga- und Wettbewerbsquellen.
- Prüfe nur neue Informationen, die nicht bereits sicher in den strukturierten API-Daten enthalten sind.
- Markiere mögliche Doppelzählungen.
- Die Torerwartungs-Anpassung je Team darf nur zwischen -0.20 und +0.20 liegen.
- Der Confidence-Einfluss darf nur zwischen -10 und +5 liegen.

Spiel: ${payload['homeTeam']} gegen ${payload['awayTeam']}
Liga: ${payload['league']}
Anstoß: ${payload['kickoff']}
Vorhandene Verletzungsdatensätze: ${availability['injuriesCount']}
Aufstellungen verfügbar: ${availability['lineups']}
Datenqualität: ${candidate['data_quality']}

Prüfe aktuelle Ausfälle, Sperren, Rückkehrer, Rotation, Belastung, Motivation,
Reise, Taktikhinweise, Trainerwechsel, Wetter/Platz und Aufstellungsstatus.
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
        'homeContextScore': {'type': 'integer', 'minimum': -100, 'maximum': 100},
        'awayContextScore': {'type': 'integer', 'minimum': -100, 'maximum': 100},
        'homeGoalDelta': {'type': 'number', 'minimum': -0.20, 'maximum': 0.20},
        'awayGoalDelta': {'type': 'number', 'minimum': -0.20, 'maximum': 0.20},
        'confidenceDelta': {'type': 'integer', 'minimum': -10, 'maximum': 5},
        'lineupStatus': {
          'type': 'string',
          'enum': ['confirmed', 'expected_only', 'not_available'],
        },
        'critical': {'type': 'boolean'},
        'requiresReanalysis': {'type': 'boolean'},
        'facts': {
          'type': 'array',
          'maxItems': 8,
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
                  'tactics',
                  'weather',
                  'coach',
                  'lineup',
                  'other'
                ],
              },
              'team': {'type': 'string'},
              'summary': {'type': 'string', 'maxLength': 240},
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
        'summary': {'type': 'string', 'maxLength': 700},
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
    final reliableEnough =
        reliability >= 60 && context['verificationStatus'] != 'unclear';

    context['reliability'] = reliability;
    context['homeGoalDelta'] = reliableEnough
        ? (_number(context['homeGoalDelta']) ?? 0).clamp(-0.20, 0.20)
        : 0.0;
    context['awayGoalDelta'] = reliableEnough
        ? (_number(context['awayGoalDelta']) ?? 0).clamp(-0.20, 0.20)
        : 0.0;
    context['confidenceDelta'] = reliableEnough
        ? _integer(context['confidenceDelta']).clamp(-10, 5)
        : 0;
    context['provider'] = 'gemini';
    context['model'] = model;
    context['applied'] = reliableEnough;

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

    return {'fixtureId': fixtureId, 'context': context};
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
