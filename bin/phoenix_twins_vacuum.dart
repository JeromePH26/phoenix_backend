import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';

/// Routinewartung: VACUUM (nicht FULL - braucht keinen zusaetzlichen freien
/// Speicherplatz) auf historical_twin_matches, um durch die Team-Matching-
/// Updates entstandene tote Tupel fuer Wiederverwendung freizugeben, bevor
/// der naechste Batch geschrieben wird.
Future<void> main() async {
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  try {
    final db = await database.connection();
    stdout.writeln('VACUUM historical_twin_matches ...');
    await db.execute('VACUUM (VERBOSE) historical_twin_matches');
    stdout.writeln('Fertig.');

    final dbSize = await db.execute("SELECT pg_size_pretty(pg_database_size(current_database()))");
    stdout.writeln('DB-Größe danach: ${dbSize.first[0]}');
  } finally {
    await database.close();
  }
}
