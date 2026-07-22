import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class TennisGeminiContextService {
  TennisGeminiContextService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  String get apiKey => Platform.environment['GEMINI_API_KEY'] ?? '';
  String get model => Platform.environment['GEMINI_MODEL'] ?? 'gemini-3.5-flash';

  Future<Map<String, Object?>> analyze({
    required String playerA,
    required String playerB,
    required String tournament,
    required String surface,
    required DateTime startTime,
    Map<String, Object?> structuredFatigue = const {},
  }) async {
    if (apiKey.trim().isEmpty) return _disabled('GEMINI_API_KEY fehlt.');

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
    );

    try {
      final response = await _client.post(
        uri,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': _prompt(playerA, playerB, tournament, surface, startTime, structuredFatigue)}
              ]
            }
          ],
          'tools': [
            {'google_search': {}}
          ],
          'generationConfig': {
            'temperature': 0.1,
            'responseMimeType': 'application/json',
          },
        }),
      ).timeout(const Duration(seconds: 45));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _disabled('Gemini HTTP ${response.statusCode}');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return _disabled('Ungültige Gemini-Antwort.');
      final text = _extractText(Map<String, Object?>.from(decoded));
      if (text.isEmpty) return _disabled('Gemini lieferte kein JSON.');
      final payload = jsonDecode(text);
      if (payload is! Map) return _disabled('Gemini-JSON ungültig.');
      return _validate(Map<String, Object?>.from(payload));
    } catch (error) {
      return _disabled(error.toString());
    }
  }

  Map<String, Object?> _validate(Map<String, Object?> json) {
    final reliability = _int(json['reliability']).clamp(0, 100);
    final facts = <Map<String, Object?>>[];
    final rawFacts = json['facts'];

    if (rawFacts is List) {
      for (final raw in rawFacts.whereType<Map>()) {
        final fact = Map<String, Object?>.from(raw);
        final sourceClass = (fact['sourceClass']?.toString() ?? '').toUpperCase();
        final sourceUrl = fact['sourceUrl']?.toString().trim() ?? '';
        final publishedAt = DateTime.tryParse(fact['publishedAt']?.toString() ?? '');
        final confidence = _int(fact['confidence']).clamp(0, 100);
        if (const {'A', 'B', 'C'}.contains(sourceClass) &&
            sourceUrl.isNotEmpty &&
            publishedAt != null &&
            confidence >= 70) {
          facts.add({
            ...fact,
            'sourceClass': sourceClass,
            'sourceUrl': sourceUrl,
            'publishedAt': publishedAt.toUtc().toIso8601String(),
            'confidence': confidence,
          });
        }
      }
    }

    if (reliability < 70 || facts.isEmpty) {
      return _disabled('Keine ausreichend verifizierten Fakten.');
    }

    final modifierA = _modifier(json['eventsA'], reliability, facts);
    final modifierB = _modifier(json['eventsB'], reliability, facts);

    return {
      'model': model,
      'applied': modifierA != 0 || modifierB != 0,
      'reliability': reliability,
      'modifierA': modifierA,
      'modifierB': modifierB,
      'reasoning': _short(json['reasoning']),
      'facts': facts,
    };
  }

  double _modifier(Object? rawEvents, int reliability, List<Map<String, Object?>> facts) {
    if (rawEvents is! List) return 0;
    var total = 0.0;
    for (final raw in rawEvents) {
      total += switch (raw.toString().trim().toLowerCase()) {
        'long_match_with_rest' => -0.005,
        'long_match_previous_day' => -0.015,
        'over_3h_under_20h_rest' => -0.025,
        'medical_timeout_last_match' => -0.020,
        'confirmed_minor_limitation' => -0.030,
        'confirmed_relevant_injury' => -0.050,
        'positive_fitness_confirmation' => 0.010,
        _ => 0.0,
      };
    }
    final sourceFactor = facts.map((f) => switch (f['sourceClass']) {
      'A' => 1.0,
      'B' => 0.9,
      'C' => 0.75,
      _ => 0.0,
    }).reduce((a, b) => a + b) / facts.length;
    return (total * (reliability / 100) * sourceFactor).clamp(-0.06, 0.02).toDouble();
  }

  String _prompt(String a, String b, String tournament, String surface, DateTime start, Map<String, Object?> fatigue) => '''
Du bist die verifizierende Soft-Fact-Schicht der PHÖNIX Tennis Engine.
Suche nur belastbare Informationen der letzten 48 Stunden.
Match: $a gegen $b, $tournament, $surface, ${start.toUtc().toIso8601String()}.
Bereits strukturierte Daten, nicht doppelt werten: ${jsonEncode(fatigue)}
Zulässig: Verletzung, Medical Timeout, Krankheit, Match über 3 Stunden mit kurzer Erholung, Reisebelastung, offizielle Fitnessaussage.
Unzulässig: Gerüchte, Fanforen, alte Verletzungen ohne aktuellen Bezug, Gewinnerprognosen.
Quellen: A offiziell, B ATP/WTA/ITF/Veranstalter, C etabliertes Sportmedium, D/E nicht anwendbar.
Gib nur JSON zurück:
{"reliability":0,"eventsA":[],"eventsB":[],"reasoning":"maximal 20 Wörter","facts":[{"player":"A|B","category":"injury|fatigue|illness|fitness","fact":"kurz","publishedAt":"ISO-8601","sourceUrl":"https://...","sourceClass":"A|B|C|D|E","confidence":0}]}
Event-Codes: long_match_with_rest, long_match_previous_day, over_3h_under_20h_rest, medical_timeout_last_match, confirmed_minor_limitation, confirmed_relevant_injury, positive_fitness_confirmation, none.
''';

  String _extractText(Map<String, Object?> body) {
    final candidates = body['candidates'];
    if (candidates is! List || candidates.isEmpty || candidates.first is! Map) return '';
    final content = (candidates.first as Map)['content'];
    if (content is! Map || content['parts'] is! List) return '';
    for (final part in (content['parts'] as List).whereType<Map>()) {
      final text = part['text']?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  String _short(Object? value) =>
      (value?.toString().trim().split(RegExp(r'\s+')) ?? const []).take(20).join(' ');

  int _int(Object? value) => value is int
      ? value
      : value is num
          ? value.round()
          : int.tryParse(value?.toString() ?? '') ?? 0;

  Map<String, Object?> _disabled(String reason) => {
        'model': model,
        'applied': false,
        'reliability': 0,
        'modifierA': 0.0,
        'modifierB': 0.0,
        'reasoning': reason,
        'facts': const <Map<String, Object?>>[],
      };

  void close() => _client.close();
}
