import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';

/// Testet vorsichtig, ob überhaupt noch irgendein Schreibvorgang (auch ein
/// kleiner DELETE) möglich ist, bevor eine größere Aufräumaktion versucht
/// wird - ein fehlgeschlagener Test kostet nichts (Transaktion rollt zurück).
Future<void> main() async {
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  try {
    final db = await database.connection();

    stdout.writeln('Test 1: sehr kleines DELETE (0 Zeilen betroffen, WHERE false) ...');
    try {
      await db.execute("DELETE FROM historical_elo_ratings WHERE club = '__nonexistent_probe__'");
      stdout.writeln('  OK - kleine Schreiboperation funktioniert.');
    } catch (e) {
      stdout.writeln('  FEHLGESCHLAGEN: $e');
    }

    stdout.writeln('\nTest 2: DELETE von 100 echten Zeilen aus historical_elo_ratings (ältestes Datum zuerst) ...');
    try {
      final result = await db.execute('''
        DELETE FROM historical_elo_ratings
        WHERE id IN (SELECT id FROM historical_elo_ratings ORDER BY rating_date ASC LIMIT 100)
      ''');
      stdout.writeln('  OK - ${result.affectedRows} Zeilen gelöscht.');
    } catch (e) {
      stdout.writeln('  FEHLGESCHLAGEN: $e');
    }

    final dbSize = await db.execute("SELECT pg_size_pretty(pg_database_size(current_database()))");
    stdout.writeln('\nDB-Größe jetzt: ${dbSize.first[0]}');
  } finally {
    await database.close();
  }
}
