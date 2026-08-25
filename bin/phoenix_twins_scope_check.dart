import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';
import 'package:postgres/postgres.dart';

/// READ-ONLY: Scope-Check vor dem eigentlichen Team-Matching - wie viele der
/// 68k Historical-Twin-Spiele koennten ueberhaupt zu einer Liga passen, fuer
/// die wir selbst schon Team-Namen (aus football_matches) gespeichert haben?
Future<void> main() async {
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  try {
    await database.migrate();
    final db = await database.connection();

    stdout.writeln('== Unsere football_leagues (Anzahl je Land) ==');
    final leaguesByCountry = await db.execute('''
      SELECT country, count(*) FROM football_leagues GROUP BY country ORDER BY count(*) DESC LIMIT 30
    ''');
    for (final row in leaguesByCountry) {
      stdout.writeln('${row[0]}: ${row[1]} Ligen');
    }

    stdout.writeln('\n== Ligen mit gespeicherten football_matches (Anzahl Teams via distinct Namen) ==');
    final leaguesWithMatches = await db.execute('''
      SELECT l.league_id, l.league_name, l.country, l.competition_level,
        (SELECT count(DISTINCT t) FROM (
          SELECT home_team_name AS t FROM football_matches WHERE league_id = l.league_id
          UNION
          SELECT away_team_name FROM football_matches WHERE league_id = l.league_id
        ) x) AS team_count,
        (SELECT count(*) FROM football_matches m WHERE m.league_id = l.league_id) AS match_count
      FROM football_leagues l
      ORDER BY match_count DESC
      LIMIT 40
    ''');
    for (final row in leaguesWithMatches) {
      stdout.writeln('${row[0]} | ${row[1]} (${row[2]}, Stufe ${row[3]}) | teams=${row[4]} matches=${row[5]}');
    }

    stdout.writeln('\n== Gesamtzahl Ligen mit >=1 gespeichertem Match ==');
    final total = await db.execute('''
      SELECT count(DISTINCT league_id) FROM football_matches
    ''');
    stdout.writeln('Ligen mit Matches: ${total.first[0]}');

    stdout.writeln('\n== Beispiel: englische Top-Liga - unsere Teamnamen ==');
    final engExample = await db.execute('''
      SELECT l.league_id, l.league_name FROM football_leagues l
      WHERE l.country ILIKE '%england%' AND l.competition_level = 1
      LIMIT 5
    ''');
    for (final row in engExample) {
      stdout.writeln('${row[0]}: ${row[1]}');
      final teams = await db.execute(
        Sql.named('''
        SELECT DISTINCT t FROM (
          SELECT home_team_name AS t FROM football_matches WHERE league_id = @lid
          UNION
          SELECT away_team_name FROM football_matches WHERE league_id = @lid
        ) x ORDER BY t LIMIT 25
      '''),
        parameters: {'lid': row[0]},
      );
      for (final t in teams) {
        stdout.writeln('  - ${t[0]}');
      }
    }
  } finally {
    await database.close();
  }
}
