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
    final failures = <Map<String, Object?>>[];

    for (final candidate in candidates) {
      try {
        results.add(await _verifyCandidate(
          phaseTwoScanRunId: phaseTwoScanRunId,
          candidate: candidate,
        ));
      } catch (error) {
        final fixtureId = candidate['fixture_id']?.toString() ?? '';
        final message = error.toString();

        failures.add({
          'fixtureId': fixtureId,
          'error': message,
        });

        // Auch technische Fehler werden gespeichert. Damit ist später klar,
        // ob Gemini fehlgeschlagen ist oder nur wegen geringer Zuverlässigkeit
        // nicht angewendet wurde.
        if (fixtureId.isNotEmpty) {
          await database.saveFootballAiContextCheck(
            phaseTwoScanRunId: phaseTwoScanRunId,
            fixtureId: fixtureId,
            model: model,
            status: 'failed',
            contextResult: {
              'fixtureId': fixtureId,
              'provider': 'gemini',
              'error': message,
              'context': {
                'provider': 'gemini',
                'model': model,
                'verificationStatus': 'unclear',
                'reliability': 0,
                'applied': false,
                'critical': false,
                'requiresReanalysis': true,
                'summary': 'Gemini-Kontextprüfung fehlgeschlagen.',
                'facts': const <Object?>[],
                'sourceUrls': const <Object?>[],
              },
            },
          );
        }
      }
    }

    return {
      'status': 'completed',
      'phase': 3,
      'provider': 'gemini',
      'processed': results.length,
      'failed': failures.length,
      'results': results,
      'failures': failures,
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
Du bist die externe Kontext- und Taktikprüfung für die PHÖNIX-Fußballanalyse.

GRUNDSÄTZE:
- Berechne keine Wettwahrscheinlichkeit, keine faire Quote und kein Value.
- Erfinde keine Fakten, Quellen, Verletzungen, Sperren oder Aufstellungen.
- Nutze bevorzugt offizielle Vereins-, Liga-, Trainer- und Wettbewerbsquellen.
- Ergänze nur Informationen, die nicht bereits sicher in den strukturierten API-Daten enthalten sind.
- Markiere mögliche Doppelzählungen ausdrücklich.
- Trenne gesicherte aktuelle Fakten von längerfristigen taktischen Tendenzen.
- Eine taktische Vermutung ohne belastbare Quelle darf die Torerwartung nicht verändern.
- Die gesamte Torerwartungs-Anpassung je Team darf nur zwischen -0.20 und +0.20 liegen.
- Der gesamte Confidence-Einfluss darf nur zwischen -10 und +5 liegen.

SPIEL:
${payload['homeTeam']} gegen ${payload['awayTeam']}
Liga/Wettbewerb: ${payload['league']}
Anstoß: ${payload['kickoff']}
Land: ${payload['country']}
Vorhandene Verletzungsdatensätze: ${availability['injuriesCount']}
Aufstellungen verfügbar: ${availability['lineups']}
Datenqualität: ${candidate['data_quality']}

PRÜFAUFTRAG:
1. Ausfälle, Sperren, Rückkehrer, Rotation und voraussichtliche/confirmierte Aufstellungen.
2. Wichtigkeit des Spiels: Titel, Aufstieg, Abstieg, Qualifikation, K.-o.-Lage, Derby,
   Hin-/Rückspiel, Must-win, Tabellenkontext, mögliche Schonung und Motivationslage.
3. Erwartete taktische Grundordnung beider Teams und wahrscheinliche Anpassungen.
4. Spielaufbau: kurz/lang, Aufbau über Außen/Zentrum, Ballbesitzabsicht und Pressingresistenz.
5. Pressing: Intensität, Höhe, Auslöser, Gegenpressing, Pressinganfälligkeit und mögliche Auswege.
6. Defensive: hoher/mittlerer/tiefer Block, Raum-/Mannorientierung, Restverteidigung und Flankenverteidigung.
7. Umschalten: Konterstärke, Tempo, Tiefe, Absicherung und Risiko nach Ballverlusten.
8. Breite, Halbräume, Überladungen, Standards, zweite Bälle und erwartetes Spieltempo.
9. Direkter taktischer Matchup: Welche Spielweise kann die andere neutralisieren oder bestrafen?
10. Belastung, Reise, Wetter, Platz, Trainerwechsel und sonstige aktuelle Kontextfaktoren.

Gib eine strukturierte, vorsichtige Bewertung zurück. homeGoalDelta und awayGoalDelta
müssen bereits die gesamte zulässige Kontextwirkung enthalten; taktische Teilwerte dürfen
nicht zusätzlich ein zweites Mal eingerechnet werden.
''';

    final tacticalProfileSchema = {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'baseFormation': {'type': 'string', 'maxLength': 40},
        'likelyFormationChange': {'type': 'string', 'maxLength': 100},
        'buildUpStyle': {
          'type': 'string',
          'enum': ['short', 'mixed', 'direct', 'unknown'],
        },
        'possessionIntent': {
          'type': 'string',
          'enum': ['dominant', 'balanced', 'reactive', 'unknown'],
        },
        'pressingIntensity': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        'pressingHeight': {
          'type': 'string',
          'enum': ['high', 'medium', 'low', 'variable', 'unknown'],
        },
        'pressingTriggers': {
          'type': 'array',
          'maxItems': 6,
          'items': {'type': 'string', 'maxLength': 120},
        },
        'counterPressing': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        'pressResistance': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        'defensiveBlock': {
          'type': 'string',
          'enum': ['high', 'mid', 'low', 'variable', 'unknown'],
        },
        'transitionThreat': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        'transitionRisk': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        'widthUsage': {
          'type': 'string',
          'enum': ['wide', 'half_spaces', 'central', 'mixed', 'unknown'],
        },
        'setPieceThreat': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        'expectedTempo': {'type': 'integer', 'minimum': 0, 'maximum': 100},
        'keyStrengths': {
          'type': 'array',
          'maxItems': 5,
          'items': {'type': 'string', 'maxLength': 160},
        },
        'keyWeaknesses': {
          'type': 'array',
          'maxItems': 5,
          'items': {'type': 'string', 'maxLength': 160},
        },
        'sourceConfidence': {'type': 'integer', 'minimum': 0, 'maximum': 100},
      },
      'required': [
        'baseFormation',
        'likelyFormationChange',
        'buildUpStyle',
        'possessionIntent',
        'pressingIntensity',
        'pressingHeight',
        'pressingTriggers',
        'counterPressing',
        'pressResistance',
        'defensiveBlock',
        'transitionThreat',
        'transitionRisk',
        'widthUsage',
        'setPieceThreat',
        'expectedTempo',
        'keyStrengths',
        'keyWeaknesses',
        'sourceConfidence',
      ],
    };

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
        'matchImportance': {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'level': {
              'type': 'string',
              'enum': ['low', 'normal', 'high', 'critical', 'unclear'],
            },
            'homeMotivation': {'type': 'integer', 'minimum': -100, 'maximum': 100},
            'awayMotivation': {'type': 'integer', 'minimum': -100, 'maximum': 100},
            'pressureLevel': {'type': 'integer', 'minimum': 0, 'maximum': 100},
            'rotationRiskHome': {'type': 'integer', 'minimum': 0, 'maximum': 100},
            'rotationRiskAway': {'type': 'integer', 'minimum': 0, 'maximum': 100},
            'reasons': {
              'type': 'array',
              'maxItems': 6,
              'items': {'type': 'string', 'maxLength': 180},
            },
          },
          'required': [
            'level',
            'homeMotivation',
            'awayMotivation',
            'pressureLevel',
            'rotationRiskHome',
            'rotationRiskAway',
            'reasons',
          ],
        },
        'homeTacticalProfile': tacticalProfileSchema,
        'awayTacticalProfile': tacticalProfileSchema,
        'tacticalMatchup': {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'expectedTempo': {'type': 'integer', 'minimum': 0, 'maximum': 100},
            'expectedPressingLevel': {'type': 'integer', 'minimum': 0, 'maximum': 100},
            'fieldTiltHome': {'type': 'integer', 'minimum': -100, 'maximum': 100},
            'homeAdvantages': {
              'type': 'array',
              'maxItems': 5,
              'items': {'type': 'string', 'maxLength': 180},
            },
            'awayAdvantages': {
              'type': 'array',
              'maxItems': 5,
              'items': {'type': 'string', 'maxLength': 180},
            },
            'keyRisks': {
              'type': 'array',
              'maxItems': 6,
              'items': {'type': 'string', 'maxLength': 180},
            },
            'likelyGameState': {'type': 'string', 'maxLength': 320},
            'sourceConfidence': {'type': 'integer', 'minimum': 0, 'maximum': 100},
          },
          'required': [
            'expectedTempo',
            'expectedPressingLevel',
            'fieldTiltHome',
            'homeAdvantages',
            'awayAdvantages',
            'keyRisks',
            'likelyGameState',
            'sourceConfidence',
          ],
        },
        'critical': {'type': 'boolean'},
        'requiresReanalysis': {'type': 'boolean'},
        'facts': {
          'type': 'array',
          'maxItems': 14,
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
                  'match_importance',
                  'travel',
                  'formation',
                  'build_up',
                  'pressing',
                  'defensive_block',
                  'transition',
                  'set_piece',
                  'tactical_matchup',
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
        'summary': {'type': 'string', 'maxLength': 1100},
        'sourceUrls': {
          'type': 'array',
          'maxItems': 16,
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
        'matchImportance',
        'homeTacticalProfile',
        'awayTacticalProfile',
        'tacticalMatchup',
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
        .timeout(const Duration(seconds: 150));

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
        ? (_number(context['homeGoalDelta']) ?? 0).clamp(-0.20, 0.20).toDouble()
        : 0.0;
    context['awayGoalDelta'] = reliableEnough
        ? (_number(context['awayGoalDelta']) ?? 0).clamp(-0.20, 0.20).toDouble()
        : 0.0;
    context['confidenceDelta'] = reliableEnough
        ? _integer(context['confidenceDelta']).clamp(-10, 5)
        : 0;
    context['matchImportance'] = _sanitizeMatchImportance(
      _map(context['matchImportance']),
    );
    context['homeTacticalProfile'] = _sanitizeTacticalProfile(
      _map(context['homeTacticalProfile']),
    );
    context['awayTacticalProfile'] = _sanitizeTacticalProfile(
      _map(context['awayTacticalProfile']),
    );
    context['tacticalMatchup'] = _sanitizeTacticalMatchup(
      _map(context['tacticalMatchup']),
    );
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

  Map<String, Object?> _sanitizeMatchImportance(
    Map<String, Object?> value,
  ) {
    return {
      ...value,
      'homeMotivation': _integer(value['homeMotivation']).clamp(-100, 100),
      'awayMotivation': _integer(value['awayMotivation']).clamp(-100, 100),
      'pressureLevel': _integer(value['pressureLevel']).clamp(0, 100),
      'rotationRiskHome': _integer(value['rotationRiskHome']).clamp(0, 100),
      'rotationRiskAway': _integer(value['rotationRiskAway']).clamp(0, 100),
    };
  }

  Map<String, Object?> _sanitizeTacticalProfile(
    Map<String, Object?> value,
  ) {
    return {
      ...value,
      'pressingIntensity': _integer(value['pressingIntensity']).clamp(0, 100),
      'counterPressing': _integer(value['counterPressing']).clamp(0, 100),
      'pressResistance': _integer(value['pressResistance']).clamp(0, 100),
      'transitionThreat': _integer(value['transitionThreat']).clamp(0, 100),
      'transitionRisk': _integer(value['transitionRisk']).clamp(0, 100),
      'setPieceThreat': _integer(value['setPieceThreat']).clamp(0, 100),
      'expectedTempo': _integer(value['expectedTempo']).clamp(0, 100),
      'sourceConfidence': _integer(value['sourceConfidence']).clamp(0, 100),
    };
  }

  Map<String, Object?> _sanitizeTacticalMatchup(
    Map<String, Object?> value,
  ) {
    return {
      ...value,
      'expectedTempo': _integer(value['expectedTempo']).clamp(0, 100),
      'expectedPressingLevel':
          _integer(value['expectedPressingLevel']).clamp(0, 100),
      'fieldTiltHome': _integer(value['fieldTiltHome']).clamp(-100, 100),
      'sourceConfidence': _integer(value['sourceConfidence']).clamp(0, 100),
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

  void close() {
    _client.close();
  }
}
