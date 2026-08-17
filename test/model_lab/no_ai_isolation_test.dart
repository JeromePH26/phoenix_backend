import 'dart:io';

import 'package:test/test.dart';

/// Section 86, Test 3 (No AI Calls Test) und Test 17 (Historical Twins
/// Isolation Test): strukturelle Prüfung des tatsächlichen Model-Lab-
/// Quellcodes, statt sich nur auf Konvention zu verlassen. Sucht NICHT nach
/// dem Wort "Gemini" (das taucht bewusst in vielen erklärenden Kommentaren
/// dieses Moduls auf, z.B. "kein Gemini"), sondern nach konkreten,
/// funktionsfähigen Verweisen: Imports der bekannten (toten)
/// KI-Service-Dateien, Instanziierung ihrer Klassen, oder rohe
/// LLM-API-Endpunkte.
void main() {
  final modelLabFiles = [
    ..._dartFilesIn('lib/src/model_lab'),
    File('lib/src/api/model_lab_routes.dart'),
    File('lib/src/config/model_lab_config.dart'),
  ].where((f) => f.existsSync()).toList();

  test('model_lab sources exist and were actually scanned', () {
    expect(modelLabFiles, isNotEmpty);
  });

  group('No AI Calls Test (Section 86 #3)', () {
    const forbiddenReferences = [
      "gemini_context_service.dart",
      "openai_context_service.dart",
      'GeminiContextService',
      'OpenAiContextService',
      'TennisGeminiContextService',
      'generativelanguage.googleapis.com',
      'api.openai.com',
      'api.anthropic.com',
    ];

    for (final file in modelLabFiles) {
      test('${file.path} does not import or call any generative AI service', () {
        final content = file.readAsStringSync();
        for (final forbidden in forbiddenReferences) {
          expect(
            content.contains(forbidden),
            isFalse,
            reason: '${file.path} unexpectedly references "$forbidden"',
          );
        }
      });
    }
  });

  group('Historical Twins Isolation Test (Section 86 #17)', () {
    for (final file in modelLabFiles) {
      test('${file.path} never imports the Historical Twins service', () {
        final content = file.readAsStringSync();
        expect(
          content.contains('historical_twin_service.dart'),
          isFalse,
          reason: '${file.path} must never depend on Historical Twins - '
              'Twins are display-only and must have zero influence on '
              'Engine/Learning/Challenger/Champion (Section 17).',
        );
        expect(content.contains('HistoricalTwinService'), isFalse);
        expect(content.toLowerCase().contains('twinsimilarity'), isFalse);
      });
    }
  });
}

List<File> _dartFilesIn(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}
