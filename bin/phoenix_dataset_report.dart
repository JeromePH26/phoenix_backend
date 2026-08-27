import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';

/// READ-ONLY: Verteilung in `phoenix_learning_dataset` (nach
/// `bin/phoenix_classify_dataset.dart --write` ausführen).
Future<void> main() async {
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  try {
    await database.migrate();
    final db = await database.connection();

    Future<void> section(String title, String sql) async {
      stdout.writeln('\n== $title ==');
      for (final row in await db.execute(sql)) {
        stdout.writeln(row.map((v) => '$v').join(' | '));
      }
    }

    await section('Datenklassen x Quelle (distinkte Fixtures)', '''
      SELECT source, data_class, count(DISTINCT fixture_id) AS fixtures,
             count(*) AS rows
      FROM phoenix_learning_dataset
      GROUP BY source, data_class
      ORDER BY source, data_class
    ''');

    await section('Ausschlussgründe (distinkte Fixtures)', '''
      SELECT COALESCE(excluded_reason, '(keiner)') AS reason,
             count(DISTINCT fixture_id) AS fixtures
      FROM phoenix_learning_dataset
      GROUP BY excluded_reason
      ORDER BY fixtures DESC
    ''');

    await section('Leakage-Ergebnis', '''
      SELECT COALESCE(leakage_result, '(null)') AS leakage,
             count(DISTINCT fixture_id) AS fixtures
      FROM phoenix_learning_dataset
      GROUP BY leakage_result
      ORDER BY fixtures DESC
    ''');

    await section('learning/production pro Monat (Kickoff, distinkte Fixtures)', '''
      SELECT to_char(date_trunc('month', kickoff), 'YYYY-MM') AS monat,
             count(DISTINCT fixture_id) FILTER (WHERE data_class = 'learning') AS learning,
             count(DISTINCT fixture_id) FILTER (WHERE data_class = 'production') AS production
      FROM phoenix_learning_dataset
      WHERE kickoff IS NOT NULL
      GROUP BY 1 ORDER BY 1
    ''');

    await section('Top-Ligen im learning-Pool', '''
      SELECT d.league_id, l.league_name,
             count(DISTINCT d.fixture_id) AS learning_fixtures
      FROM phoenix_learning_dataset d
      LEFT JOIN football_leagues l ON l.league_id = d.league_id
      WHERE d.data_class = 'learning'
      GROUP BY d.league_id, l.league_name
      ORDER BY learning_fixtures DESC
      LIMIT 20
    ''');

    stdout.writeln('\n== FERTIG (read-only) ==');
  } finally {
    await database.close();
  }
}
