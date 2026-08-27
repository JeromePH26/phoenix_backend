import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/team_name_resolver.dart';

/// Befüllt die persistente Team-Dimension (`football_teams` +
/// `football_team_aliases` mit Quelle `football_matches`) aus den bisher nur
/// verstreut in `football_matches` liegenden `(team_id, name)`-Paaren.
///
/// Standardmäßig DRY RUN. Mit `--write` werden `football_teams` und die
/// Selbst-Alias-Zeilen tatsächlich geschrieben (idempotent, additiv).
///
///   dart run bin/phoenix_teams_backfill.dart
///   dart run bin/phoenix_teams_backfill.dart --write
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

    final rows = await db.execute('''
      SELECT id, name, country FROM (
        SELECT home_team_id AS id, home_team_name AS name, country
          FROM football_matches
        UNION ALL
        SELECT away_team_id, away_team_name, country
          FROM football_matches
      ) x
      WHERE id IS NOT NULL AND id <> '' AND name IS NOT NULL AND name <> ''
    ''');

    // Pro team_id den am häufigsten vorkommenden Namen als canonical wählen.
    final nameCounts = <String, Map<String, int>>{};
    final country = <String, String>{};
    for (final row in rows) {
      final id = row[0] as String;
      final name = row[1] as String;
      final c = (row[2] as String?)?.trim() ?? '';
      (nameCounts[id] ??= <String, int>{}).update(name, (v) => v + 1,
          ifAbsent: () => 1);
      if (c.isNotEmpty) country.putIfAbsent(id, () => c);
    }

    var teamsWritten = 0;
    var aliasesWritten = 0;
    final aliasBatch =
        <({String aliasNorm, String teamId, double confidence})>[];

    for (final entry in nameCounts.entries) {
      final teamId = entry.key;
      final canonical = entry.value.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;
      if (write) {
        await database.upsertFootballTeam(
          teamId: teamId,
          canonicalName: canonical,
          country: country[teamId] ?? '',
        );
      }
      teamsWritten++;
      // Ein Selbst-Alias pro beobachteter Namensvariante.
      for (final name in entry.value.keys) {
        final norm = TeamNameResolver.normalize(name);
        if (norm.isEmpty) continue;
        aliasBatch.add((aliasNorm: norm, teamId: teamId, confidence: 1.0));
      }
    }

    if (write && aliasBatch.isNotEmpty) {
      aliasesWritten = await database.upsertTeamAliases(
        aliasBatch,
        source: 'football_matches',
      );
    } else {
      aliasesWritten = aliasBatch.length;
    }

    stdout.writeln('== football_teams-Backfill ==');
    stdout.writeln('Distinkte team_ids: $teamsWritten');
    stdout.writeln('Selbst-Alias-Zeilen: $aliasesWritten');
    stdout.writeln(write
        ? 'Geschrieben.'
        : 'DRY RUN - nichts geschrieben. Mit --write erneut ausführen.');
  } finally {
    await database.close();
  }
}
