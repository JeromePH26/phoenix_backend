import 'dart:io';

import 'package:phoenix_backend/src/database/database.dart';

/// READ-ONLY Eligibility-Tiefenanalyse fuer das PHOENIX MODEL LAB.
///
/// Ergaenzt den aggregierten `/dry-run`-Audit (nur Zaehler pro Grund) um die
/// Verteilungen, die man braucht, um zu entscheiden, welche Ausschluesse
/// ueberhaupt behebbar sind:
///   - outcome_missing  -> aufgeschluesselt nach m.status
///   - timestamp_invalid -> Snapshot fehlt ganz vs. wie viele Stunden/Tage
///                          nach Anpfiff erzeugt
///   - data_quality_below_minimum -> Histogramm + wie viele bei niedrigerer
///                          Schwelle zurueckkaemen
///
/// Fuehrt AUSSER dem additiven `database.migrate()` (identisch zum
/// produktiven Boot-Pfad) KEINE Schreiboperation aus. Nur SELECTs.
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

  // Spiegelt exakt die Auswahl aus modelLabEligibilityAuditRows(): ein
  // Datensatz je Fixture, ein gueltiger Pre-Match-Snapshot geht immer vor.
  const bestSnapshotCte = '''
    WITH best AS (
      SELECT DISTINCT ON (ei.fixture_id)
        ei.fixture_id,
        ei.league_id,
        ei.data_quality,
        ei.created_at AS snapshot_created_at,
        m.kickoff_utc,
        m.status,
        m.home_goals,
        m.away_goals,
        fl.collection_tier
      FROM football_engine_inputs ei
      LEFT JOIN football_matches m ON m.id = ei.fixture_id
      LEFT JOIN football_leagues fl ON fl.league_id = ei.league_id
      ORDER BY ei.fixture_id,
        CASE
          WHEN m.kickoff_utc IS NOT NULL AND ei.created_at < m.kickoff_utc
            THEN 0 ELSE 1
        END,
        ei.created_at DESC
    ),
    scoped AS (
      SELECT * FROM best
      WHERE collection_tier IN ('focus', 'watchlist', 'data_pool')
    )
  ''';

  const finished = "('FT','AET','PEN','AWD','WO')";
  const minDq = 50; // PHOENIX_MODEL_LAB_MIN_DATA_QUALITY default

  try {
    await database.migrate();
    final db = await database.connection();

    Future<void> section(String title, String sql) async {
      stdout.writeln('\n== $title ==');
      final rows = await db.execute(bestSnapshotCte + sql);
      for (final row in rows) {
        stdout.writeln(row.map((v) => '$v').join(' | '));
      }
    }

    await section('Gesamtueberblick (Whitelist-Tiers, Fixture-Ebene)', '''
      SELECT
        count(*) AS fixtures_total,
        count(*) FILTER (WHERE kickoff_utc < now()) AS kickoff_vergangen,
        count(*) FILTER (WHERE status IN $finished
                           AND home_goals IS NOT NULL
                           AND away_goals IS NOT NULL) AS mit_ergebnis,
        count(*) FILTER (WHERE status IN $finished
                           AND home_goals IS NOT NULL
                           AND away_goals IS NOT NULL
                           AND kickoff_utc IS NOT NULL
                           AND snapshot_created_at IS NOT NULL
                           AND snapshot_created_at < kickoff_utc) AS mit_prematch_snapshot,
        count(*) FILTER (WHERE status IN $finished
                           AND home_goals IS NOT NULL
                           AND away_goals IS NOT NULL
                           AND kickoff_utc IS NOT NULL
                           AND snapshot_created_at < kickoff_utc
                           AND data_quality >= $minDq) AS eligible
      FROM scoped
    ''');

    await section('outcome_missing nach Status', '''
      SELECT
        COALESCE(status, '(null)') AS status,
        count(*) AS n,
        count(*) FILTER (WHERE kickoff_utc < now()) AS davon_kickoff_vergangen
      FROM scoped
      WHERE NOT (status IN $finished
                 AND home_goals IS NOT NULL
                 AND away_goals IS NOT NULL)
      GROUP BY status
      ORDER BY n DESC
    ''');

    await section(
        'outcome_missing: Status "beendet" aber Tore NULL (per Settlement behebbar)',
        '''
      SELECT
        COALESCE(status,'(null)') AS status,
        count(*) AS n
      FROM scoped
      WHERE status IN $finished
        AND (home_goals IS NULL OR away_goals IS NULL)
      GROUP BY status
      ORDER BY n DESC
    ''');

    await section('timestamp_invalid: Snapshot fehlt ganz vs. zu spaet', '''
      SELECT
        CASE
          WHEN snapshot_created_at IS NULL THEN 'kein snapshot'
          WHEN snapshot_created_at < kickoff_utc THEN 'ok (pre-match)'
          WHEN snapshot_created_at - kickoff_utc <= interval '1 hour' THEN 'bis 1h nach anpfiff'
          WHEN snapshot_created_at - kickoff_utc <= interval '6 hours' THEN '1-6h nach anpfiff'
          WHEN snapshot_created_at - kickoff_utc <= interval '24 hours' THEN '6-24h nach anpfiff'
          WHEN snapshot_created_at - kickoff_utc <= interval '7 days' THEN '1-7 tage nach anpfiff'
          ELSE '> 7 tage nach anpfiff'
        END AS snapshot_timing,
        count(*) AS n
      FROM scoped
      WHERE status IN $finished
        AND home_goals IS NOT NULL AND away_goals IS NOT NULL
        AND kickoff_utc IS NOT NULL
        AND (snapshot_created_at IS NULL OR snapshot_created_at >= kickoff_utc)
      GROUP BY 1
      ORDER BY n DESC
    ''');

    await section(
        'timestamp_invalid: existiert IRGENDEIN pre-match snapshot fuer diese fixtures?',
        '''
      SELECT
        count(*) AS betroffene_fixtures,
        count(*) FILTER (WHERE EXISTS (
          SELECT 1 FROM football_engine_inputs ei2
          WHERE ei2.fixture_id = s.fixture_id
            AND ei2.created_at < s.kickoff_utc
        )) AS haben_doch_einen_frueheren_prematch
      FROM scoped s
      WHERE status IN $finished
        AND home_goals IS NOT NULL AND away_goals IS NOT NULL
        AND kickoff_utc IS NOT NULL
        AND (snapshot_created_at IS NULL OR snapshot_created_at >= kickoff_utc)
    ''');

    await section('data_quality_below_minimum: Histogramm (nur sonst-eligible)',
        '''
      SELECT
        (data_quality / 10) * 10 AS dq_bucket,
        count(*) AS n
      FROM scoped
      WHERE status IN $finished
        AND home_goals IS NOT NULL AND away_goals IS NOT NULL
        AND kickoff_utc IS NOT NULL
        AND snapshot_created_at < kickoff_utc
        AND data_quality < $minDq
      GROUP BY 1
      ORDER BY 1
    ''');

    await section('data_quality: Rueckgewinn bei niedrigerer Schwelle', '''
      SELECT
        count(*) FILTER (WHERE data_quality >= 45) AS ab_45,
        count(*) FILTER (WHERE data_quality >= 40) AS ab_40,
        count(*) FILTER (WHERE data_quality >= 30) AS ab_30,
        count(*) FILTER (WHERE data_quality >= 25) AS ab_25,
        count(*) FILTER (WHERE data_quality >= 20) AS ab_20,
        count(*) AS aktuell_eligible_ab_50
      FROM scoped
      WHERE status IN $finished
        AND home_goals IS NOT NULL AND away_goals IS NOT NULL
        AND kickoff_utc IS NOT NULL
        AND snapshot_created_at < kickoff_utc
    ''');

    await section('Eligible-Spiele pro Tier', '''
      SELECT collection_tier, count(*) AS eligible
      FROM scoped
      WHERE status IN $finished
        AND home_goals IS NOT NULL AND away_goals IS NOT NULL
        AND kickoff_utc IS NOT NULL
        AND snapshot_created_at < kickoff_utc
        AND data_quality >= $minDq
      GROUP BY collection_tier
      ORDER BY eligible DESC
    ''');

    await section('Eligible-Spiele pro Monat (Kickoff)', '''
      SELECT to_char(date_trunc('month', kickoff_utc), 'YYYY-MM') AS monat,
             count(*) AS eligible
      FROM scoped
      WHERE status IN $finished
        AND home_goals IS NOT NULL AND away_goals IS NOT NULL
        AND kickoff_utc IS NOT NULL
        AND snapshot_created_at < kickoff_utc
        AND data_quality >= $minDq
      GROUP BY 1
      ORDER BY 1
    ''');

    stdout.writeln('\n== Settlement-Kandidaten: alt (nur phaseTwo) vs. neu (+ engine_inputs) ==');
    final settleCmp = await db.execute('''
      SELECT
        count(*) FILTER (
          WHERE raw_json ? 'phaseTwo'
        ) AS alt_nur_phasetwo,
        count(*) FILTER (
          WHERE raw_json ? 'phaseTwo'
             OR EXISTS (SELECT 1 FROM football_engine_inputs ei
                        WHERE ei.fixture_id = football_matches.id)
        ) AS neu_inkl_engine_inputs
      FROM football_matches
      WHERE id <> ''
        AND kickoff_utc <= NOW() - make_interval(hours => 3)
        AND status NOT IN ('FT','AET','PEN','AWD','WO','CANC','ABD')
    ''');
    for (final row in settleCmp) {
      stdout.writeln(row.map((v) => '$v').join(' | '));
    }

    stdout.writeln('\n== FERTIG (read-only) ==');
  } finally {
    await database.close();
  }
}
