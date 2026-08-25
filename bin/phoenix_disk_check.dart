import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';

Future<void> main() async {
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  try {
    final db = await database.connection();

    final dbSize = await db.execute("SELECT pg_size_pretty(pg_database_size(current_database()))");
    stdout.writeln('DB-Größe (laut Postgres): ${dbSize.first[0]}');

    final diskFree = await db.execute('''
      SELECT pg_size_pretty(pg_total_relation_size(c.oid)) AS size, relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind IN ('r','i')
      ORDER BY pg_total_relation_size(c.oid) DESC
      LIMIT 20
    ''');
    stdout.writeln('\nGrößte Tabellen/Indizes:');
    for (final row in diskFree) {
      stdout.writeln('${row[0]}\t${row[1]}');
    }

    try {
      final settings = await db.execute("SHOW data_directory");
      stdout.writeln('\ndata_directory: ${settings.first[0]}');
    } catch (e) {
      stdout.writeln('\nSHOW data_directory fehlgeschlagen: $e');
    }

    try {
      final walSize = await db.execute(
        "SELECT pg_size_pretty(sum(size)) FROM pg_ls_waldir()",
      );
      stdout.writeln('WAL-Verzeichnis-Größe: ${walSize.first[0]}');
    } catch (e) {
      stdout.writeln('WAL-Größenabfrage fehlgeschlagen (evtl. keine Berechtigung): $e');
    }
  } finally {
    await database.close();
  }
}
