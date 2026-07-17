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

  Future<void> runBackground({
    required int jobId,
    required int phaseTwoScanRunId,
    int limit = 20,
  }) async {
    try {
      final result = await verifyAllEligibleTips(
        phaseTwoScanRunId: phaseTwoScanRunId,
        candidateLimit: limit,
      );

      await database.completeFootballAiContextJob(
        jobId: jobId,
        processed: _integer(result['processed']),
      );
    } catch (error) {
      await database.failFootballAiContextJob(
        jobId: jobId,
        error: error,
      );
    }
  }

  Future<Map<String, Object?>> verifyAllEligibleTips({
    required int phaseTwoScanRunId,
    int candidateLimit = 20,
  }) async {
    if (apiKey.isEmpty) {
      throw StateError('GEMINI_API_KEY fehlt.');
    }

    final candidates = await database.contextCandidates(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: candidateLimit.clamp(1, 20),
    );

    final eligible = candidates.where(_isEligiblePhoenixTip).toList()
      ..sort((a, b) => _candidateScore(b).compareTo(_candidateScore(a)));

    if (eligible.isEmpty) {
      return {
        'status': 'completed',
        'provider': 'gemini',
        'processed': 0,
        'reason': 'Keine geeigneten PHÖNIX-Tipps für die Gemini-Kontextprüfung.',
      };
    }

    final results = <Map<String, Object?>>[];

    for (final candidate in eligible) {
      final result = await _verifyCandidate(
        phaseTwoScanRunId: phaseTwoScanRunId,
        candidate: candidate,
      );
      results.add(result);
    }

    return {
      'status': 'completed',
      'provider': 'gemini',
      'processed': results.length,
      'results': results,
    };
  }

  bool _isEligiblePhoenixTip(Map<String, Object?> candidate) {
    final selection = _map(candidate['selection']);
    final phoenixTip = _map(selection['phoenixTip']);
    final trust = _map(selection['trust']);

    final qualifies =
        selection['qualifiesForTip'] == true || phoenixTip.isNotEmpty;
    final probability = _probabilityPercent(
      phoenixTip['probability'] ??
          phoenixTip['modelProbability'] ??
          selection['modelProbability'],
    );
    final trustScore = _integer(
      trust['score'] ?? selection['trustScore'] ?? selection['baseTrust'],
    );

    // Gemini unterstützt alle veröffentlichten PHÖNIX-Tipps,
    // unabhängig davon, ob sie Value besitzen.
    return qualifies && probability >= 50 && trustScore >= 50;
  }

  double _candidateScore(Map<String, Object?> candidate) {
    final selection = _map(candidate['selection']);
    final value = _map(selection['value']);
    final trust = _map(selection['trust']);
    final phoenixTip = _map(selection['phoenixTip']);

    final valuePercent =
        _number(value['valuePercent'] ?? selection['valuePercent']) ?? 0;
    final trustScore = _integer(
      trust['score'] ?? selection['trustScore'] ?? selection['baseTrust'],
    );
    final probability = _probabilityPercent(
      phoenixTip['probability'] ??
          phoenixTip['modelProbability'] ??
          selection['modelProbability'],
    );

    // Value-Tipps zuerst, danach Trust und Modellwahrscheinlichkeit.
    return valuePercent * 0.35 + trustScore * 0.40 + probability * 0.25;
  }

  Future<Map<String, Object?>> _verifyCandidate({
    required int phaseTwoScanRunId,
    required Map<String, Object?> candidate,
  }) async {
    final fixtureId = candidate['fixture_id']?.toString() ?? '';
    final selection = _map(candidate['selection']);
    final availability = _map(candidate['availability']);
    final payload = _map(candidate['payload']);
    final phoenixTip = _map(selection['phoenixTip']);
    final value = _map(selection['value']);

    final prompt = '''
Du unterstützt PHÖNIX ausschließlich bei der aktuellen Kontextprüfung eines bereits berechneten PHÖNIX-Tipps.

WICHTIGE GRENZEN:
- Berechne keine Wahrscheinlichkeit, keine faire Quote, kein Value und keine Units.
- Ändere nicht den Wettmarkt.
- Erfinde keine Verletzungen, Sperren, Aufstellungen oder Quellen.
- Bevorzuge offizielle Vereins-, Liga- und Wettbewerbsquellen.
- Die Trust-Anpassung darf nur zwischen -5 und +5 liegen.
- Halte die Antwort kurz und sachlich.

Spiel: ${payload['homeTeam']} gegen ${payload['awayTeam']}
Liga: ${payload['league']}
Anstoß: ${payload['kickoff']}
PHÖNIX-Tipp: ${phoenixTip['market'] ?? phoenixTip['label']}
Value-Status: ${value['isValueTip'] == true ? 'Value-Tipp' : 'kein Value-Tipp'}
Berechnetes Value: ${value['valuePercent']} %
Marktquote: ${value['marketOdds']}
API-Verletzungsdatensätze: ${availability['injuriesCount']}

Prüfe nur aktuelle Ausfälle, Sperren, Rückkehrer, Rotation, Belastung,
Motivation, Reise und Aufstellungsstatus. Bewerte anschließend, ob der
aktuelle Kontext den vorhandenen PHÖNIX-Tipp unterstützt, neutral ist oder
schwächt.
''';

    final schema = {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'verificationStatus': {
          'type': 'string',
          'enum': ['verified', 'partial', 'unclear'],
        },
        'contextEffect': {
          'type': 'string',
          'enum': ['supports_tip', 'neutral', 'weakens_tip'],
        },
        'suggestedTrustAdjustment': {
          'type': 'integer',
          'minimum': -5,
          'maximum': 5,
        },
        'lineupStatus': {
          'type': 'string',
          'enum': ['confirmed', 'expected_only', 'not_available'],
        },
        'injuries': {
          'type': 'array',
          'maxItems': 6,
          'items': {
            'type': 'object',
            'additionalProperties': false,
            'properties': {
              'player': {'type': 'string'},
              'team': {'type': 'string'},
              'status': {
                'type': 'string',
                'enum': ['out', 'doubtful', 'available', 'unclear'],
              },
              'importance': {
                'type': 'string',
                'enum': ['high', 'medium', 'low', 'unknown'],
              },
              'evidence': {'type': 'string', 'maxLength': 220},
            },
            'required': [
              'player',
              'team',
              'status',
              'importance',
              'evidence',
            ],
          },
        },
        'contextPoints': {
          'type': 'array',
          'maxItems': 5,
          'items': {'type': 'string', 'maxLength': 220},
        },
        'summary': {'type': 'string', 'maxLength': 600},
        'sourceUrls': {
          'type': 'array',
          'maxItems': 10,
          'items': {'type': 'string'},
        },
      },
      'required': [
        'verificationStatus',
        'contextEffect',
        'suggestedTrustAdjustment',
        'lineupStatus',
        'injuries',
        'contextPoints',
        'summary',
        'sourceUrls',
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
    context['suggestedTrustAdjustment'] =
        _integer(context['suggestedTrustAdjustment']).clamp(-5, 5);
    context['provider'] = 'gemini';
    context['model'] = model;
    context['role'] = 'phoenix_tip_context_support';

    final citationUrls = <String>{};
    _collectUrls(responseMap, citationUrls);
    final modelUrls = context['sourceUrls'];
    if (modelUrls is List) {
      for (final url in modelUrls) {
        final value = url?.toString().trim() ?? '';
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
      'context': context,
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

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  double _probabilityPercent(Object? value) {
    final number = _number(value) ?? 0;
    return number <= 1 ? number * 100 : number;
  }

  int _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
