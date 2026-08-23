import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';

/// READ-ONLY Status-Check: kein INSERT/UPDATE/DELETE außer dem additiven
/// `database.migrate()` (identisch sicher wie jeder andere Boot-Pfad).
/// Beantwortet "wie schaut es aus mit dem Learning" mit echten Zahlen aus
/// der Produktions-DB statt Vermutungen.
Future<void> main() async {
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  if (databaseUrl.isEmpty) {
    stderr.writeln('DATABASE_URL/DATABASE_PUBLIC_URL fehlt.');
    exitCode = 1;
    return;
  }

  final database = PhoenixDatabase(databaseUrl);

  try {
    await database.migrate();
    final db = await database.connection();

    stdout.writeln('== Letzte 10 Learning Runs ==');
    final runs = await db.execute('''
      SELECT id, trigger_type, status, current_step, started_at, completed_at,
             challengers_created, markets_processed, leagues_processed
      FROM phoenix_learning_runs
      ORDER BY started_at DESC
      LIMIT 10
    ''');
    for (final row in runs) {
      stdout.writeln(
          '#${row[0]} | ${row[1]} | ${row[2]} (${row[3]}) | started ${row[4]} | completed ${row[5]} | challengers=${row[6]} markets=${row[7]} leagues=${row[8]}');
    }

    stdout.writeln('\n== Aktuell laufender Run? ==');
    final running = await db.execute('''
      SELECT id, started_at, current_step FROM phoenix_learning_runs WHERE status = 'running'
    ''');
    if (running.isEmpty) {
      stdout.writeln('Kein Run aktuell "running".');
    } else {
      for (final row in running) {
        stdout.writeln('LÄUFT: #${row[0]} seit ${row[1]} (Schritt: ${row[2]})');
      }
    }

    stdout.writeln('\n== Globale Champions pro Markt ==');
    final champions = await db.execute('''
      SELECT market, id, readable_version, model_type, training_count,
             validation_count, holdout_count, champion_since,
             (weights->>'engineVersion') AS engine_version
      FROM phoenix_model_versions
      WHERE league_id IS NULL AND status = 'champion'
      ORDER BY market
    ''');
    for (final row in champions) {
      stdout.writeln(
          '${row[0]}: #${row[1]} ${row[2]} | type=${row[3]} | train=${row[4]} val=${row[5]} holdout=${row[6]} | champion_since=${row[7]} | engine=${row[8] ?? "attackWeight"}');
    }

    stdout.writeln('\n== Offene Challenger (nicht champion/retired/rejected) ==');
    final pending = await db.execute('''
      SELECT market, count(*) FROM phoenix_model_versions
      WHERE status = 'challenger'
      GROUP BY market ORDER BY market
    ''');
    for (final row in pending) {
      stdout.writeln('${row[0]}: ${row[1]} Challenger');
    }

    stdout.writeln('\n== Learning Samples pro Liga (Top 15, letzte 30 Tage Aktivität) ==');
    final ligas = await db.execute('''
      SELECT league_id, count(*) AS n
      FROM phoenix_learning_candidates
      WHERE created_at > now() - interval '30 days'
      GROUP BY league_id ORDER BY n DESC LIMIT 15
    ''');
    for (final row in ligas) {
      stdout.writeln('${row[0]}: ${row[1]} Kandidaten (30 Tage)');
    }

    stdout.writeln('\n== Monatliche Reviews (letzte 5) ==');
    final reviews = await db.execute('''
      SELECT id, market, league_id, recommendation, reviewed_at
      FROM phoenix_monthly_reviews
      ORDER BY reviewed_at DESC LIMIT 5
    ''');
    if (reviews.isEmpty) {
      stdout.writeln('Noch keine monatlichen Reviews.');
    }
    for (final row in reviews) {
      stdout.writeln('#${row[0]} ${row[1]} / league=${row[2]} | ${row[3]} | ${row[4]}');
    }
  } finally {
    await database.close();
  }
}
