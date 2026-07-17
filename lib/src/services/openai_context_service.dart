import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../database/database.dart';

class OpenAiContextService {
  OpenAiContextService({required this.database, http.Client? client})
      : _client = client ?? http.Client();

  final PhoenixDatabase database;
  final http.Client _client;

  String get apiKey => Platform.environment['OPENAI_API_KEY']?.trim() ?? '';
  String get model => Platform.environment['OPENAI_MODEL']?.trim() ?? '';

  Future<Map<String, Object?>> verify({required int phaseTwoScanRunId, int limit = 1}) async {
    if (apiKey.isEmpty || model.isEmpty) {
      throw StateError('OPENAI_API_KEY oder OPENAI_MODEL fehlt.');
    }
    final candidates = await database.contextCandidates(
      phaseTwoScanRunId: phaseTwoScanRunId,
      limit: limit,
    );
    final results = <Map<String, Object?>>[];

    for (final candidate in candidates) {
      final fixtureId = candidate['fixture_id']?.toString() ?? '';
      final selection = _map(candidate['selection']);
      final availability = _map(candidate['availability']);
      final payload = _map(candidate['payload']);
      final phoenixTip = _map(selection['phoenixTip']);

      final body = {
        'model': model,
        'store': false,
        'max_output_tokens': 1600,
        'tools': [{'type': 'web_search'}],
        'include': ['web_search_call.action.sources'],
        'instructions': 'Du prüfst aktuelle Kontextfakten für PHÖNIX. Berechne keine Wahrscheinlichkeiten, fairen Quoten oder Value-Werte. Erfinde keine Verletzungen, Sperren, Aufstellungen oder Quellen. Nutze bevorzugt offizielle Vereins- und Wettbewerbsquellen. Antworte ausschließlich im verlangten JSON-Schema.',
        'input': 'Spiel: ${payload['homeTeam']} gegen ${payload['awayTeam']}\nLiga: ${payload['league']}\nAnstoß: ${payload['kickoff']}\nPHÖNIX-Tipp: ${phoenixTip['market']}\nAPI-Verletzungsdatensätze: ${availability['injuriesCount']}\nPrüfe aktuelle Ausfälle, Sperren, Rückkehrer, Rotation, Belastung, Motivation, Reise und Aufstellungsstatus. Bewerte nur, ob der Kontext den Tipp unterstützt, neutral ist oder schwächt.',
        'text': {
          'format': {
            'type': 'json_schema',
            'name': 'phoenix_context_verification',
            'strict': true,
            'schema': {
              'type': 'object',
              'additionalProperties': false,
              'properties': {
                'verificationStatus': {'type':'string','enum':['verified','partial','unclear']},
                'contextEffect': {'type':'string','enum':['supports_tip','neutral','weakens_tip']},
                'suggestedTrustAdjustment': {'type':'integer','minimum':-10,'maximum':10},
                'lineupStatus': {'type':'string','enum':['confirmed','expected_only','not_available']},
                'injuries': {
                  'type':'array',
                  'items': {
                    'type':'object','additionalProperties':false,
                    'properties': {
                      'player': {'type':'string'},
                      'team': {'type':'string'},
                      'status': {'type':'string','enum':['out','doubtful','available','unclear']},
                      'importance': {'type':'string','enum':['high','medium','low','unknown']},
                      'evidence': {'type':'string'}
                    },
                    'required':['player','team','status','importance','evidence']
                  }
                },
                'contextPoints': {'type':'array','items':{'type':'string'}},
                'summary': {'type':'string'},
                'sourceUrls': {'type':'array','items':{'type':'string'}}
              },
              'required':['verificationStatus','contextEffect','suggestedTrustAdjustment','lineupStatus','injuries','contextPoints','summary','sourceUrls']
            }
          }
        }
      };

      final response = await _client.post(
        Uri.parse('https://api.openai.com/v1/responses'),
        headers: {'Authorization':'Bearer $apiKey','Content-Type':'application/json'},
        body: jsonEncode(body),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('OpenAI HTTP ${response.statusCode}: ${response.body}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw StateError('Ungültige OpenAI-Antwort.');
      final responseMap=Map<String,Object?>.from(decoded);
      final context=jsonDecode(_extractOutputText(responseMap));
      if (context is! Map) throw StateError('OpenAI lieferte kein JSON-Objekt.');
      final result=<String,Object?>{
        'fixtureId':fixtureId,
        'status':responseMap['status']?.toString() ?? 'unknown',
        'responseId':responseMap['id']?.toString(),
        'model':responseMap['model']?.toString() ?? model,
        'checkedAt':DateTime.now().toUtc().toIso8601String(),
        'context':Map<String,Object?>.from(context),
        'engineRule':'OpenAI bestätigt Kontext; die Engine berechnet Wahrscheinlichkeiten.'
      };
      await database.saveFootballAiContextCheck(
        phaseTwoScanRunId:phaseTwoScanRunId,
        fixtureId:fixtureId,
        model:model,
        responseId:result['responseId']?.toString(),
        status:result['status']?.toString() ?? 'unknown',
        contextResult:result,
      );
      results.add(result);
    }
    return {'status':'completed','phaseTwoScanRunId':phaseTwoScanRunId,'model':model,'processed':results.length,'results':results};
  }

  String _extractOutputText(Map<String,Object?> response) {
    final output=response['output'];
    if (output is! List) throw StateError('OpenAI-Ausgabe fehlt.');
    for (final itemRaw in output) {
      if (itemRaw is! Map) continue;
      final item=Map<String,Object?>.from(itemRaw);
      if (item['type']!='message') continue;
      final content=item['content'];
      if (content is! List) continue;
      for (final partRaw in content) {
        if (partRaw is! Map) continue;
        final part=Map<String,Object?>.from(partRaw);
        if (part['type']=='output_text') {
          final text=part['text']?.toString();
          if (text!=null && text.trim().isNotEmpty) return text;
        }
      }
    }
    throw StateError('Kein output_text gefunden.');
  }

  Map<String,Object?> _map(Object? value) => value is Map ? Map<String,Object?>.from(value) : <String,Object?>{};
}
