import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/team_name_resolver.dart';
import 'package:postgres/postgres.dart';

/// Bindet die verwaiste `historical_elo_ratings`-Zeitreihe (nur `club`-Name
/// + 3-Buchstaben-Land) an die Team-Dimension: setzt `matched_team_id` /
/// `match_confidence` über `football_team_aliases`.
///
/// Voraussetzung: `bin/phoenix_teams_backfill.dart --write` (Selbst-Aliase)
/// und/oder `bin/phoenix_twins_match_teams.dart --write` (Twin-Aliase)
/// liefen bereits.
///
/// Standardmäßig DRY RUN. Mit `--write` werden die Spalten gesetzt.
///
///   dart run bin/phoenix_elo_match_teams.dart
///   dart run bin/phoenix_elo_match_teams.dart --write
Future<void> main(List<String> args) async {
  final write = args.contains('--write');
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  try {
    await database.migrate();
    final db = await database.connection();

    // Alle bekannten Aliase in eine Map alias_norm -> team_id, mit Priorität
    // football_matches > twins > manual (ein Norm kann quellenübergreifend
    // auf verschiedene team_ids zeigen).
    const sourceRank = {'football_matches': 0, 'twins': 1, 'manual': 2, 'elo': 3};
    final aliasRows = await db.execute(
        'SELECT alias_norm, team_id, source FROM football_team_aliases');
    final aliasMap = <String, ({String teamId, int rank})>{};
    for (final row in aliasRows) {
      final norm = row[0] as String;
      final teamId = row[1] as String;
      final rank = sourceRank[row[2] as String] ?? 9;
      final existing = aliasMap[norm];
      if (existing == null || rank < existing.rank) {
        aliasMap[norm] = (teamId: teamId, rank: rank);
      }
    }
    final candidates = {
      for (final e in aliasMap.entries) e.key: e.value.teamId,
    };
    stdout.writeln('Alias-Kandidaten: ${candidates.length}');

    final clubRows = await db.execute(
        'SELECT DISTINCT club FROM historical_elo_ratings');
    var matched = 0;
    var ambiguous = 0;
    var noMatch = 0;
    final resolved = <String, String>{}; // club -> team_id
    final samples = <String>[];

    for (final row in clubRows) {
      final club = row[0] as String;
      final r = TeamMatchResult();
      final teamId = TeamNameResolver.bestMatch(club, candidates, result: r);
      switch (r.status) {
        case TeamMatchStatus.matched:
          resolved[club] = teamId!;
          matched++;
          if (samples.length < 10) {
            samples.add('"$club" -> $teamId (${(r.bestScore * 100).round()}%)');
          }
        case TeamMatchStatus.ambiguous:
          ambiguous++;
        case TeamMatchStatus.noMatch:
          noMatch++;
      }
    }

    stdout.writeln('\nDistinkte Clubs in historical_elo_ratings: ${clubRows.length}');
    stdout.writeln('  gematcht:    $matched');
    stdout.writeln('  mehrdeutig:  $ambiguous');
    stdout.writeln('  kein Treffer: $noMatch');
    for (final s in samples) {
      stdout.writeln('   $s');
    }

    if (write && resolved.isNotEmpty) {
      var rowsWritten = 0;
      final entries = resolved.entries.toList();
      const batchSize = 500;
      for (var start = 0; start < entries.length; start += batchSize) {
        final end = start + batchSize < entries.length
            ? start + batchSize
            : entries.length;
        final valueClauses = <String>[];
        final params = <String, Object?>{
          'conf': TeamNameResolver.matchThreshold,
        };
        for (var i = start; i < end; i++) {
          final j = i - start;
          valueClauses.add('(@club$j::text, @team$j::text)');
          params['club$j'] = entries[i].key;
          params['team$j'] = entries[i].value;
        }
        final res = await db.execute(
          Sql.named('''
            UPDATE historical_elo_ratings AS e
            SET matched_team_id = v.team, match_confidence = @conf
            FROM (VALUES ${valueClauses.join(', ')}) AS v(club, team)
            WHERE e.club = v.club
          '''),
          parameters: params,
        );
        rowsWritten += res.affectedRows;
      }
      stdout.writeln('\n$rowsWritten Elo-Zeilen mit matched_team_id versehen.');
    } else {
      stdout.writeln(write
          ? '\nNichts zu schreiben.'
          : '\nDRY RUN - nichts geschrieben. Mit --write erneut ausführen.');
    }
  } finally {
    await database.close();
  }
}
