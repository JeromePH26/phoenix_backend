import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';

Future<void> main() async {
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  try {
    await database.migrate();
    final db = await database.connection();
    final rows = await db.execute('''
      SELECT division, count(*) FROM historical_twin_matches GROUP BY division ORDER BY division
    ''');
    for (final row in rows) {
      stdout.writeln('${row[0]}\t${row[1]}');
    }
  } finally {
    await database.close();
  }
}
