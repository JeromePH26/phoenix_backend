import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';

/// READ-ONLY: wie weit sind die historischen Daten an unsere Liga-/Team-
/// Dimension angebunden. Nach `phoenix_teams_backfill.dart --write`,
/// `phoenix_division_map_report.dart --write`,
/// `phoenix_twins_match_teams.dart --write` und
/// `phoenix_elo_match_teams.dart --write` ausführen.
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

    await section('football_teams / aliases', '''
      SELECT
        (SELECT count(*) FROM football_teams) AS teams,
        (SELECT count(*) FROM football_team_aliases) AS aliases,
        (SELECT count(DISTINCT source) FROM football_team_aliases) AS alias_sources,
        (SELECT count(*) FROM football_division_map WHERE league_id IS NOT NULL) AS divisions_mapped
    ''');

    await section('historical_twin_matches – Anbindung', '''
      SELECT
        count(*) AS total,
        count(*) FILTER (WHERE matched_league_id IS NOT NULL) AS league_linked,
        count(*) FILTER (WHERE matched_home_team_id IS NOT NULL
                           AND matched_away_team_id IS NOT NULL) AS both_teams_linked,
        count(*) FILTER (WHERE matched_league_id IS NOT NULL
                           AND matched_home_team_id IS NOT NULL
                           AND matched_away_team_id IS NOT NULL
                           AND home_goals IS NOT NULL
                           AND away_goals IS NOT NULL) AS usable_for_learning,
        round(100.0 * count(*) FILTER (WHERE matched_league_id IS NOT NULL
                           AND matched_home_team_id IS NOT NULL
                           AND matched_away_team_id IS NOT NULL) / NULLIF(count(*),0), 1) AS pct_both_teams
      FROM historical_twin_matches
    ''');

    await section('historical_twin_matches – nach Division (Top 25 verknüpft)', '''
      SELECT division,
             count(*) AS rows,
             count(*) FILTER (WHERE matched_home_team_id IS NOT NULL
                                AND matched_away_team_id IS NOT NULL) AS both_teams,
             min(match_date) AS from_date,
             max(match_date) AS to_date
      FROM historical_twin_matches
      GROUP BY division
      ORDER BY both_teams DESC
      LIMIT 25
    ''');

    await section('historical_elo_ratings – Anbindung', '''
      SELECT
        count(*) AS rows,
        count(DISTINCT club) AS clubs,
        count(*) FILTER (WHERE matched_team_id IS NOT NULL) AS rows_linked,
        count(DISTINCT club) FILTER (WHERE matched_team_id IS NOT NULL) AS clubs_linked
      FROM historical_elo_ratings
    ''');

    await section('Elo-Skala: Twin home_elo vs. historical_elo_ratings (Überlapp)', '''
      WITH overlap AS (
        SELECT t.home_elo AS twin_elo, e.elo AS series_elo
        FROM historical_twin_matches t
        JOIN historical_elo_ratings e
          ON e.matched_team_id = t.matched_home_team_id
         AND e.rating_date = (
              SELECT max(rating_date) FROM historical_elo_ratings e2
              WHERE e2.matched_team_id = t.matched_home_team_id
                AND e2.rating_date <= t.match_date)
        WHERE t.home_elo IS NOT NULL AND t.matched_home_team_id IS NOT NULL
        LIMIT 20000
      )
      SELECT count(*) AS pairs,
             round(avg(twin_elo)::numeric, 1) AS avg_twin,
             round(avg(series_elo)::numeric, 1) AS avg_series,
             round(avg(twin_elo - series_elo)::numeric, 1) AS avg_diff,
             round(corr(twin_elo, series_elo)::numeric, 3) AS correlation
      FROM overlap
    ''');

    stdout.writeln('\n== FERTIG (read-only) ==');
  } finally {
    await database.close();
  }
}
