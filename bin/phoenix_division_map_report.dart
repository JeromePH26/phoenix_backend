import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/division_map.dart';
import 'package:phoenix_backend/src/model_lab/team_name_resolver.dart';
import 'package:postgres/postgres.dart';

/// Verifiziert `kDivisionHints` (lib/src/model_lab/division_map.dart) gegen
/// `football_leagues` und meldet je Divisionscode: aufgelöst (verifizierte
/// geratene ID), aufgelöst (Land+Stufe+Name-Fallback) oder NICHT AUFGELÖST.
///
/// Standardmäßig DRY RUN. Mit `--write` wird das Ergebnis in
/// `football_division_map` persistiert (nur die aufgelösten Codes; nichts
/// wird geraten).
///
///   dart run bin/phoenix_division_map_report.dart
///   dart run bin/phoenix_division_map_report.dart --write
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

    var viaGuessed = 0;
    var viaFallback = 0;
    var unresolved = 0;

    for (final hint in kDivisionHints) {
      final result = await _resolve(db, hint);
      if (result == null) {
        unresolved++;
        stdout.writeln('${hint.division.padRight(5)} NICHT AUFGELÖST  '
            '(${hint.country}, Stufe ${hint.tier ?? "-"}, "${hint.nameKeyword}")');
        continue;
      }
      final (leagueId, leagueName, source, confidence) = result;
      if (source == 'guessed_verified') {
        viaGuessed++;
      } else {
        viaFallback++;
      }
      stdout.writeln('${hint.division.padRight(5)} -> $leagueId  '
          '"$leagueName"  [$source, conf ${confidence.toStringAsFixed(2)}]');

      if (write) {
        await db.execute(
          Sql.named('''
            INSERT INTO football_division_map
              (division, league_id, country, tier, name_keyword, source,
               confidence, reviewed_at)
            VALUES (@div, @lid, @country, @tier, @kw, @src, @conf, NOW())
            ON CONFLICT (division) DO UPDATE
            SET league_id = EXCLUDED.league_id, country = EXCLUDED.country,
                tier = EXCLUDED.tier, name_keyword = EXCLUDED.name_keyword,
                source = EXCLUDED.source, confidence = EXCLUDED.confidence,
                reviewed_at = NOW()
          '''),
          parameters: {
            'div': hint.division,
            'lid': leagueId,
            'country': hint.country,
            'tier': hint.tier,
            'kw': hint.nameKeyword,
            'src': source,
            'conf': confidence,
          },
        );
      }
    }

    stdout.writeln('\n== Zusammenfassung ==');
    stdout.writeln('Codes gesamt:            ${kDivisionHints.length}');
    stdout.writeln('Verifizierte geratene ID: $viaGuessed');
    stdout.writeln('Land+Stufe+Name-Fallback: $viaFallback');
    stdout.writeln('Nicht aufgelöst:          $unresolved');
    stdout.writeln(write
        ? '\nfootball_division_map befüllt.'
        : '\nDRY RUN - nichts geschrieben. Mit --write persistieren.');
  } finally {
    await database.close();
  }
}

Future<(String, String, String, double)?> _resolve(
    Connection db, DivisionHint hint) async {
  if (hint.guessedLeagueId != null) {
    final rows = await db.execute(
      Sql.named(
          'SELECT league_id, league_name, country FROM football_leagues WHERE league_id = @id'),
      parameters: {'id': hint.guessedLeagueId.toString()},
    );
    if (rows.isNotEmpty) {
      final country = (rows.first[2] as String?) ?? '';
      final name = (rows.first[1] as String?) ?? '';
      final countryOk =
          country.toLowerCase().contains(hint.country.toLowerCase()) ||
              hint.country.toLowerCase().contains(country.toLowerCase());
      if (countryOk &&
          TeamNameResolver.leagueNamePlausible(name, hint.nameKeyword)) {
        return (rows.first[0] as String, name, 'guessed_verified', 0.95);
      }
    }
  }

  final rows = await db.execute(
    Sql.named('''
      SELECT league_id, league_name FROM football_leagues
      WHERE country ILIKE @country
        AND (@tier::int IS NULL OR competition_level = @tier)
        AND league_name ILIKE @nameLike
      LIMIT 1
    '''),
    parameters: {
      'country': '%${hint.country}%',
      'tier': hint.tier,
      'nameLike': '%${hint.nameKeyword}%',
    },
  );
  if (rows.isNotEmpty) {
    return (
      rows.first[0] as String,
      (rows.first[1] as String?) ?? '',
      'country_tier_name',
      0.80,
    );
  }
  return null;
}
