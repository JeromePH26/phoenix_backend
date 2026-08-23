import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../model_lab/football_league_tier.dart';

class PhoenixDatabase {
  PhoenixDatabase(this.databaseUrl);

  final String databaseUrl;
  Connection? _connection;

  bool get isConfigured => databaseUrl.trim().isNotEmpty;

  Future<Connection> connection() async {
    final current = _connection;
    if (current != null && current.isOpen) return current;
    if (!isConfigured) {
      throw StateError('DATABASE_URL fehlt.');
    }

    final uri = Uri.parse(databaseUrl);
    final endpoint = Endpoint(
      host: uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: uri.pathSegments.isEmpty ? 'railway' : uri.pathSegments.first,
      username: uri.userInfo.split(':').first,
      password: uri.userInfo.contains(':')
          ? uri.userInfo.substring(uri.userInfo.indexOf(':') + 1)
          : null,
    );

    final connection = await Connection.open(
      endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.require),
    );
    _connection = connection;
    return connection;
  }

  Future<void> migrate() async {
    if (!isConfigured) return;
    final db = await connection();

    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    // API-Sports Free-Plan: produktbezogen 100 Requests/Tag. Dieser Zaehler
    // bleibt ueber Redeployments erhalten und laesst bewusst zehn Requests
    // Reserve fuer manuelle Diagnoseaufrufe im Dashboard.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS api_sports_daily_usage (
        api_name TEXT NOT NULL,
        usage_date DATE NOT NULL,
        requests INTEGER NOT NULL DEFAULT 0,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (api_name, usage_date)
      )
    ''');
    // Section 25 (AN2, "Höchste Priorität"): bis hierhin zählte diese
    // Tabelle NUR die sekundären API-Sports-Free-Produkte (ApiSportsTeamEngine
    // - andere Sportarten als Fußball), nie die tatsächliche
    // API-Football-Hauptnutzung von FootballService, die den eigentlichen
    // API-Kostentreiber darstellt. `errors` neu für eine echte Fehlerquote.
    await db.execute('''
      ALTER TABLE api_sports_daily_usage
      ADD COLUMN IF NOT EXISTS errors INTEGER NOT NULL DEFAULT 0
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_matches (
        id TEXT PRIMARY KEY,
        kickoff_utc TIMESTAMPTZ NOT NULL,
        status TEXT NOT NULL,
        league_id TEXT NOT NULL,
        league_name TEXT NOT NULL,
        country TEXT NOT NULL DEFAULT '',
        home_team_id TEXT NOT NULL,
        home_team_name TEXT NOT NULL,
        home_logo TEXT NOT NULL DEFAULT '',
        away_team_id TEXT NOT NULL,
        away_team_name TEXT NOT NULL,
        away_logo TEXT NOT NULL DEFAULT '',
        home_goals INTEGER,
        away_goals INTEGER,
        raw_json JSONB NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_matches_kickoff
      ON football_matches (kickoff_utc)
    ''');

    // Section 31 (Ligen/Teams Performance): footballEntityPerformance und
    // footballDataCoverage filtern jede Aggregation über league_id bzw.
    // home_team_id/away_team_id - ohne diese Indizes scannt jede Liga-/
    // Team-Detailseite die komplette football_matches-Tabelle.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_matches_league
      ON football_matches (league_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_matches_home_team
      ON football_matches (home_team_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_matches_away_team
      ON football_matches (away_team_id)
    ''');

    // Originalwappen werden einmalig beim ersten Abruf gespeichert. Dadurch
    // laden Tabellen und Teamvergleiche keine Bilddateien erneut von der
    // Sportdaten-API und bleiben auch bei späteren API-Aussetzern sichtbar.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_assets (
        asset_type TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        source_url TEXT NOT NULL DEFAULT '',
        mime_type TEXT NOT NULL,
        content BYTEA NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (asset_type, asset_id)
      )
    ''');

    // Archiv früherer Wappen-Versionen: wird ausschließlich beim manuellen
    // Ersetzen im Control Center befüllt (Section "Assets als echte
    // Galerie"), NICHT beim automatischen Erst-Caching in
    // FootballAssetService - dort gibt es nichts zu archivieren.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_assets_history (
        id BIGSERIAL PRIMARY KEY,
        asset_type TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        source_url TEXT NOT NULL DEFAULT '',
        mime_type TEXT NOT NULL,
        content BYTEA NOT NULL,
        archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    // Zentrale Medienbibliothek für alle eigenen Bilder außerhalb der
    // Fußball-Wappen: redaktionelle Titelbilder, Kampagnen, Branding und
    // UI-Grafiken. Provider-Wappen bleiben im bestehenden football_assets-
    // Cache, werden in der Bibliothek aber gemeinsam inventarisiert.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS media_assets (
        id BIGSERIAL PRIMARY KEY,
        category TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        alt_text TEXT NOT NULL DEFAULT '',
        usage_type TEXT NOT NULL DEFAULT 'library',
        entity_type TEXT,
        entity_id TEXT,
        source_kind TEXT NOT NULL DEFAULT 'upload',
        source_url TEXT NOT NULL DEFAULT '',
        mime_type TEXT NOT NULL,
        byte_size INTEGER NOT NULL,
        content BYTEA NOT NULL,
        metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
        archived_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (category IN ('brand', 'editorial', 'advertising', 'ui', 'other')),
        CHECK (source_kind IN ('upload', 'generated', 'provider')),
        CHECK (byte_size > 0 AND byte_size <= 3145728)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_media_assets_library
      ON media_assets (category, archived_at, updated_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_media_assets_entity
      ON media_assets (entity_type, entity_id)
      WHERE entity_type IS NOT NULL AND entity_id IS NOT NULL
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_assets_history_lookup
      ON football_assets_history (asset_type, asset_id, archived_at DESC)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS tennis_matches (
        id TEXT PRIMARY KEY,
        start_time_utc TIMESTAMPTZ NOT NULL,
        status TEXT NOT NULL,
        tournament TEXT NOT NULL,
        tour TEXT NOT NULL,
        surface TEXT NOT NULL,
        round_name TEXT NOT NULL DEFAULT '',
        best_of INTEGER NOT NULL DEFAULT 3,
        player_one_id TEXT NOT NULL,
        player_one_name TEXT NOT NULL,
        player_two_id TEXT NOT NULL,
        player_two_name TEXT NOT NULL,
        score TEXT,
        raw_json JSONB NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_tennis_matches_start
      ON tennis_matches (start_time_utc)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS analyses (
        id BIGSERIAL PRIMARY KEY,
        sport TEXT NOT NULL,
        match_id TEXT NOT NULL,
        model_version TEXT NOT NULL,
        data_quality INTEGER NOT NULL,
        confidence INTEGER NOT NULL,
        recommendation TEXT,
        payload JSONB NOT NULL,
        analyzed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        locked_at TIMESTAMPTZ,
        UNIQUE (sport, match_id, model_version)
      )
    ''');

    // Unveränderliche Prognose-Snapshots für die spätere Erfolgsanalyse.
    // `analyses` liefert weiterhin nur den aktuellsten Stand an die App.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_analysis_history (
        phase_two_scan_run_id BIGINT NOT NULL,
        fixture_id TEXT NOT NULL,
        prediction_date DATE NOT NULL,
        kickoff TIMESTAMPTZ,
        model_version TEXT NOT NULL,
        market_key TEXT NOT NULL DEFAULT '',
        market_label TEXT NOT NULL DEFAULT '',
        model_probability DOUBLE PRECISION,
        fair_odds DOUBLE PRECISION,
        market_odds DOUBLE PRECISION,
        assigned_units DOUBLE PRECISION NOT NULL DEFAULT 0,
        data_quality INTEGER NOT NULL,
        confidence INTEGER NOT NULL,
        result_status TEXT NOT NULL DEFAULT 'pending',
        home_score INTEGER,
        away_score INTEGER,
        profit_units DOUBLE PRECISION,
        settled_at TIMESTAMPTZ,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (phase_two_scan_run_id, fixture_id)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_analysis_history_date
      ON football_analysis_history (prediction_date, result_status)
    ''');

    // Section 31: footballEntityPerformance filtert/joint über fixture_id,
    // market_key und kickoff (nicht prediction_date) - fixture_id ist nur
    // der zweite Teil des Primärschlüssels und daher ohne eigenen Index
    // für den INNER JOIN mit football_matches nicht nutzbar.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_analysis_history_fixture
      ON football_analysis_history (fixture_id)
    ''');
    // Die Admin-Tippübersicht holt pro Spiel den letzten Snapshot. Dieser
    // zusammengesetzte Index liefert DISTINCT ON (fixture_id) bereits in der
    // richtigen Reihenfolge und verhindert bei jeder Seitenansicht einen
    // vollständigen Sort über die komplette Analysehistorie.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_analysis_history_fixture_latest
      ON football_analysis_history (fixture_id, created_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_analysis_history_market
      ON football_analysis_history (market_key)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_analysis_history_kickoff
      ON football_analysis_history (kickoff)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_analysis_history_model_version
      ON football_analysis_history (model_version)
    ''');

    // MLB snapshots are stored before the first pitch. A result is useful for
    // model calibration even without odds; units/ROI stay at zero until a
    // licensed odds source provides a real market price.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS baseball_analysis_history (
        game_id TEXT PRIMARY KEY,
        prediction_date DATE NOT NULL,
        scheduled_at TIMESTAMPTZ,
        home_team TEXT NOT NULL,
        away_team TEXT NOT NULL,
        pick_side TEXT NOT NULL,
        market_label TEXT NOT NULL,
        model_probability DOUBLE PRECISION,
        fair_odds DOUBLE PRECISION,
        market_odds DOUBLE PRECISION,
        assigned_units DOUBLE PRECISION NOT NULL DEFAULT 0,
        result_status TEXT NOT NULL DEFAULT 'pending',
        home_score INTEGER,
        away_score INTEGER,
        profit_units DOUBLE PRECISION,
        settled_at TIMESTAMPTZ,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_baseball_analysis_history_date
      ON baseball_analysis_history (prediction_date, result_status)
    ''');

    // ROI represents bets the value guard actually released. Older snapshots
    // incorrectly assigned one unit to every analysis that merely had odds.
    await db.execute('''
      UPDATE football_analysis_history
      SET assigned_units = 0
      WHERE assigned_units <> 0
        AND COALESCE(payload #> '{selection,value,isValueTip}', 'false'::jsonb)
            <> 'true'::jsonb
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS daily_tips (
        tip_date DATE NOT NULL,
        sport TEXT NOT NULL,
        match_id TEXT NOT NULL,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (tip_date, sport)
      )
    ''');

    // A daily combo is a reproducible snapshot, not a recalculated client
    // suggestion. Its legs and quote source remain fixed after publication.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_daily_combos (
        combo_date DATE PRIMARY KEY,
        combined_odds DOUBLE PRECISION NOT NULL,
        combined_probability DOUBLE PRECISION NOT NULL,
        uses_model_odds BOOLEAN NOT NULL DEFAULT FALSE,
        result_status TEXT NOT NULL DEFAULT 'pending',
        assigned_units DOUBLE PRECISION NOT NULL DEFAULT 0,
        profit_units DOUBLE PRECISION,
        settled_at TIMESTAMPTZ,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_phase_two_results (
        scan_run_id BIGINT NOT NULL,
        fixture_id TEXT NOT NULL,
        league_id TEXT NOT NULL,
        season INTEGER NOT NULL,
        data_quality INTEGER NOT NULL,
        analysis_allowed BOOLEAN NOT NULL,
        availability JSONB NOT NULL,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (scan_run_id, fixture_id)
      )
    ''');

    // Section 31: footballDataCoverage filtert über league_id und joint per
    // fixture_id mit football_matches für den Team-Filter.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_phase_two_results_league
      ON football_phase_two_results (league_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_phase_two_results_fixture
      ON football_phase_two_results (fixture_id)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_ai_context_checks (
        phase_two_scan_run_id BIGINT NOT NULL,
        fixture_id TEXT NOT NULL,
        model TEXT NOT NULL,
        response_id TEXT,
        status TEXT NOT NULL,
        context_result JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (phase_two_scan_run_id, fixture_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_engine_inputs (
        phase_two_scan_run_id BIGINT NOT NULL,
        fixture_id TEXT NOT NULL,
        league_id TEXT NOT NULL,
        season INTEGER NOT NULL,
        data_quality INTEGER NOT NULL,
        model_version TEXT NOT NULL,
        normalized_input JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (phase_two_scan_run_id, fixture_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_simulation_results (
        phase_two_scan_run_id BIGINT NOT NULL,
        fixture_id TEXT NOT NULL,
        model_version TEXT NOT NULL,
        simulations INTEGER NOT NULL,
        result JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (phase_two_scan_run_id, fixture_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_market_selections (
        phase_two_scan_run_id BIGINT NOT NULL,
        fixture_id TEXT NOT NULL,
        model_version TEXT NOT NULL,
        selection JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (phase_two_scan_run_id, fixture_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_daily_pipeline_jobs (
        id BIGSERIAL PRIMARY KEY,
        scan_date DATE NOT NULL,
        status TEXT NOT NULL DEFAULT 'running',
        current_step TEXT NOT NULL DEFAULT 'created',
        phase_one_scan_run_id BIGINT,
        phase_two_scan_run_id BIGINT,
        requested_limit INTEGER NOT NULL,
        minimum_data_quality INTEGER NOT NULL,
        simulations INTEGER NOT NULL DEFAULT 100000,
        processed INTEGER NOT NULL DEFAULT 0,
        published INTEGER NOT NULL DEFAULT 0,
        error TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        last_activity_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        completed_at TIMESTAMPTZ
      )
    ''');

    // Bestehende Railway-Datenbanken können eine ältere Version der
    // Job-Tabelle besitzen. CREATE TABLE IF NOT EXISTS ergänzt keine
    // später hinzugekommenen Spalten, deshalb werden sie hier einzeln
    // nachgezogen.
    await db.execute('''
      ALTER TABLE football_daily_pipeline_jobs
        ADD COLUMN IF NOT EXISTS scan_date DATE,
        ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'running',
        ADD COLUMN IF NOT EXISTS current_step TEXT NOT NULL DEFAULT 'created',
        ADD COLUMN IF NOT EXISTS phase_one_scan_run_id BIGINT,
        ADD COLUMN IF NOT EXISTS phase_two_scan_run_id BIGINT,
        ADD COLUMN IF NOT EXISTS requested_limit INTEGER NOT NULL DEFAULT 20,
        ADD COLUMN IF NOT EXISTS minimum_data_quality INTEGER NOT NULL DEFAULT 60,
        ADD COLUMN IF NOT EXISTS simulations INTEGER NOT NULL DEFAULT 100000,
        ADD COLUMN IF NOT EXISTS processed INTEGER NOT NULL DEFAULT 0,
        ADD COLUMN IF NOT EXISTS published INTEGER NOT NULL DEFAULT 0,
        ADD COLUMN IF NOT EXISTS error TEXT,
        ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ADD COLUMN IF NOT EXISTS last_activity_at TIMESTAMPTZ,
        ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ
    ''');

    // Ein Scan darf nie unbegrenzt als "läuft" hängen bleiben. Bestehende
    // Datensätze erhalten zunächst einen sinnvollen Aktivitätszeitpunkt;
    // neue Läufe aktualisieren ihn zusätzlich durch einen Heartbeat.
    await db.execute('''
      UPDATE football_daily_pipeline_jobs
      SET last_activity_at = COALESCE(last_activity_at, completed_at, created_at)
      WHERE last_activity_at IS NULL
    ''');

    await db.execute('''
      ALTER TABLE football_daily_pipeline_jobs
      ALTER COLUMN last_activity_at SET DEFAULT NOW()
    ''');

    await db.execute('''
      ALTER TABLE football_daily_pipeline_jobs
      ALTER COLUMN last_activity_at SET NOT NULL
    ''');

    // Alte Prozesse aus früheren Deployments haben keinen Heartbeat. Sie
    // blockieren keinen weiteren manuellen Scan mehr, wenn sie 15 Minuten
    // keinerlei Aktivität gemeldet haben.
    await db.execute('''
      UPDATE football_daily_pipeline_jobs
      SET status = 'failed',
          current_step = 'timed_out',
          error = 'Scan wegen fehlender Aktivität automatisch beendet.',
          completed_at = NOW(),
          last_activity_at = NOW()
      WHERE status = 'running'
        AND last_activity_at < NOW() - INTERVAL '15 minutes'
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_daily_pipeline_jobs_date
      ON football_daily_pipeline_jobs (scan_date, id DESC)
    ''');

    // Es darf genau ein rechenintensiver Football-Scan gleichzeitig laufen.
    // Das ist absichtlich kein Tageslimit: Nach Abschluss kann derselbe Tag
    // jederzeit erneut gescannt werden.
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_football_daily_pipeline_one_running
      ON football_daily_pipeline_jobs ((1))
      WHERE status = 'running'
    ''');

    // PHÖNIX-Fußballanalysen laufen verbindlich mit 100.000 Simulationen.
    // Dadurch erhalten auch bereits bestehende Railway-Datenbanken den
    // aktuellen Standardwert.
    await db.execute('''
      ALTER TABLE football_daily_pipeline_jobs
      ALTER COLUMN simulations SET DEFAULT 100000
    ''');

    await db.execute('''
      ALTER TABLE football_daily_pipeline_jobs
      ALTER COLUMN minimum_data_quality SET DEFAULT 60
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_leagues (
        league_id TEXT PRIMARY KEY,
        league_name TEXT NOT NULL,
        country TEXT NOT NULL DEFAULT '',
        gender TEXT NOT NULL DEFAULT 'unknown',
        competition_level INTEGER,
        manual_status TEXT NOT NULL DEFAULT 'auto',
        historical_status TEXT NOT NULL DEFAULT 'observation',
        total_samples INTEGER NOT NULL DEFAULT 0,
        successful_full_analyses INTEGER NOT NULL DEFAULT 0,
        first_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (manual_status IN ('auto', 'whitelist', 'blacklist')),
        CHECK (
          historical_status IN (
            'observation',
            'provisional',
            'approved',
            'restricted',
            'blacklist'
          )
        )
      )
    ''');

    // Liga-Tiers erweitern die historische Whitelist, statt sie zu brechen.
    // Alle Tabellen/Teams/Spiele behalten dadurch dasselbe Datenmodell. Die
    // Stufe entscheidet ausschließlich über Scan-Tiefe und Sichtbarkeit.
    await db.execute('''
      ALTER TABLE football_leagues
      ADD COLUMN IF NOT EXISTS collection_tier TEXT NOT NULL DEFAULT 'data_pool'
    ''');
    await db.execute('''
      ALTER TABLE football_leagues
      ADD COLUMN IF NOT EXISTS background_enabled BOOLEAN NOT NULL DEFAULT TRUE
    ''');
    await db.execute('''
      ALTER TABLE football_leagues
      ADD COLUMN IF NOT EXISTS detail_refresh_hours INTEGER NOT NULL DEFAULT 24
    ''');
    await db.execute('''
      UPDATE football_leagues
      SET collection_tier = CASE manual_status
        WHEN 'whitelist' THEN 'focus'
        WHEN 'blacklist' THEN 'blocked'
        ELSE COALESCE(NULLIF(collection_tier, ''), 'data_pool')
      END,
      background_enabled = manual_status <> 'blacklist',
      detail_refresh_hours = CASE manual_status
        WHEN 'whitelist' THEN 1
        WHEN 'blacklist' THEN 0
        ELSE 24
      END
      WHERE collection_tier NOT IN ('focus', 'watchlist', 'data_pool', 'blocked')
         OR collection_tier = 'data_pool'
         OR manual_status IN ('whitelist', 'blacklist')
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_league_sync_state (
        league_id TEXT PRIMARY KEY REFERENCES football_leagues(league_id)
          ON DELETE CASCADE,
        catalog_synced_at TIMESTAMPTZ,
        fixtures_synced_at TIMESTAMPTZ,
        results_synced_at TIMESTAMPTZ,
        standings_synced_at TIMESTAMPTZ,
        details_synced_at TIMESTAMPTZ,
        last_error TEXT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    // PHÖNIX feste Wettbewerbs-Whitelist:
    // 22 nationale Ligen, 11 nationale Pokale und 3 UEFA-Wettbewerbe.
    // Bereits vorhandene Datensätze werden auf whitelist aktualisiert.
    await db.execute(r'''
      INSERT INTO football_leagues (
        league_id,
        league_name,
        country,
        gender,
        competition_level,
        manual_status,
        historical_status,
        collection_tier,
        background_enabled,
        detail_refresh_hours,
        updated_at
      )
      VALUES
        ('39',  'Premier League',              'England',     'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('40',  'Championship',                'England',     'men', 2, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('61',  'Ligue 1',                     'France',      'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('78',  'Bundesliga',                  'Germany',     'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('79',  '2. Bundesliga',               'Germany',     'men', 2, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('80',  '3. Liga',                     'Germany',     'men', 3, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('88',  'Eredivisie',                  'Netherlands', 'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('94',  'Primeira Liga',               'Portugal',    'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('103', 'Eliteserien',                 'Norway',      'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('113', 'Allsvenskan',                 'Sweden',      'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('119', 'Superliga',                   'Denmark',     'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('135', 'Serie A',                     'Italy',       'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('140', 'La Liga',                     'Spain',       'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('141', 'Segunda Division',            'Spain',       'men', 2, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('144', 'Jupiler Pro League',          'Belgium',     'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('203', 'Süper Lig',                   'Turkey',      'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('244', 'Veikkausliiga',               'Finland',     'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('207', 'Super League',                 'Switzerland', 'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('210', 'HNL',                          'Croatia',     'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('218', '2. Liga',                      'Austria',     'men', 2, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('253', 'Major League Soccer',          'USA',         'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),

        ('45',  'FA Cup',                      'England',     'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('48',  'EFL Cup',                     'England',     'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('66',  'Coupe de France',             'France',      'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('81',  'DFB Pokal',                   'Germany',     'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('90',  'KNVB Beker',                  'Netherlands', 'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('96',  'Taça de Portugal',            'Portugal',    'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('104', 'NM Cupen',                    'Norway',      'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('106', 'Ekstraklasa',                 'Poland',      'men', 1, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('137', 'Coppa Italia',                'Italy',       'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('143', 'Copa del Rey',                'Spain',       'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('147', 'Belgian Cup',                 'Belgium',     'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('245', 'Suomen Cup',                  'Finland',     'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),

        ('2',   'UEFA Champions League',       'World',       'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('3',   'UEFA Europa League',          'World',       'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW()),
        ('848', 'UEFA Conference League',      'World',       'men', NULL, 'whitelist', 'approved', 'focus', TRUE, 1, NOW())
      ON CONFLICT (league_id) DO UPDATE SET
        league_name = EXCLUDED.league_name,
        country = EXCLUDED.country,
        gender = EXCLUDED.gender,
        competition_level = EXCLUDED.competition_level,
        manual_status = 'whitelist',
        historical_status = 'approved',
        collection_tier = 'focus',
        background_enabled = TRUE,
        detail_refresh_hours = 1,
        updated_at = NOW()
    ''');

    // API-Football 116 ist die belarussische Premier League. Eine ältere
    // Zuordnung als Svenska Cupen hatte sie versehentlich freigeschaltet.
    await db.execute(r'''
      INSERT INTO football_leagues (
        league_id, league_name, country, gender, competition_level,
        manual_status, historical_status, collection_tier, background_enabled,
        detail_refresh_hours, updated_at
      ) VALUES (
        '116', 'Premier League', 'Belarus', 'men', 1,
        'blacklist', 'blacklist', 'blocked', FALSE, 0, NOW()
      )
      ON CONFLICT (league_id) DO UPDATE SET
        league_name = EXCLUDED.league_name,
        country = EXCLUDED.country,
        gender = EXCLUDED.gender,
        competition_level = EXCLUDED.competition_level,
        manual_status = 'blacklist',
        historical_status = 'blacklist',
        collection_tier = 'blocked',
        background_enabled = FALSE,
        detail_refresh_hours = 0,
        updated_at = NOW()
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_league_seasons (
        league_id TEXT NOT NULL REFERENCES football_leagues(league_id)
          ON DELETE CASCADE,
        season INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'observation',
        samples INTEGER NOT NULL DEFAULT 0,
        fixtures_available INTEGER NOT NULL DEFAULT 0,
        standings_available INTEGER NOT NULL DEFAULT 0,
        statistics_available INTEGER NOT NULL DEFAULT 0,
        lineups_available INTEGER NOT NULL DEFAULT 0,
        players_available INTEGER NOT NULL DEFAULT 0,
        player_images_available INTEGER NOT NULL DEFAULT 0,
        injuries_available INTEGER NOT NULL DEFAULT 0,
        odds_available INTEGER NOT NULL DEFAULT 0,
        h2h_available INTEGER NOT NULL DEFAULT 0,
        full_analysis_available INTEGER NOT NULL DEFAULT 0,
        last_evaluated_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (league_id, season),
        CHECK (
          status IN (
            'observation',
            'provisional',
            'approved',
            'restricted',
            'blacklist'
          )
        )
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_coverage_samples (
        id BIGSERIAL PRIMARY KEY,
        league_id TEXT NOT NULL,
        season INTEGER NOT NULL,
        fixture_id TEXT,
        fixtures_available BOOLEAN NOT NULL DEFAULT FALSE,
        standings_available BOOLEAN NOT NULL DEFAULT FALSE,
        statistics_available BOOLEAN NOT NULL DEFAULT FALSE,
        lineups_available BOOLEAN NOT NULL DEFAULT FALSE,
        players_available BOOLEAN NOT NULL DEFAULT FALSE,
        player_images_available BOOLEAN NOT NULL DEFAULT FALSE,
        injuries_available BOOLEAN NOT NULL DEFAULT FALSE,
        odds_available BOOLEAN NOT NULL DEFAULT FALSE,
        h2h_available BOOLEAN NOT NULL DEFAULT FALSE,
        full_analysis_available BOOLEAN NOT NULL DEFAULT FALSE,
        source TEXT NOT NULL DEFAULT 'scan',
        sampled_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_coverage_league_season
      ON football_coverage_samples (league_id, season)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_scan_runs (
        id BIGSERIAL PRIMARY KEY,
        scan_date DATE NOT NULL,
        phase INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'running',
        total_matches INTEGER NOT NULL DEFAULT 0,
        eligible_matches INTEGER NOT NULL DEFAULT 0,
        excluded_matches INTEGER NOT NULL DEFAULT 0,
        payload JSONB NOT NULL DEFAULT '{}'::jsonb,
        started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        completed_at TIMESTAMPTZ,
        CHECK (status IN ('running', 'completed', 'failed'))
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_scan_matches (
        scan_run_id BIGINT NOT NULL REFERENCES football_scan_runs(id)
          ON DELETE CASCADE,
        fixture_id TEXT NOT NULL,
        league_id TEXT NOT NULL,
        season INTEGER NOT NULL,
        eligible BOOLEAN NOT NULL,
        decision_status TEXT NOT NULL,
        exclusion_reason TEXT,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (scan_run_id, fixture_id)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_scan_matches_eligible
      ON football_scan_matches (scan_run_id, eligible)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS push_devices (
        installation_id TEXT PRIMARY KEY,
        push_token TEXT NOT NULL UNIQUE,
        platform TEXT NOT NULL,
        locale TEXT NOT NULL DEFAULT 'de',
        enabled BOOLEAN NOT NULL DEFAULT TRUE,
        news_enabled BOOLEAN NOT NULL DEFAULT TRUE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
    await db.execute('''
      ALTER TABLE push_devices
      ADD COLUMN IF NOT EXISTS news_enabled BOOLEAN NOT NULL DEFAULT TRUE
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_favorite_entities (
        installation_id TEXT NOT NULL REFERENCES push_devices(installation_id)
          ON DELETE CASCADE,
        entity_type TEXT NOT NULL CHECK (entity_type IN ('team', 'league')),
        entity_id TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (installation_id, entity_type, entity_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS news_push_deliveries (
        article_id TEXT NOT NULL,
        installation_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        provider_response TEXT,
        attempted_at TIMESTAMPTZ,
        PRIMARY KEY (article_id, installation_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_favorites (
        installation_id TEXT NOT NULL REFERENCES push_devices(installation_id)
          ON DELETE CASCADE,
        fixture_id TEXT NOT NULL,
        notifications_enabled BOOLEAN NOT NULL DEFAULT TRUE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (installation_id, fixture_id)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_favorites_fixture
      ON football_favorites (fixture_id)
      WHERE notifications_enabled = TRUE
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_live_events (
        fixture_id TEXT NOT NULL,
        event_key TEXT NOT NULL,
        event_type TEXT NOT NULL,
        payload JSONB NOT NULL,
        detected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (fixture_id, event_key)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS push_deliveries (
        fixture_id TEXT NOT NULL,
        event_key TEXT NOT NULL,
        installation_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        provider_response TEXT,
        attempted_at TIMESTAMPTZ,
        PRIMARY KEY (fixture_id, event_key, installation_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS news_articles (
        id TEXT PRIMARY KEY,
        source_name TEXT NOT NULL,
        source_url TEXT NOT NULL,
        article_url TEXT NOT NULL UNIQUE,
        title_de TEXT NOT NULL,
        summary_de TEXT NOT NULL DEFAULT '',
        body_de TEXT NOT NULL DEFAULT '',
        article_type TEXT NOT NULL DEFAULT 'general',
        image_url TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT 'general',
        importance INTEGER NOT NULL DEFAULT 40,
        team_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
        team_names JSONB NOT NULL DEFAULT '[]'::jsonb,
        league_ids JSONB NOT NULL DEFAULT '[]'::jsonb,
        league_names JSONB NOT NULL DEFAULT '[]'::jsonb,
        published_at TIMESTAMPTZ NOT NULL,
        fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');

    // Bestehende Railway-Datenbanken besitzen die News-Tabelle bereits.
    // Die Felder werden deshalb separat ergänzt statt nur in CREATE TABLE
    // definiert, damit der eigene Phoenix-Redaktionsbereich sofort migriert.
    await db.execute('''
      ALTER TABLE news_articles
        ADD COLUMN IF NOT EXISTS body_de TEXT NOT NULL DEFAULT '',
        ADD COLUMN IF NOT EXISTS article_type TEXT NOT NULL DEFAULT 'general'
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_news_articles_published
      ON news_articles (published_at DESC)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_season_projections (
        league_id TEXT NOT NULL REFERENCES football_leagues(league_id)
          ON DELETE CASCADE,
        season INTEGER NOT NULL,
        model_version TEXT NOT NULL,
        simulations INTEGER NOT NULL,
        payload JSONB NOT NULL,
        calculated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (league_id, season)
      )
    ''');

    // Verfolgt Backfill- und wiederkehrende Ergebnis-Abgleichläufe für
    // football_matches. Getrennt von football_daily_pipeline_jobs, weil hier
    // weder Phasen noch Simulationen anfallen, nur ein Batch-Fortschritt.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS football_match_settlement_jobs (
        id BIGSERIAL PRIMARY KEY,
        status TEXT NOT NULL DEFAULT 'running',
        min_hours_since_kickoff INTEGER NOT NULL,
        batch_size INTEGER NOT NULL,
        checked INTEGER NOT NULL DEFAULT 0,
        settled INTEGER NOT NULL DEFAULT 0,
        pending INTEGER NOT NULL DEFAULT 0,
        failed INTEGER NOT NULL DEFAULT 0,
        error TEXT,
        last_error TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        completed_at TIMESTAMPTZ
      )
    ''');

    // Bestehende Railway-Datenbanken besitzen die Spalte ggf. noch nicht.
    await db.execute('''
      ALTER TABLE football_match_settlement_jobs
        ADD COLUMN IF NOT EXISTS last_error TEXT
    ''');

    // Beschleunigt die wiederkehrende Suche nach noch offenen Spielen, ohne
    // bei jedem Lauf die gesamte football_matches-Tabelle zu scannen.
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_matches_status
      ON football_matches (status, kickoff_utc)
    ''');

    // Historical Twins V1: externe historische Spiele bewusst getrennt von
    // football_matches, damit ein Pre-Match-Vergleichsdatensatz nie mit
    // PHÖNIX' eigenen Live-Daten kollidiert. "source" unterscheidet spätere
    // phoenix-eigene Twin-Kandidaten (phoenix_native) von diesem externen
    // Datensatz (external_dataset).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS historical_twin_matches (
        id BIGSERIAL PRIMARY KEY,
        source TEXT NOT NULL DEFAULT 'external_dataset',
        source_match_key TEXT NOT NULL,
        division TEXT NOT NULL DEFAULT '',
        match_date DATE NOT NULL,
        home_team TEXT NOT NULL,
        away_team TEXT NOT NULL,
        home_goals INTEGER,
        away_goals INTEGER,
        result TEXT,
        home_elo DOUBLE PRECISION,
        away_elo DOUBLE PRECISION,
        elo_difference DOUBLE PRECISION,
        absolute_elo_level DOUBLE PRECISION,
        form3_home DOUBLE PRECISION,
        form5_home DOUBLE PRECISION,
        form3_away DOUBLE PRECISION,
        form5_away DOUBLE PRECISION,
        normalized_home_probability DOUBLE PRECISION,
        normalized_draw_probability DOUBLE PRECISION,
        normalized_away_probability DOUBLE PRECISION,
        over25_probability DOUBLE PRECISION,
        under25_probability DOUBLE PRECISION,
        -- Rolling-/Lagged-Features (nur aus frueheren Spielen berechnet,
        -- siehe Import-Skript) liegen gebuendelt in JSONB statt als
        -- ~28 Einzelspalten.
        features JSONB NOT NULL DEFAULT '{}'::jsonb,
        data_coverage_percent DOUBLE PRECISION NOT NULL DEFAULT 0,
        import_version TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (source, source_match_key)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_historical_twin_matches_elo_diff
      ON historical_twin_matches (elo_difference)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_historical_twin_matches_coverage
      ON historical_twin_matches (data_coverage_percent)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_historical_twin_matches_date
      ON historical_twin_matches (match_date DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_historical_twin_matches_prob
      ON historical_twin_matches (normalized_home_probability)
    ''');

    // Zeitreihe aus EloRatings.csv, getrennt von den je-Match-Elo-Werten in
    // historical_twin_matches. Legt die Basis dafür, dass PHÖNIX seine
    // eigene Elo-Reihe künftig selbst fortschreiben kann (siehe Vorgabe 14) -
    // die Fortschreibung selbst ist bewusst nicht Teil von V1.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS historical_elo_ratings (
        id BIGSERIAL PRIMARY KEY,
        rating_date DATE NOT NULL,
        club TEXT NOT NULL,
        country TEXT NOT NULL DEFAULT '',
        elo DOUBLE PRECISION NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (rating_date, club)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_historical_elo_ratings_club_date
      ON historical_elo_ratings (club, rating_date DESC)
    ''');

    await _migrateModelLab(db);
    await _migrateControlCenter(db);
    await _migrateSupport(db);
    await _migrateContent(db);
    await _migrateOps(db);
    await _migrateModuleControl(db);
    await _migrateSystemAuditHistory(db);
    await _migrateFootballMatchControls(db);
    await _migrateUserAccounts(db);
    await _migrateFootballAssetsSchema(db);

    await db.execute('''
      INSERT INTO app_meta (key, value)
      VALUES ('schema_version', '11')
      ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value, updated_at = NOW()
    ''');
  }

  /// PHÖNIX ACCOUNT SYSTEM (additiv, Phase 1 laut "anweisungen claude.txt"
  /// Abschnitt 99: Datenmodell + Migrationen + Permissions). Muss NACH
  /// `_migrateControlCenter` (admin_employees) und `_migrateSupport`
  /// (support_tickets) laufen, da beide per Foreign Key referenziert werden.
  ///
  /// Wiederverwendet bewusst bestehende Strukturen statt zu duplizieren
  /// (Abschnitt 98): `admin_audit_log` dient auch als Audit-Trail für
  /// Account-System-Ereignisse (Abschnitt 92 verlangt exakt actor/action/
  /// target_type/target_id/before/after/reason/created_at - das deckt sich
  /// vollständig mit dem bestehenden Schema); die bestehenden deutschen
  /// Support-Ticket-Status (NEU/IN_BEARBEITUNG/WARTET_AUF_NUTZER/GELOEST/
  /// GESCHLOSSEN) entsprechen bereits exakt Abschnitt 39; `support_ticket_
  /// messages.internal_note` (Abschnitt 40) existiert bereits.
  ///
  /// `admin_employees` bleibt die alleinige Control-Center-RBAC-Quelle
  /// (Abschnitt 93 Backward Compatibility) - Mitarbeiter, die zusätzlich in
  /// der normalen App auftreten sollen (Abschnitt 16/17), bekommen über die
  /// neue `user_id`-Spalte optional eine verknüpfte `users`-Zeile.
  Future<void> _migrateUserAccounts(Connection db) async {
    // Abschnitt 8/11/84: dauerhafte PHX-U-Nummer als STORED Generated Column
    // direkt aus der Primärschlüssel-Sequenz - kollisionsfrei per
    // Konstruktion, kein App-seitiges Race-Condition-Risiko bei Retries.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id BIGSERIAL PRIMARY KEY,
        phoenix_user_id TEXT GENERATED ALWAYS AS
          ('PHX-U-' || LPAD(id::text, 8, '0')) STORED,
        account_type TEXT NOT NULL DEFAULT 'USER',
        email TEXT NOT NULL,
        email_lower TEXT GENERATED ALWAYS AS (LOWER(email)) STORED,
        email_verified BOOLEAN NOT NULL DEFAULT FALSE,
        username TEXT,
        username_lower TEXT GENERATED ALWAYS AS (LOWER(username)) STORED,
        display_name TEXT,
        username_changed_at TIMESTAMPTZ,
        date_of_birth DATE NOT NULL,
        age_gate_passed BOOLEAN NOT NULL DEFAULT FALSE,
        age_gate_checked_at TIMESTAMPTZ,
        account_status TEXT NOT NULL DEFAULT 'PENDING_EMAIL_VERIFICATION',
        language TEXT,
        country TEXT,
        terms_version TEXT,
        terms_accepted_at TIMESTAMPTZ,
        privacy_version TEXT,
        privacy_accepted_at TIMESTAMPTZ,
        community_guidelines_version TEXT,
        community_guidelines_accepted_at TIMESTAMPTZ,
        trial_available BOOLEAN NOT NULL DEFAULT TRUE,
        trial_started_at TIMESTAMPTZ,
        trial_ends_at TIMESTAMPTZ,
        trial_used BOOLEAN NOT NULL DEFAULT FALSE,
        intro_offer_used BOOLEAN NOT NULL DEFAULT FALSE,
        notification_settings JSONB NOT NULL DEFAULT '{}',
        current_app_version TEXT,
        deletion_status TEXT,
        deletion_requested_at TIMESTAMPTZ,
        deletion_scheduled_at TIMESTAMPTZ,
        deletion_cancelled_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        last_login_at TIMESTAMPTZ,
        last_active_at TIMESTAMPTZ,
        CHECK (account_type IN ('USER', 'EMPLOYEE', 'OWNER')),
        CHECK (account_status IN (
          'PENDING_EMAIL_VERIFICATION', 'ACTIVE', 'SUSPENDED',
          'PERMANENTLY_SUSPENDED', 'DELETION_PENDING', 'DELETED'
        )),
        CHECK (
          deletion_status IS NULL
          OR deletion_status IN ('PENDING', 'CANCELLED', 'COMPLETED')
        )
      )
    ''');
    // Abschnitt 6/85: E-Mail und Username case-insensitive eindeutig,
    // DB-seitig erzwungen (nicht nur Frontend-Prüfung). Username ist
    // nullable (erst beim Onboarding vergeben) - partial index lässt
    // mehrere NULLs zu, erzwingt Eindeutigkeit nur für tatsächlich gesetzte
    // Namen.
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_lower
      ON users (email_lower)
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username_lower
      ON users (username_lower) WHERE username_lower IS NOT NULL
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_users_account_status
      ON users (account_status)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_users_deletion_scheduled
      ON users (deletion_scheduled_at) WHERE deletion_scheduled_at IS NOT NULL
    ''');

    // Abschnitt 6: Account Linking. Ein PHÖNIX User kann mehrere Auth-
    // Provider verknüpft haben (z.B. zuerst E-Mail+Passwort, später
    // zusätzlich Google) - niemals ein zweites PHÖNIX-Konto für dieselbe
    // E-Mail.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_auth_providers (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id),
        provider TEXT NOT NULL,
        provider_uid TEXT NOT NULL,
        email_at_link TEXT,
        linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (provider IN ('google', 'password')),
        UNIQUE (provider, provider_uid)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_user_auth_providers_user
      ON user_auth_providers (user_id)
    ''');

    // Abschnitt 78: App-seitige Sessions/Geräte, getrennt von den
    // bestehenden `admin_sessions` (Control-Center-Mitarbeiter-Logins).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_sessions (
        token TEXT PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        expires_at TIMESTAMPTZ NOT NULL,
        revoked_at TIMESTAMPTZ,
        ip TEXT,
        user_agent TEXT,
        device_model TEXT,
        platform TEXT,
        app_version TEXT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_user_sessions_user
      ON user_sessions (user_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_user_sessions_expiry
      ON user_sessions (expires_at)
    ''');

    // Abschnitt 28/29: Premiumquellen strikt getrennt speichern - niemals
    // ein einzelnes premium=true. `effective_premium` wird zentral aus
    // aktiven, nicht abgelaufenen Zeilen berechnet (siehe
    // `effectivePremiumForUser` weiter unten), nicht als eigene Spalte
    // dupliziert (würde veralten können).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_premium_entitlements (
        id BIGSERIAL PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES users(id),
        source TEXT NOT NULL,
        active BOOLEAN NOT NULL DEFAULT TRUE,
        tier TEXT,
        starts_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        expires_at TIMESTAMPTZ,
        auto_renew BOOLEAN NOT NULL DEFAULT FALSE,
        cancelled_at TIMESTAMPTZ,
        provider_product_id TEXT,
        provider_purchase_token TEXT,
        provider_reference JSONB NOT NULL DEFAULT '{}',
        granted_by_employee_id BIGINT REFERENCES admin_employees(id),
        reason TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (source IN (
          'GOOGLE_PLAY', 'WEBSITE', 'MANUAL', 'PROMOTION', 'STAFF', 'PARTNER'
        ))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_user_premium_entitlements_user
      ON user_premium_entitlements (user_id, active)
    ''');

    // Abschnitt 44/47/48: Sperrfälle. Sperre bleibt IMMER eine manuelle
    // Mitarbeiteraktion (created_by_employee_id NOT NULL, kein System-Actor
    // möglich) - Anti-Abuse (unten) kann nur markieren, niemals selbst eine
    // Zeile hier erzeugen.
    // `TO_CHAR(timestamptz, ...)` und `EXTRACT(... FROM timestamptz)` sind in
    // Postgres NICHT immutable (Ergebnis hängt von der Session-TimeZone ab)
    // und werden deshalb in einer STORED Generated Column abgelehnt
    // (42P17). `created_at AT TIME ZONE 'UTC'` konvertiert mit einer FEST
    // codierten Zone (kein Session-State) zu `timestamp` und macht den
    // Ausdruck dadurch deterministisch/immutable.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_bans (
        id BIGSERIAL PRIMARY KEY,
        case_number TEXT GENERATED ALWAYS AS (
          'BAN-' || EXTRACT(YEAR FROM (created_at AT TIME ZONE 'UTC'))::text
          || '-' || LPAD(id::text, 5, '0')
        ) STORED,
        user_id BIGINT NOT NULL REFERENCES users(id),
        status TEXT NOT NULL DEFAULT 'ACTIVE',
        reason TEXT NOT NULL,
        internal_report TEXT NOT NULL,
        duration_type TEXT NOT NULL,
        expires_at TIMESTAMPTZ,
        refund_decision TEXT,
        refund_reason TEXT,
        support_ticket_id BIGINT REFERENCES support_tickets(id),
        created_by_employee_id BIGINT NOT NULL REFERENCES admin_employees(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        lifted_by_employee_id BIGINT REFERENCES admin_employees(id),
        lifted_at TIMESTAMPTZ,
        lift_reason TEXT,
        CHECK (status IN ('ACTIVE', 'LIFTED', 'EXPIRED')),
        CHECK (duration_type IN (
          '1_HOUR', '24_HOURS', '7_DAYS', '30_DAYS', 'CUSTOM', 'PERMANENT'
        )),
        CHECK (
          refund_decision IS NULL
          OR refund_decision IN ('NONE', 'PARTIAL', 'FULL', 'CREDIT')
        )
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_user_bans_user
      ON user_bans (user_id, status)
    ''');

    // Abschnitt 59: IP-/Netzwerksperren mit granularem Scope
    // (Registrierung/Trial/Login getrennt blockierbar).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ip_blocks (
        id BIGSERIAL PRIMARY KEY,
        ip TEXT NOT NULL,
        reason TEXT NOT NULL,
        scope JSONB NOT NULL DEFAULT '{}',
        duration_type TEXT NOT NULL,
        expires_at TIMESTAMPTZ,
        status TEXT NOT NULL DEFAULT 'ACTIVE',
        created_by_employee_id BIGINT NOT NULL REFERENCES admin_employees(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        lifted_by_employee_id BIGINT REFERENCES admin_employees(id),
        lifted_at TIMESTAMPTZ,
        CHECK (duration_type IN (
          '24_HOURS', '7_DAYS', '30_DAYS', 'CUSTOM', 'PERMANENT'
        )),
        CHECK (status IN ('ACTIVE', 'LIFTED', 'EXPIRED'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_ip_blocks_ip ON ip_blocks (ip, status)
    ''');

    // Abschnitt 93: additive Verknüpfung, bestehende installation_id-
    // basierte Tickets bleiben unverändert funktionsfähig.
    await db.execute('''
      ALTER TABLE support_tickets
      ADD COLUMN IF NOT EXISTS user_id BIGINT REFERENCES users(id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_support_tickets_user
      ON support_tickets (user_id)
    ''');

    // Abschnitt 16/17/19-21: Mitarbeiter = auch App-Nutzer (optional
    // verknüpfte users-Zeile), Staff-App-Access getrennt von Control-
    // Center-Rechten, verpflichtendes 2FA, Owner/Vize-Owner-genehmigter
    // Passwort-Reset-Workflow statt Selbst-Reset.
    await db.execute('''
      ALTER TABLE admin_employees
      ADD COLUMN IF NOT EXISTS user_id BIGINT REFERENCES users(id)
    ''');
    await db.execute('''
      ALTER TABLE admin_employees
      ADD COLUMN IF NOT EXISTS two_factor_enabled BOOLEAN NOT NULL DEFAULT FALSE
    ''');
    await db.execute('''
      ALTER TABLE admin_employees ADD COLUMN IF NOT EXISTS two_factor_method TEXT
    ''');
    // Section 32 (AN2, "Priorität hoch"): das eigentliche TOTP-Secret - die
    // beiden Spalten oben existierten bereits (vorbereitet, nie genutzt),
    // hier kommt die tatsächliche Implementierung dazu.
    await db.execute('''
      ALTER TABLE admin_employees ADD COLUMN IF NOT EXISTS two_factor_secret TEXT
    ''');
    await db.execute('''
      ALTER TABLE admin_employees
      ADD COLUMN IF NOT EXISTS staff_app_access BOOLEAN NOT NULL DEFAULT FALSE
    ''');
    await db.execute('''
      ALTER TABLE admin_employees
      ADD COLUMN IF NOT EXISTS maintenance_bypass BOOLEAN NOT NULL DEFAULT FALSE
    ''');
    await db.execute('''
      ALTER TABLE admin_employees
      ADD COLUMN IF NOT EXISTS premium_bypass BOOLEAN NOT NULL DEFAULT FALSE
    ''');
    await db.execute('''
      ALTER TABLE admin_employees
      ADD COLUMN IF NOT EXISTS beta_access BOOLEAN NOT NULL DEFAULT FALSE
    ''');
    await db.execute('''
      ALTER TABLE admin_employees
      ADD COLUMN IF NOT EXISTS feature_flag_bypass BOOLEAN NOT NULL DEFAULT FALSE
    ''');
    await db.execute('''
      ALTER TABLE admin_employees ADD COLUMN IF NOT EXISTS password_reset_status TEXT
    ''');
    await db.execute('''
      ALTER TABLE admin_employees
      ADD COLUMN IF NOT EXISTS password_reset_requested_at TIMESTAMPTZ
    ''');
    await db.execute('''
      ALTER TABLE admin_employees ADD COLUMN IF NOT EXISTS password_reset_approved_by
      BIGINT REFERENCES admin_employees(id)
    ''');
    await db.execute('''
      ALTER TABLE admin_employees
      ADD COLUMN IF NOT EXISTS password_reset_approved_at TIMESTAMPTZ
    ''');

    // Abschnitt 15: neue Rollen VICE_OWNER + SECURITY. Postgres kennt kein
    // ALTER CONSTRAINT für CHECKs - sauber ersetzen (idempotent: DROP IF
    // EXISTS + ADD läuft bei jedem Migrationslauf gefahrlos erneut).
    await db.execute('''
      ALTER TABLE admin_employees DROP CONSTRAINT IF EXISTS admin_employees_role_check
    ''');
    await db.execute('''
      ALTER TABLE admin_employees ADD CONSTRAINT admin_employees_role_check
      CHECK (role IN (
        'OWNER', 'VICE_OWNER', 'ADMIN', 'TECHNICAL', 'SUPPORT', 'CONTENT',
        'MARKETING', 'SECURITY'
      ))
    ''');
    await db.execute('''
      ALTER TABLE admin_employees
      DROP CONSTRAINT IF EXISTS admin_employees_password_reset_status_check
    ''');
    await db.execute('''
      ALTER TABLE admin_employees ADD CONSTRAINT admin_employees_password_reset_status_check
      CHECK (
        password_reset_status IS NULL
        OR password_reset_status IN ('REQUESTED', 'APPROVED', 'COMPLETED')
      )
    ''');
  }

  // ===========================================================================
  // PHÖNIX ACCOUNT SYSTEM - Phase 2 (Auth + 18+ + Registrierung + User
  // Profiles). Query-Methoden für `users`/`user_auth_providers`/
  // `user_sessions`, analog zum bestehenden `admin_sessions`-Muster
  // (`createAdminSession`/`adminSessionWithEmployee`/`revokeAdminSession`).
  // ===========================================================================

  /// Abschnitt 6: Auth-Provider-Lookup für einen bereits verifizierten
  /// Firebase-Token (provider + provider_uid). Liefert `null`, wenn dieser
  /// Provider/UID noch mit keinem PHÖNIX-Account verknüpft ist (entweder
  /// komplett neuer Nutzer ODER eine neue Verknüpfung zu einem bestehenden
  /// Account per E-Mail, siehe [userByEmail]).
  Future<Map<String, Object?>?> userByAuthProvider({
    required String provider,
    required String providerUid,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT u.* FROM users u
        JOIN user_auth_providers p ON p.user_id = u.id
        WHERE p.provider = @provider AND p.provider_uid = @provider_uid
        LIMIT 1
      '''),
      parameters: {'provider': provider, 'provider_uid': providerUid},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Abschnitt 6: Lookup per E-Mail (case-insensitive) für Account-Linking -
  /// verhindert ein zweites PHÖNIX-Konto für dieselbe E-Mail-Adresse.
  Future<Map<String, Object?>?> userByEmail(String email) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM users WHERE email_lower = LOWER(@email) LIMIT 1
      '''),
      parameters: {'email': email},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> userById(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT * FROM users WHERE id = @id LIMIT 1'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Abschnitt 6: verknüpft einen zusätzlichen Auth-Provider (z.B. Google)
  /// mit einem bereits bestehenden PHÖNIX-Account (z.B. ursprünglich per
  /// E-Mail+Passwort registriert). `ON CONFLICT DO NOTHING` macht den Aufruf
  /// idempotent, falls derselbe Link-Request retried wird (Abschnitt 84).
  Future<void> linkAuthProvider({
    required int userId,
    required String provider,
    required String providerUid,
    String? emailAtLink,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO user_auth_providers (user_id, provider, provider_uid, email_at_link)
        VALUES (@user_id, @provider, @provider_uid, @email_at_link)
        ON CONFLICT (provider, provider_uid) DO NOTHING
      '''),
      parameters: {
        'user_id': userId,
        'provider': provider,
        'provider_uid': providerUid,
        'email_at_link': emailAtLink,
      },
    );
  }

  /// Abschnitt 3/84: erzeugt einen komplett neuen PHÖNIX-Account + die
  /// verknüpfte Auth-Provider-Zeile ATOMAR in einer Transaktion - entweder
  /// entsteht ein vollständiger Nutzer mit Login-Möglichkeit, oder gar
  /// nichts ("kein halb kaputter User", Abschnitt 84). Die Altersprüfung
  /// selbst passiert VOR diesem Aufruf im Route-Handler (mit
  /// `calculateAge`/`passesAgeGate`), damit unter-18-Anfragen niemals auch
  /// nur transaktional eine Zeile anlegen.
  Future<Map<String, Object?>> createUserAccount({
    required String email,
    required bool emailVerified,
    required DateTime dateOfBirth,
    required String provider,
    required String providerUid,
    String? termsVersion,
    String? privacyVersion,
  }) async {
    final db = await connection();
    return db.runTx((session) async {
      final result = await session.execute(
        Sql.named('''
          INSERT INTO users (
            email, email_verified, date_of_birth, age_gate_passed,
            age_gate_checked_at, account_status, terms_version,
            terms_accepted_at, privacy_version, privacy_accepted_at,
            created_at, updated_at, last_login_at
          ) VALUES (
            @email, @email_verified, @date_of_birth, TRUE, NOW(),
            @account_status, @terms_version,
            CASE WHEN @terms_version IS NULL THEN NULL ELSE NOW() END,
            @privacy_version,
            CASE WHEN @privacy_version IS NULL THEN NULL ELSE NOW() END,
            NOW(), NOW(), NOW()
          )
          RETURNING *
        '''),
        parameters: {
          'email': email,
          'email_verified': emailVerified,
          'date_of_birth':
              dateOfBirth.toUtc().toIso8601String().substring(0, 10),
          // Abschnitt 82: E-Mail bereits vom Provider verifiziert (z.B.
          // Google) -> direkt ACTIVE, sonst erst nach Verifizierung.
          'account_status':
              emailVerified ? 'ACTIVE' : 'PENDING_EMAIL_VERIFICATION',
          'terms_version': termsVersion,
          'privacy_version': privacyVersion,
        },
      );
      final row = Map<String, Object?>.from(result.first.toColumnMap());
      final userId = row['id'] as int;

      await session.execute(
        Sql.named('''
          INSERT INTO user_auth_providers (user_id, provider, provider_uid, email_at_link)
          VALUES (@user_id, @provider, @provider_uid, @email)
        '''),
        parameters: {
          'user_id': userId,
          'provider': provider,
          'provider_uid': providerUid,
          'email': email,
        },
      );

      return row;
    });
  }

  Future<void> touchUserLastLogin(int userId) async {
    final db = await connection();
    await db.execute(
      Sql.named('UPDATE users SET last_login_at = NOW() WHERE id = @id'),
      parameters: {'id': userId},
    );
  }

  Future<void> markUserEmailVerified(int userId) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE users SET
          email_verified = TRUE,
          account_status = CASE
            WHEN account_status = 'PENDING_EMAIL_VERIFICATION' THEN 'ACTIVE'
            ELSE account_status
          END,
          updated_at = NOW()
        WHERE id = @id
      '''),
      parameters: {'id': userId},
    );
  }

  /// Abschnitt 91 "update allowed profile fields" - bewusst eine feste,
  /// kleine Menge selbst änderbarer Felder statt eines generischen
  /// UPDATE-Endpunkts (`date_of_birth`/`account_status`/`account_type`/etc.
  /// sind explizit NICHT hier drin, siehe Abschnitt 4/76).
  Future<Map<String, Object?>?> updateOwnUserProfile({
    required int userId,
    String? username,
    String? displayName,
    String? language,
    String? country,
    Map<String, Object?>? notificationSettings,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE users SET
          username = COALESCE(@username, username),
          username_changed_at = CASE
            WHEN @username IS NOT NULL AND @username IS DISTINCT FROM username
            THEN NOW() ELSE username_changed_at
          END,
          display_name = COALESCE(@display_name, display_name),
          language = COALESCE(@language, language),
          country = COALESCE(@country, country),
          notification_settings = COALESCE(@notification_settings, notification_settings),
          updated_at = NOW()
        WHERE id = @id
        RETURNING *
      '''),
      parameters: {
        'id': userId,
        'username': username,
        'display_name': displayName,
        'language': language,
        'country': country,
        'notification_settings': notificationSettings == null
            ? null
            : jsonEncode(notificationSettings),
      },
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<bool> isUsernameTaken(String username, {int? excludingUserId}) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT 1 FROM users
        WHERE username_lower = LOWER(@username)
        AND (@excluding_user_id IS NULL OR id != @excluding_user_id)
        LIMIT 1
      '''),
      parameters: {'username': username, 'excluding_user_id': excludingUserId},
    );
    return result.isNotEmpty;
  }

  // --- App-seitige Sessions (Abschnitt 78, analog admin_sessions) --------

  Future<void> createUserSession({
    required int userId,
    required String token,
    required DateTime expiresAt,
    String? ip,
    String? userAgent,
    String? deviceModel,
    String? platform,
    String? appVersion,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO user_sessions (
          token, user_id, expires_at, ip, user_agent, device_model,
          platform, app_version
        ) VALUES (
          @token, @user_id, @expires_at, @ip, @user_agent, @device_model,
          @platform, @app_version
        )
      '''),
      parameters: {
        'token': token,
        'user_id': userId,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'ip': ip,
        'user_agent': userAgent,
        'device_model': deviceModel,
        'platform': platform,
        'app_version': appVersion,
      },
    );
  }

  /// Analog `adminSessionWithEmployee` - eine Abfrage für Session +
  /// zugehöriges Nutzerprofil, für den App-Auth-Guard.
  Future<Map<String, Object?>?> userSessionWithProfile(String token) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          u.*,
          s.token AS session_token,
          s.expires_at AS session_expires_at,
          s.revoked_at AS session_revoked_at
        FROM user_sessions s
        JOIN users u ON u.id = s.user_id
        WHERE s.token = @token
        LIMIT 1
      '''),
      parameters: {'token': token},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<void> revokeUserSession(String token) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE user_sessions SET revoked_at = NOW()
        WHERE token = @token AND revoked_at IS NULL
      '''),
      parameters: {'token': token},
    );
  }

  /// Abschnitt 78: "Alle anderen Geräte abmelden" - widerruft jede Session
  /// des Nutzers außer der aktuell verwendeten.
  Future<void> revokeOtherUserSessions({
    required int userId,
    required String exceptToken,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE user_sessions SET revoked_at = NOW()
        WHERE user_id = @user_id AND token != @except_token AND revoked_at IS NULL
      '''),
      parameters: {'user_id': userId, 'except_token': exceptToken},
    );
  }

  Future<List<Map<String, Object?>>> listUserSessions(int userId) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT token, created_at, expires_at, revoked_at, ip, user_agent,
          device_model, platform, app_version
        FROM user_sessions
        WHERE user_id = @user_id
        ORDER BY created_at DESC
      '''),
      parameters: {'user_id': userId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// PHÖNIX CONTROL CENTER PHASE 2 (Football-Domain-Admin-APIs, additiv):
  /// Pro-Match-Steuerflags für Matches/Teams/Wappen-Verwaltung. Rein additiv
  /// über `ADD COLUMN IF NOT EXISTS` mit `DEFAULT TRUE`, damit bestehende
  /// Zeilen unverändert das bisherige Produktionsverhalten behalten, bis ein
  /// Admin ein Flag aktiv umschaltet. Löscht oder überschreibt keine
  /// bestehenden Spalten.
  /// `ALTER TABLE ADD COLUMN` needs an ACCESS EXCLUSIVE lock, which briefly
  /// blocks on any other open transaction touching `football_matches` (the
  /// most actively-written table in this app - scans, settlement, etc.). A
  /// short `SET LOCAL lock_timeout` means a busy moment fails fast with a
  /// catchable error (caught by the caller in `migrate()`'s try/catch, server
  /// still starts) instead of hanging past the Railway healthcheck window and
  /// taking the whole deploy down. Safe to just retry `migrate()` (next
  /// server start, or `POST /api/admin/migrate`) once the table is quieter -
  /// the `ADD COLUMN IF NOT EXISTS` itself stays fully idempotent.
  /// Fund während des "alles muss laufen"-Audits: die Live-Produktions-
  /// Tabelle `football_assets` wurde ursprünglich mit den Spalten
  /// `entity_type`/`entity_id`/`image_bytes`/`size_bytes` angelegt. Der
  /// aktuelle Code (CREATE TABLE weiter oben, alle Queries) erwartet aber
  /// `asset_type`/`asset_id`/`content` - ein Schema-Drift, vermutlich aus
  /// einer früheren, nie nachgezogenen Umbenennung. `CREATE TABLE IF NOT
  /// EXISTS` verändert eine bereits existierende Tabelle nicht, deshalb blieb
  /// das unbemerkt: `GET /api/admin/football/assets` warf 500
  /// ("column a.asset_type does not exist"), und `saveFootballAsset()`
  /// (Cache-Schreibpfad) schlug vermutlich seit dieser Divergenz immer fehl -
  /// abgefangen durch den bewusst resilienten Fallback in
  /// `FootballAssetService.serve()`, der bei einem Cache-Fehler einfach vom
  /// Original-Quell-URL ausliefert. Bilder waren dadurch nie für Endnutzer
  /// sichtbar kaputt, nur der eigene Cache wurde nie erfolgreich befüllt.
  ///
  /// RENAME COLUMN ist eine reine Katalog-Änderung (kein Table-Rewrite,
  /// keine Downtime) und erhält alle 191 bereits gecachten Bilder. Die
  /// PRIMARY-KEY-Definition folgt der Spaltenumbenennung automatisch.
  /// `size_bytes` wird nullable, weil kein aktueller Code diese Spalte noch
  /// befüllt (nicht gelöscht, um nichts Bestehendes zu zerstören).
  Future<void> _migrateFootballAssetsSchema(Connection db) async {
    await db.runTx((session) async {
      await session.execute("SET LOCAL lock_timeout = '5s'");
      await session.execute('''
        DO \$\$
        BEGIN
          IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'football_assets' AND column_name = 'entity_type'
          ) THEN
            ALTER TABLE football_assets RENAME COLUMN entity_type TO asset_type;
          END IF;
          IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'football_assets' AND column_name = 'entity_id'
          ) THEN
            ALTER TABLE football_assets RENAME COLUMN entity_id TO asset_id;
          END IF;
          IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'football_assets' AND column_name = 'image_bytes'
          ) THEN
            ALTER TABLE football_assets RENAME COLUMN image_bytes TO content;
          END IF;
          IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_name = 'football_assets' AND column_name = 'size_bytes'
              AND is_nullable = 'NO'
          ) THEN
            ALTER TABLE football_assets ALTER COLUMN size_bytes DROP NOT NULL;
          END IF;
        END \$\$;
      ''');
    });
  }

  Future<void> _migrateFootballMatchControls(Connection db) async {
    await db.runTx((session) async {
      await session.execute("SET LOCAL lock_timeout = '5s'");
      await session.execute('''
        ALTER TABLE football_matches
          ADD COLUMN IF NOT EXISTS visible BOOLEAN NOT NULL DEFAULT TRUE,
          ADD COLUMN IF NOT EXISTS analysis_enabled BOOLEAN NOT NULL DEFAULT TRUE,
          ADD COLUMN IF NOT EXISTS tip_enabled BOOLEAN NOT NULL DEFAULT TRUE,
          ADD COLUMN IF NOT EXISTS learning_enabled BOOLEAN NOT NULL DEFAULT TRUE,
          ADD COLUMN IF NOT EXISTS live_enabled BOOLEAN NOT NULL DEFAULT TRUE,
          ADD COLUMN IF NOT EXISTS status_locked BOOLEAN NOT NULL DEFAULT FALSE,
          ADD COLUMN IF NOT EXISTS status_lock_reason TEXT,
          ADD COLUMN IF NOT EXISTS status_locked_by_employee_id BIGINT,
          ADD COLUMN IF NOT EXISTS status_locked_at TIMESTAMPTZ
      ''');
    });
  }

  /// PHÖNIX CONTROL CENTER (internes Admin-Webapp-Backend, additiv): eigene
  /// Mitarbeiter-/Session-/Audit-Tabellen, komplett getrennt vom bestehenden
  /// statischen `PHOENIX_ADMIN_TOKEN`, das weiterhin unverändert für die
  /// bestehenden `/api/admin/*`-Routen genutzt wird. Verändert oder löscht
  /// keine bestehenden PHÖNIX-Produktionsdaten.
  Future<void> _migrateControlCenter(Connection db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS admin_employees (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        login TEXT NOT NULL UNIQUE,
        email TEXT NOT NULL UNIQUE,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL,
        permission_overrides JSONB NOT NULL DEFAULT '{}',
        department TEXT,
        status TEXT NOT NULL DEFAULT 'active',
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        last_login_at TIMESTAMPTZ,
        CHECK (role IN ('OWNER', 'ADMIN', 'TECHNICAL', 'SUPPORT', 'CONTENT', 'MARKETING')),
        CHECK (status IN ('active', 'disabled'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_admin_employees_login
      ON admin_employees (login)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_admin_employees_role_status
      ON admin_employees (role, status)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS admin_sessions (
        token TEXT PRIMARY KEY,
        employee_id BIGINT NOT NULL REFERENCES admin_employees(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        expires_at TIMESTAMPTZ NOT NULL,
        revoked_at TIMESTAMPTZ,
        ip TEXT,
        user_agent TEXT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_admin_sessions_employee
      ON admin_sessions (employee_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_admin_sessions_expiry
      ON admin_sessions (expires_at)
    ''');

    // Section 32 (AN2): Kurzlebiger Zwischenzustand "Passwort korrekt, TOTP
    // noch ausstehend" - erst nach erfolgreicher Code-Prüfung entsteht eine
    // echte admin_sessions-Zeile. Single-Use (wird bei Verbrauch gelöscht).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS admin_pending_two_factor_logins (
        token TEXT PRIMARY KEY,
        employee_id BIGINT NOT NULL REFERENCES admin_employees(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        expires_at TIMESTAMPTZ NOT NULL,
        ip TEXT,
        user_agent TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS admin_audit_log (
        id BIGSERIAL PRIMARY KEY,
        employee_id BIGINT REFERENCES admin_employees(id),
        employee_login TEXT,
        area TEXT NOT NULL,
        object_type TEXT,
        object_id TEXT,
        action TEXT NOT NULL,
        previous_value JSONB,
        new_value JSONB,
        reason TEXT,
        comment TEXT,
        ip TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        reverted BOOLEAN NOT NULL DEFAULT FALSE,
        reverted_at TIMESTAMPTZ
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_admin_audit_log_created
      ON admin_audit_log (created_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_admin_audit_log_area
      ON admin_audit_log (area, created_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_admin_audit_log_employee
      ON admin_audit_log (employee_id, created_at DESC)
    ''');

    // Single-row App-Status (Section 39/81: ACTIVE/MAINTENANCE/DISABLED).
    // Wird inzwischen von phoenixflt gelesen (fetchRemoteStatus(), Stand
    // 2026-08-19) - betrifft aber ausschließlich, was in der App angezeigt
    // wird. Kein Backend-Job (Daily Pipeline, Settlement, Live-Monitor)
    // prüft diesen Status; Backend-Arbeit läuft unabhängig weiter
    // (Section 22 AN2: "klar unterscheiden").
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_control_state (
        id INTEGER PRIMARY KEY DEFAULT 1,
        status TEXT NOT NULL DEFAULT 'ACTIVE',
        message TEXT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_by TEXT,
        CHECK (id = 1),
        CHECK (status IN ('ACTIVE', 'MAINTENANCE', 'DISABLED'))
      )
    ''');
    await db.execute('''
      INSERT INTO app_control_state (id, status)
      VALUES (1, 'ACTIVE')
      ON CONFLICT (id) DO NOTHING
    ''');
    // Section 22 (AN2): "Wartungsmodus mit ... geplantem Ende" - rein
    // informativ, kein automatischer Rückschalter dahinter.
    await db.execute('''
      ALTER TABLE app_control_state
      ADD COLUMN IF NOT EXISTS maintenance_until TIMESTAMPTZ
    ''');
  }

  /// PHÖNIX CONTROL CENTER Phase 4 (Section 22-25, additiv): Support-Tickets.
  /// PHÖNIX hat bisher KEIN Nutzerkonto-System (nur anonyme
  /// installation_id-Geräte über push_devices, siehe Migration weiter oben) -
  /// Tickets werden deshalb an installation_id statt an einen Nutzer-Account
  /// geknüpft. Sobald echte Accounts existieren, kann eine Migration die
  /// bestehenden Tickets nachträglich verknüpfen.
  Future<void> _migrateSupport(Connection db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS support_tickets (
        id BIGSERIAL PRIMARY KEY,
        installation_id TEXT NOT NULL REFERENCES push_devices(installation_id),
        category TEXT NOT NULL DEFAULT 'sonstiges',
        subject TEXT NOT NULL,
        message TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'NEU',
        priority TEXT NOT NULL DEFAULT 'normal',
        assigned_employee_id BIGINT REFERENCES admin_employees(id),
        app_version TEXT,
        platform TEXT,
        os_version TEXT,
        device_model TEXT,
        match_id TEXT,
        screen TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (status IN ('NEU', 'IN_BEARBEITUNG', 'WARTET_AUF_NUTZER', 'GELOEST', 'GESCHLOSSEN')),
        CHECK (category IN ('frage', 'bug', 'premium', 'match', 'sonstiges')),
        CHECK (priority IN ('niedrig', 'normal', 'hoch', 'dringend'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_support_tickets_installation
      ON support_tickets (installation_id, created_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_support_tickets_status
      ON support_tickets (status, created_at DESC)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS support_ticket_messages (
        id BIGSERIAL PRIMARY KEY,
        ticket_id BIGINT NOT NULL REFERENCES support_tickets(id),
        author_type TEXT NOT NULL,
        employee_id BIGINT REFERENCES admin_employees(id),
        message TEXT NOT NULL,
        internal_note BOOLEAN NOT NULL DEFAULT FALSE,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (author_type IN ('user', 'employee'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_support_ticket_messages_ticket
      ON support_ticket_messages (ticket_id, created_at ASC)
    ''');
  }

  /// PHÖNIX CONTROL CENTER Phase 5 (Section 30-32/46, additiv): manuell
  /// verfasste News (getrennt von `news_articles`, das ausschließlich
  /// importierte Publisher-Artikel und automatisch generierte Phoenix-
  /// Berichte via `PhoenixEditorialComposer` enthält - siehe
  /// football_news_service.dart), FAQ, Werbekampagnen, Push-Broadcasts und
  /// die Premium-Feature-Matrix.
  Future<void> _migrateContent(Connection db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_editorial_articles (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        summary TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT 'allgemein',
        image_url TEXT,
        author_employee_id BIGINT REFERENCES admin_employees(id),
        status TEXT NOT NULL DEFAULT 'DRAFT',
        homepage_feature BOOLEAN NOT NULL DEFAULT FALSE,
        breaking BOOLEAN NOT NULL DEFAULT FALSE,
        send_push BOOLEAN NOT NULL DEFAULT FALSE,
        push_sent_at TIMESTAMPTZ,
        scheduled_at TIMESTAMPTZ,
        published_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (status IN ('DRAFT', 'SCHEDULED', 'PUBLISHED', 'HIDDEN', 'ARCHIVED'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_editorial_articles_status
      ON phoenix_editorial_articles (status, published_at DESC)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_faq_articles (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT 'allgemein',
        position INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'DRAFT',
        author_employee_id BIGINT REFERENCES admin_employees(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (status IN ('DRAFT', 'PUBLISHED', 'ARCHIVED'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_faq_articles_status
      ON phoenix_faq_articles (status, category, position)
    ''');

    // Section 32: Slots sind serverseitig fest vordefiniert (nicht frei
    // wählbar) - die App entscheidet, welche Slots sie überhaupt rendert.
    // Noch nicht in der Flutter-App verdrahtet (out of scope), deshalb rein
    // additiv und ohne Verhaltensänderung.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ad_campaigns (
        id BIGSERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        slot TEXT NOT NULL,
        image_url TEXT NOT NULL,
        link_url TEXT NOT NULL,
        active BOOLEAN NOT NULL DEFAULT TRUE,
        start_date DATE,
        end_date DATE,
        target_country TEXT,
        target_audience TEXT NOT NULL DEFAULT 'ALL',
        impressions BIGINT NOT NULL DEFAULT 0,
        clicks BIGINT NOT NULL DEFAULT 0,
        created_by_employee_id BIGINT REFERENCES admin_employees(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (slot IN ('home_banner', 'match_detail_infeed', 'news_infeed')),
        CHECK (target_audience IN ('ALL', 'FREE', 'PREMIUM'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_ad_campaigns_slot_active
      ON ad_campaigns (slot, active)
    ''');
    // Section 21 (AN2): "Kampagnen brauchen ... Budget, Frequency Cap" -
    // reine Planungsfelder, solange die App keinen Ad-Slot ausliest (kein
    // Ausgaben-Tracking, keine echte Impressions-Deckelung dahinter).
    await db.execute('''
      ALTER TABLE ad_campaigns
      ADD COLUMN IF NOT EXISTS budget_amount NUMERIC,
      ADD COLUMN IF NOT EXISTS frequency_cap_per_day INTEGER
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS push_broadcasts (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        target_type TEXT NOT NULL,
        target_value TEXT,
        sent_count INTEGER NOT NULL DEFAULT 0,
        failed_count INTEGER NOT NULL DEFAULT 0,
        sent_by_employee_id BIGINT REFERENCES admin_employees(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (target_type IN ('all', 'league'))
      )
    ''');
    // Section 19 (AN2): Deep Link (mit in den FCM-data-Payload gepackt) und
    // Zeitplanung. scheduled_at gesetzt + sent_at NULL = wartet noch auf den
    // PushScheduleService; sent_at wird sowohl beim sofortigen Versand als
    // auch beim geplanten Versand gesetzt, sobald tatsächlich gesendet wurde.
    await db.execute('''
      ALTER TABLE push_broadcasts
      ADD COLUMN IF NOT EXISTS deep_link_url TEXT,
      ADD COLUMN IF NOT EXISTS scheduled_at TIMESTAMPTZ,
      ADD COLUMN IF NOT EXISTS sent_at TIMESTAMPTZ
    ''');

    // Section 46: nur bereits implementierte Features können hier
    // umklassifiziert werden. Die App liest diese Matrix noch nicht (out of
    // scope) - Zweck aktuell: Backend/Admin-Seite vorbereiten.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS premium_feature_matrix (
        feature_key TEXT PRIMARY KEY,
        feature_label TEXT NOT NULL,
        tier TEXT NOT NULL DEFAULT 'FREE',
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_by TEXT,
        CHECK (tier IN ('FREE', 'PREMIUM', 'DISABLED'))
      )
    ''');
    await db.execute('''
      INSERT INTO premium_feature_matrix (feature_key, feature_label, tier) VALUES
        ('all_tips', 'Alle Tipps', 'FREE'),
        ('advanced_analysis', 'Erweiterte Analyse', 'PREMIUM'),
        ('history', 'Historie', 'PREMIUM'),
        ('phoenix_live', 'PHÖNIX Live', 'FREE'),
        ('historical_twins', 'Historical Twins', 'PREMIUM')
      ON CONFLICT (feature_key) DO NOTHING
    ''');
  }

  /// PHÖNIX CONTROL CENTER Phase 6 (Section 42-45/52/74, additiv):
  /// Feature Flags (deckt auch Rollout/Staging ab, Section 42-44),
  /// Release-Konfiguration (Section 45), Incidents (Section 52) und
  /// fehlgeschlagene Login-Versuche (Section 13, Sicherheits-Vorbereitung).
  Future<void> _migrateOps(Connection db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS feature_flags (
        flag_key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        enabled BOOLEAN NOT NULL DEFAULT FALSE,
        rollout_percentage INTEGER NOT NULL DEFAULT 0,
        audience TEXT NOT NULL DEFAULT 'ALL',
        stage TEXT NOT NULL DEFAULT 'STAGING',
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_by TEXT,
        CHECK (rollout_percentage BETWEEN 0 AND 100),
        CHECK (audience IN ('ALL', 'FREE', 'PREMIUM', 'BETA', 'CUSTOM_SEGMENT')),
        CHECK (stage IN ('STAGING', 'PRODUCTION'))
      )
    ''');

    // Section 45: Single-Row-Konfiguration für Mindestversion/aktuelle
    // Version. Kein echtes Nutzer-pro-Version-Tracking - dafür gibt es keine
    // Telemetrie (siehe app_version nur als Freitext auf Support-Tickets).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_release_config (
        id INTEGER PRIMARY KEY DEFAULT 1,
        current_version TEXT,
        minimum_supported_version TEXT,
        forced_update BOOLEAN NOT NULL DEFAULT FALSE,
        changelog TEXT NOT NULL DEFAULT '',
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_by TEXT,
        CHECK (id = 1)
      )
    ''');
    // Section 24 (AN2): "App-Kompatibilität" - Mindest-Betriebssystemversion
    // je Plattform, rein informativ vom Admin gepflegt (keine Store-API
    // angebunden, die das automatisch liefern könnte).
    await db.execute('''
      ALTER TABLE app_release_config
      ADD COLUMN IF NOT EXISTS minimum_os_android TEXT,
      ADD COLUMN IF NOT EXISTS minimum_os_ios TEXT
    ''');
    await db.execute('''
      INSERT INTO app_release_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS incidents (
        id BIGSERIAL PRIMARY KEY,
        title TEXT NOT NULL,
        severity TEXT NOT NULL DEFAULT 'minor',
        status TEXT NOT NULL DEFAULT 'OPEN',
        affected_systems TEXT NOT NULL DEFAULT '',
        responsible_employee_id BIGINT REFERENCES admin_employees(id),
        actions_taken TEXT NOT NULL DEFAULT '',
        postmortem TEXT NOT NULL DEFAULT '',
        started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ended_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (severity IN ('minor', 'major', 'critical')),
        CHECK (status IN ('OPEN', 'MONITORING', 'RESOLVED'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_incidents_status
      ON incidents (status, started_at DESC)
    ''');
    // Section 27 (AN2): "Auswirkungen" (impact_description, getrennt von
    // affected_systems - dort steht WAS kaputt war, hier WIE es Nutzer
    // getroffen hat) sowie freitextige Verknüpfung zu Jobs/API-Ausfällen
    // und zu bereits verschickter Nutzerkommunikation. Freitext bewusst
    // statt einer festen Fremdschlüssel-Beziehung: Jobs verteilen sich auf
    // drei unterschiedliche Tabellen ohne gemeinsames ID-Schema, und ein
    // API-Ausfall ist kein eigenständig erfasstes Ereignis.
    await db.execute('''
      ALTER TABLE incidents
      ADD COLUMN IF NOT EXISTS impact_description TEXT NOT NULL DEFAULT '',
      ADD COLUMN IF NOT EXISTS related_jobs_note TEXT NOT NULL DEFAULT '',
      ADD COLUMN IF NOT EXISTS communication_note TEXT NOT NULL DEFAULT ''
    ''');
    // Section 27 (AN2): "Timeline" - chronologische Einzeleinträge während
    // eines Incidents, zusätzlich zu Beginn/Ende.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS incident_timeline_events (
        id BIGSERIAL PRIMARY KEY,
        incident_id BIGINT NOT NULL REFERENCES incidents(id),
        occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        note TEXT NOT NULL,
        created_by_employee_id BIGINT REFERENCES admin_employees(id),
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_incident_timeline_events_incident
      ON incident_timeline_events (incident_id, occurred_at)
    ''');

    // Section 28 (AN2): "Größenverlauf" - ein Snapshot pro Seitenaufruf der
    // Database-/System-Health-Seite (siehe recordDatabaseSizeSnapshot()).
    await db.execute('''
      CREATE TABLE IF NOT EXISTS database_size_snapshots (
        id BIGSERIAL PRIMARY KEY,
        size_bytes BIGINT NOT NULL,
        recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_database_size_snapshots_recorded
      ON database_size_snapshots (recorded_at DESC)
    ''');

    // Section 13: Sicherheits-Vorbereitung. Noch kein 2FA/Login-Historie-UI,
    // aber fehlgeschlagene Login-Versuche werden ab jetzt festgehalten, damit
    // spätere Sicherheitswarnungen echte Daten haben statt bei Null zu
    // starten.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS admin_failed_logins (
        id BIGSERIAL PRIMARY KEY,
        login TEXT NOT NULL,
        ip TEXT,
        attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_admin_failed_logins_login
      ON admin_failed_logins (login, attempted_at DESC)
    ''');
  }

  /// PHÖNIX CONTROL CENTER "Module Control" (Section 40, additiv). Anders
  /// als `app_control_state` (App-weiter Status) sind das per-Subsystem-
  /// Schalter. `enforced_in_backend = TRUE` heißt: der Schalter wird
  /// tatsächlich von Backend-Code geprüft (siehe moduleEnabled()-Aufrufe in
  /// football_favorite_live_monitor.dart, routes.dart, model_lab_routes.dart)
  /// - nicht nur UI. Für `FALSE`-Module existiert der Schalter zwar, aber
  /// noch keine Verhaltenskopplung; das UI zeigt das ehrlich an statt eine
  /// Wirkung vorzutäuschen (Section 89).
  Future<void> _migrateModuleControl(Connection db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS module_control (
        module_key TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        enabled BOOLEAN NOT NULL DEFAULT TRUE,
        enforced_in_backend BOOLEAN NOT NULL DEFAULT FALSE,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_by TEXT
      )
    ''');
    await db.execute('''
      INSERT INTO module_control (module_key, label, description, enforced_in_backend) VALUES
        ('phoenix_live', 'PHÖNIX Live', 'Live-Event-Polling (alle 5s je verfolgtem Match) + Live-Push. Aus = Polling stoppt sofort, spart API-Budget.', TRUE),
        ('settlement', 'Settlement', 'Ergebnis-/Tipp-Abrechnung. Aus = manuelle und geplante Settlement-Läufe werden abgelehnt.', TRUE),
        ('model_lab_learning', 'Model Lab Learning', 'Manuelle und geplante Learning-Runs. Aus = Läufe werden abgelehnt, bestehende Champions bleiben unberührt.', TRUE),
        ('historical_twins', 'Historical Twins', 'Informationelle Historical-Twins-Anzeige (Gewicht 0, kein Einfluss auf Analyse/Tipp/Learning). Aus = GET /api/football/historical-twins/<id> liefert 503.', TRUE),
        ('news', 'News', 'Manuell verfasste PHÖNIX-News (Control-Center-CMS, /api/news/phoenix). Aus = liefert eine leere Liste. Betrifft NICHT den importierten Publisher-Feed unter /api/news.', TRUE),
        ('advertising', 'Werbung', 'Ausspielung von Werbekampagnen (/api/ads/<slot>). Aus = liefert keine Kampagnen für keinen Slot.', TRUE)
      ON CONFLICT (module_key) DO NOTHING
    ''');
    // Bestehende Railway-Datenbanken haben diese Zeilen ggf. schon mit dem
    // alten enforced_in_backend=FALSE angelegt (ON CONFLICT DO NOTHING oben
    // greift dort nicht mehr) - hier retroaktiv korrigieren, jetzt wo die
    // drei Endpunkte den Schalter tatsächlich prüfen.
    await db.execute('''
      UPDATE module_control SET enforced_in_backend = TRUE
      WHERE module_key IN ('historical_twins', 'news', 'advertising')
    ''');
  }

  Future<bool> moduleEnabled(String moduleKey) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT enabled FROM module_control WHERE module_key = @key'),
      parameters: {'key': moduleKey},
    );
    if (result.isEmpty) return true;
    return result.first[0] as bool;
  }

  Future<List<Map<String, Object?>>> listModuleControls() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT module_key, label, description, enabled, enforced_in_backend,
        updated_at::text AS updated_at, updated_by
      FROM module_control
      ORDER BY label
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<Map<String, Object?>?> updateModuleControl({
    required String moduleKey,
    required bool enabled,
    required String updatedBy,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE module_control SET enabled = @enabled, updated_at = NOW(), updated_by = @updated_by
        WHERE module_key = @module_key
        RETURNING module_key, label, description, enabled, enforced_in_backend,
          updated_at::text AS updated_at, updated_by
      '''),
      parameters: {
        'module_key': moduleKey,
        'enabled': enabled,
        'updated_by': updatedBy
      },
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// System-Audit-Historie (Section 76 "Historie"). Jeder `/system-audit`-
  /// Aufruf wird hier abgelegt, damit die bisher leere "Historie"-Ansicht
  /// echte, vergangene Berichte zeigen kann statt nur den aktuellen On-
  /// Demand-Lauf.
  Future<void> _migrateSystemAuditHistory(Connection db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS system_audit_runs (
        id BIGSERIAL PRIMARY KEY,
        critical_count INTEGER NOT NULL,
        warning_count INTEGER NOT NULL,
        report_text TEXT NOT NULL,
        generated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_system_audit_runs_generated
      ON system_audit_runs (generated_at DESC)
    ''');
  }

  Future<Map<String, Object?>> saveSystemAuditRun({
    required int criticalCount,
    required int warningCount,
    required String reportText,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO system_audit_runs (critical_count, warning_count, report_text)
        VALUES (@critical_count, @warning_count, @report_text)
        RETURNING id, critical_count, warning_count, report_text,
          generated_at::text AS generated_at
      '''),
      parameters: {
        'critical_count': criticalCount,
        'warning_count': warningCount,
        'report_text': reportText,
      },
    );
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> listSystemAuditRuns(
      {int limit = 50}) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT id, critical_count, warning_count, report_text,
          generated_at::text AS generated_at
        FROM system_audit_runs
        ORDER BY generated_at DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit.clamp(1, 200)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// PHÖNIX MODEL LAB (Self-Learning Engine V0). Rein additive Tabellen für
  /// Model Registry, Learning Runs, Evaluationen, Shadow Predictions,
  /// Monthly Reviews und Audit Log. Verändert oder löscht keine bestehenden
  /// PHÖNIX-Produktionsdaten (Section 87).
  Future<void> _migrateModelLab(Connection db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_model_versions (
        id BIGSERIAL PRIMARY KEY,
        readable_version TEXT NOT NULL,
        parent_model_id BIGINT REFERENCES phoenix_model_versions(id),
        generation INTEGER NOT NULL DEFAULT 1,
        league_id TEXT REFERENCES football_leagues(league_id),
        market TEXT NOT NULL,
        model_type TEXT NOT NULL DEFAULT 'weight_variant',
        feature_config JSONB NOT NULL DEFAULT '{}',
        weights JSONB NOT NULL DEFAULT '{}',
        training_start TIMESTAMPTZ,
        training_end TIMESTAMPTZ,
        training_count INTEGER NOT NULL DEFAULT 0,
        validation_count INTEGER NOT NULL DEFAULT 0,
        holdout_count INTEGER NOT NULL DEFAULT 0,
        shadow_count INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        status TEXT NOT NULL DEFAULT 'challenger',
        champion_since TIMESTAMPTZ,
        last_promotion_at TIMESTAMPTZ,
        minimum_observation_period_days INTEGER NOT NULL DEFAULT 14,
        previous_champion_id BIGINT REFERENCES phoenix_model_versions(id),
        rollback_model_id BIGINT REFERENCES phoenix_model_versions(id),
        config_hash TEXT NOT NULL,
        code_schema_version TEXT NOT NULL,
        evaluation_summary JSONB NOT NULL DEFAULT '{}',
        CHECK (model_type IN ('global_baseline', 'weight_variant')),
        CHECK (status IN ('champion', 'challenger', 'retired', 'rejected'))
      )
    ''');

    // Genau ein aktiver Champion je Liga (NULL = Global) x Markt.
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_phoenix_model_versions_one_champion
      ON phoenix_model_versions (market, COALESCE(league_id, '__GLOBAL__'))
      WHERE status = 'champion'
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_phoenix_model_versions_config_hash
      ON phoenix_model_versions (market, COALESCE(league_id, '__GLOBAL__'), config_hash)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_model_versions_scope
      ON phoenix_model_versions (league_id, market, status)
    ''');

    // Append-only Zuweisungs-Historie (Section 59: phoenix_model_assignments).
    // Die aktuell gültige Zuweisung ergibt sich aus
    // phoenix_model_versions.status = 'champion' (Single Source of Truth,
    // siehe eindeutigem Index oben); diese Tabelle protokolliert jede
    // Änderung zusätzlich chronologisch und auditierbar.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_model_assignments (
        id BIGSERIAL PRIMARY KEY,
        league_id TEXT,
        market TEXT NOT NULL,
        model_version_id BIGINT NOT NULL REFERENCES phoenix_model_versions(id),
        is_global BOOLEAN NOT NULL DEFAULT FALSE,
        assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_model_assignments_scope
      ON phoenix_model_assignments (market, league_id, assigned_at DESC)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_learning_runs (
        id BIGSERIAL PRIMARY KEY,
        started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        completed_at TIMESTAMPTZ,
        status TEXT NOT NULL DEFAULT 'running',
        trigger_type TEXT NOT NULL DEFAULT 'manual',
        current_step TEXT NOT NULL DEFAULT 'created',
        leagues_processed INTEGER NOT NULL DEFAULT 0,
        markets_processed INTEGER NOT NULL DEFAULT 0,
        eligible_matches INTEGER NOT NULL DEFAULT 0,
        excluded_matches INTEGER NOT NULL DEFAULT 0,
        exclusions_by_reason JSONB NOT NULL DEFAULT '{}',
        challengers_created INTEGER NOT NULL DEFAULT 0,
        errors JSONB NOT NULL DEFAULT '[]',
        summary JSONB NOT NULL DEFAULT '{}',
        CHECK (status IN ('running', 'completed', 'failed')),
        CHECK (trigger_type IN ('scheduled', 'manual'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_learning_runs_started
      ON phoenix_learning_runs (started_at DESC)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_learning_candidates (
        id BIGSERIAL PRIMARY KEY,
        learning_run_id BIGINT NOT NULL REFERENCES phoenix_learning_runs(id),
        model_version_id BIGINT NOT NULL REFERENCES phoenix_model_versions(id),
        league_id TEXT,
        market TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'created',
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_learning_candidates_run
      ON phoenix_learning_candidates (learning_run_id)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_model_evaluations (
        id BIGSERIAL PRIMARY KEY,
        model_version_id BIGINT NOT NULL REFERENCES phoenix_model_versions(id),
        compared_against_model_id BIGINT REFERENCES phoenix_model_versions(id),
        league_id TEXT,
        market TEXT NOT NULL,
        evaluation_type TEXT NOT NULL,
        match_scope TEXT NOT NULL DEFAULT 'all',
        sample_size INTEGER NOT NULL DEFAULT 0,
        brier_score DOUBLE PRECISION,
        log_loss DOUBLE PRECISION,
        calibration JSONB NOT NULL DEFAULT '[]',
        accuracy DOUBLE PRECISION,
        roi DOUBLE PRECISION,
        avg_probability DOUBLE PRECISION,
        uncertainty JSONB NOT NULL DEFAULT '{}',
        period_start TIMESTAMPTZ,
        period_end TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        CHECK (evaluation_type IN ('walk_forward', 'holdout', 'shadow', 'monthly_review')),
        CHECK (match_scope IN ('all', 'clean'))
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_model_evaluations_model
      ON phoenix_model_evaluations (model_version_id, evaluation_type)
    ''');

    // Storage-bewusst (Section 82): Shadow Predictions referenzieren den
    // bereits vorhandenen Pre-Match-Snapshot über phase_two_scan_run_id +
    // fixture_id, statt den kompletten JSON-Payload zu duplizieren.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_shadow_predictions (
        id BIGSERIAL PRIMARY KEY,
        model_version_id BIGINT NOT NULL REFERENCES phoenix_model_versions(id),
        fixture_id TEXT NOT NULL,
        league_id TEXT NOT NULL,
        market TEXT NOT NULL,
        phase_two_scan_run_id BIGINT,
        predicted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        kickoff TIMESTAMPTZ,
        predicted_before_kickoff BOOLEAN NOT NULL DEFAULT TRUE,
        class_labels JSONB NOT NULL,
        class_probabilities JSONB NOT NULL,
        settled BOOLEAN NOT NULL DEFAULT FALSE,
        outcome_index INTEGER,
        brier_score DOUBLE PRECISION,
        log_loss DOUBLE PRECISION,
        settled_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (model_version_id, fixture_id, market)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_shadow_predictions_fixture
      ON phoenix_shadow_predictions (fixture_id, market)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_shadow_predictions_settlement
      ON phoenix_shadow_predictions (settled, kickoff)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_monthly_reviews (
        id BIGSERIAL PRIMARY KEY,
        review_year INTEGER NOT NULL,
        review_month INTEGER NOT NULL,
        league_id TEXT,
        market TEXT NOT NULL,
        champion_model_id BIGINT REFERENCES phoenix_model_versions(id),
        challenger_model_id BIGINT REFERENCES phoenix_model_versions(id),
        same_match_sample INTEGER NOT NULL DEFAULT 0,
        metrics JSONB NOT NULL DEFAULT '{}',
        uncertainty JSONB NOT NULL DEFAULT '{}',
        recommendation TEXT NOT NULL,
        reason TEXT NOT NULL DEFAULT '',
        reviewed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        status TEXT NOT NULL DEFAULT 'completed'
      )
    ''');
    // Section 50: Idempotenz - ein Review pro Jahr/Monat/Liga/Markt.
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_phoenix_monthly_reviews_period
      ON phoenix_monthly_reviews (
        review_year, review_month, market, COALESCE(league_id, '__GLOBAL__')
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_model_audit_log (
        id BIGSERIAL PRIMARY KEY,
        occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        action TEXT NOT NULL,
        actor TEXT NOT NULL DEFAULT 'system',
        model_version_id BIGINT,
        league_id TEXT,
        market TEXT,
        learning_run_id BIGINT,
        details JSONB NOT NULL DEFAULT '{}'
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_model_audit_log_time
      ON phoenix_model_audit_log (occurred_at DESC)
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_match_learning_flags (
        id BIGSERIAL PRIMARY KEY,
        fixture_id TEXT NOT NULL,
        league_id TEXT NOT NULL,
        market TEXT NOT NULL,
        eligible BOOLEAN NOT NULL,
        exclusion_reason TEXT,
        data_quality INTEGER,
        snapshot_timestamp TIMESTAMPTZ,
        kickoff TIMESTAMPTZ,
        checked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (fixture_id, market)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_phoenix_match_learning_flags_scope
      ON phoenix_match_learning_flags (league_id, market, eligible)
    ''');

    // Section 64: einfaches DB-seitiges Advisory-Lock, verhindert parallele
    // Learning Runs / Monthly Reviews / Promotions ohne externe Infrastruktur.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS phoenix_model_lab_locks (
        lock_name TEXT PRIMARY KEY,
        locked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        locked_by TEXT NOT NULL DEFAULT ''
      )
    ''');
  }

  Future<Map<String, Object?>?> footballAsset({
    required String type,
    required String id,
  }) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT mime_type, encode(content, 'base64') AS content_base64
      FROM football_assets
      WHERE asset_type = @type AND asset_id = @id
    '''), parameters: {'type': type, 'id': id});
    return rows.isEmpty
        ? null
        : Map<String, Object?>.from(rows.first.toColumnMap());
  }

  /// Kopiert die aktuell gespeicherte Version in `football_assets_history`,
  /// bevor sie überschrieben wird - No-Op, wenn noch keine Version existiert
  /// (z.B. beim allerersten Upload für dieses Team/diese Liga).
  Future<void> archiveCurrentFootballAsset({
    required String type,
    required String id,
  }) async {
    final db = await connection();
    await db.execute(Sql.named('''
      INSERT INTO football_assets_history (
        asset_type, asset_id, source_url, mime_type, content
      )
      SELECT asset_type, asset_id, source_url, mime_type, content
      FROM football_assets
      WHERE asset_type = @type AND asset_id = @id
    '''), parameters: {'type': type, 'id': id});
  }

  Future<List<Map<String, Object?>>> footballAssetHistory({
    required String type,
    required String id,
  }) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT id, mime_type, archived_at
      FROM football_assets_history
      WHERE asset_type = @type AND asset_id = @id
      ORDER BY archived_at DESC
      LIMIT 50
    '''), parameters: {'type': type, 'id': id});
    return rows
        .map((r) => Map<String, Object?>.from(r.toColumnMap()))
        .toList(growable: false);
  }

  Future<Map<String, Object?>?> footballAssetHistoryImage({
    required String type,
    required String id,
    required int historyId,
  }) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT mime_type, encode(content, 'base64') AS content_base64
      FROM football_assets_history
      WHERE id = @history_id AND asset_type = @type AND asset_id = @id
    '''), parameters: {'history_id': historyId, 'type': type, 'id': id});
    return rows.isEmpty
        ? null
        : Map<String, Object?>.from(rows.first.toColumnMap());
  }

  Future<void> saveFootballAsset({
    required String type,
    required String id,
    required String sourceUrl,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final db = await connection();
    await db.execute(Sql.named('''
      INSERT INTO football_assets (
        asset_type, asset_id, source_url, mime_type, content, updated_at
      ) VALUES (
        @type, @id, @source_url, @mime_type,
        decode(@content_base64, 'base64'), NOW()
      )
      ON CONFLICT (asset_type, asset_id) DO UPDATE SET
        source_url = EXCLUDED.source_url,
        mime_type = EXCLUDED.mime_type,
        content = EXCLUDED.content,
        updated_at = NOW()
    '''), parameters: {
      'type': type,
      'id': id,
      'source_url': sourceUrl,
      'mime_type': mimeType,
      'content_base64': base64Encode(bytes),
    });
  }

  Future<int> saveMediaAsset({
    required String category,
    required String title,
    required String altText,
    required String usageType,
    String? entityType,
    String? entityId,
    required String sourceKind,
    required String sourceUrl,
    required String mimeType,
    required List<int> bytes,
    Map<String, Object?> metadata = const {},
  }) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      INSERT INTO media_assets (
        category, title, alt_text, usage_type, entity_type, entity_id,
        source_kind, source_url, mime_type, byte_size, content, metadata
      ) VALUES (
        @category, @title, @alt_text, @usage_type, @entity_type, @entity_id,
        @source_kind, @source_url, @mime_type, @byte_size,
        decode(@content_base64, 'base64'), CAST(@metadata AS JSONB)
      )
      RETURNING id
    '''), parameters: {
      'category': category,
      'title': title,
      'alt_text': altText,
      'usage_type': usageType,
      'entity_type': entityType,
      'entity_id': entityId,
      'source_kind': sourceKind,
      'source_url': sourceUrl,
      'mime_type': mimeType,
      'byte_size': bytes.length,
      'content_base64': base64Encode(bytes),
      'metadata': jsonEncode(metadata),
    });
    return rows.first[0] as int;
  }

  Future<Map<String, Object?>?> mediaAssetImage(int id) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT mime_type, encode(content, 'base64') AS content_base64
      FROM media_assets
      WHERE id = @id AND archived_at IS NULL
    '''), parameters: {'id': id});
    return rows.isEmpty
        ? null
        : Map<String, Object?>.from(rows.first.toColumnMap());
  }

  /// Ein zentraler, lesender Katalog: gespeicherte eigene Medien, bereits
  /// gecachte Provider-Wappen und externe Bildreferenzen aus Content/Ads.
  /// Externe Referenzen werden absichtlich nicht heruntergeladen, da das
  /// keine Nutzungsrechte an Pressebildern erzeugt.
  Future<List<Map<String, Object?>>> mediaLibrary({
    String? category,
    int limit = 500,
  }) async {
    final db = await connection();
    final categoryFilter = category?.trim().toLowerCase() ?? '';
    final rows = await db.execute(Sql.named('''
      WITH catalog AS (
        SELECT
          'media:' || id::text AS asset_key,
          'stored' AS storage_status,
          category,
          title,
          alt_text,
          usage_type,
          entity_type,
          entity_id,
          source_kind,
          source_url,
          mime_type,
          byte_size,
          id AS media_id,
          updated_at
        FROM media_assets
        WHERE archived_at IS NULL

        UNION ALL

        SELECT
          'football:' || asset_type || ':' || asset_id AS asset_key,
          'stored' AS storage_status,
          CASE asset_type WHEN 'league' THEN 'league_badge' ELSE 'team_badge' END AS category,
          asset_type || ' ' || asset_id AS title,
          '' AS alt_text,
          'football_identity' AS usage_type,
          asset_type AS entity_type,
          asset_id AS entity_id,
          'provider' AS source_kind,
          source_url,
          mime_type,
          octet_length(content)::INTEGER AS byte_size,
          NULL::BIGINT AS media_id,
          updated_at
        FROM football_assets

        UNION ALL

        SELECT
          'editorial:' || id::text AS asset_key,
          'external_reference' AS storage_status,
          'editorial_reference' AS category,
          title,
          '' AS alt_text,
          'editorial_article' AS usage_type,
          'editorial_article' AS entity_type,
          id::text AS entity_id,
          'external' AS source_kind,
          image_url AS source_url,
          NULL::TEXT AS mime_type,
          NULL::INTEGER AS byte_size,
          NULL::BIGINT AS media_id,
          updated_at
        FROM phoenix_editorial_articles
        WHERE COALESCE(image_url, '') <> ''

        UNION ALL

        SELECT
          'advertising:' || id::text AS asset_key,
          'external_reference' AS storage_status,
          'advertising_reference' AS category,
          name AS title,
          '' AS alt_text,
          'ad_campaign' AS usage_type,
          'ad_campaign' AS entity_type,
          id::text AS entity_id,
          'external' AS source_kind,
          image_url AS source_url,
          NULL::TEXT AS mime_type,
          NULL::INTEGER AS byte_size,
          NULL::BIGINT AS media_id,
          updated_at
        FROM ad_campaigns
        WHERE COALESCE(image_url, '') <> ''
      )
      SELECT * FROM catalog
      WHERE @category = '' OR category = @category
      ORDER BY updated_at DESC
      LIMIT @limit
    '''), parameters: {
      'category': categoryFilter,
      'limit': limit.clamp(1, 1000),
    });
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<void> registerPushDevice({
    required String installationId,
    required String pushToken,
    required String platform,
    String locale = 'de',
  }) async {
    final db = await connection();
    await db.execute(Sql.named('''
      INSERT INTO push_devices (
        installation_id, push_token, platform, locale
      ) VALUES (@installationId, @pushToken, @platform, @locale)
      ON CONFLICT (installation_id) DO UPDATE SET
        push_token = EXCLUDED.push_token,
        platform = EXCLUDED.platform,
        locale = EXCLUDED.locale,
        enabled = TRUE,
        updated_at = NOW(),
        last_seen_at = NOW()
    '''), parameters: {
      'installationId': installationId,
      'pushToken': pushToken,
      'platform': platform,
      'locale': locale,
    });
  }

  Future<void> setFootballFavorite({
    required String installationId,
    required String fixtureId,
    required bool favorite,
  }) async {
    final db = await connection();
    if (favorite) {
      await db.execute(Sql.named('''
        INSERT INTO football_favorites (installation_id, fixture_id)
        VALUES (@installationId, @fixtureId)
        ON CONFLICT (installation_id, fixture_id) DO UPDATE SET
          notifications_enabled = TRUE
      '''), parameters: {
        'installationId': installationId,
        'fixtureId': fixtureId,
      });
    } else {
      await db.execute(Sql.named('''
        DELETE FROM football_favorites
        WHERE installation_id = @installationId AND fixture_id = @fixtureId
      '''), parameters: {
        'installationId': installationId,
        'fixtureId': fixtureId,
      });
    }
  }

  Future<void> setFavoriteEntity({
    required String installationId,
    required String entityType,
    required String entityId,
    required bool favorite,
  }) async {
    final db = await connection();
    if (favorite) {
      await db.execute(Sql.named('''
        INSERT INTO football_favorite_entities (
          installation_id, entity_type, entity_id
        ) VALUES (@installationId, @entityType, @entityId)
        ON CONFLICT DO NOTHING
      '''), parameters: {
        'installationId': installationId,
        'entityType': entityType,
        'entityId': entityId,
      });
    } else {
      await db.execute(Sql.named('''
        DELETE FROM football_favorite_entities
        WHERE installation_id = @installationId
          AND entity_type = @entityType AND entity_id = @entityId
      '''), parameters: {
        'installationId': installationId,
        'entityType': entityType,
        'entityId': entityId,
      });
    }
  }

  Future<void> setNewsNotifications({
    required String installationId,
    required bool enabled,
  }) async {
    final db = await connection();
    await db.execute(Sql.named('''
      UPDATE push_devices SET news_enabled = @enabled, updated_at = NOW()
      WHERE installation_id = @installationId
    '''), parameters: {
      'installationId': installationId,
      'enabled': enabled,
    });
  }

  Future<List<String>> footballFavorites(String installationId) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT fixture_id FROM football_favorites
      WHERE installation_id = @installationId
      ORDER BY created_at
    '''), parameters: {'installationId': installationId});
    return rows.map((row) => row[0].toString()).toList(growable: false);
  }

  Future<List<String>> trackedFavoriteFixtureIds() async {
    final db = await connection();
    final rows = await db.execute('''
      SELECT DISTINCT fixture_id FROM football_favorites
      WHERE notifications_enabled = TRUE
    ''');
    return rows.map((row) => row[0].toString()).toList(growable: false);
  }

  Future<bool> claimFootballLiveEvent({
    required String fixtureId,
    required String eventKey,
    required String eventType,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      INSERT INTO football_live_events (
        fixture_id, event_key, event_type, payload
      ) VALUES (@fixtureId, @eventKey, @eventType, @payload::jsonb)
      ON CONFLICT DO NOTHING
      RETURNING event_key
    '''), parameters: {
      'fixtureId': fixtureId,
      'eventKey': eventKey,
      'eventType': eventType,
      'payload': jsonEncode(payload),
    });
    return rows.isNotEmpty;
  }

  Future<List<Map<String, String>>> pushTargetsForFixture(
    String fixtureId,
  ) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT d.installation_id, d.push_token, d.platform, d.locale
      FROM football_favorites f
      JOIN push_devices d ON d.installation_id = f.installation_id
      WHERE f.fixture_id = @fixtureId
        AND f.notifications_enabled = TRUE
        AND d.enabled = TRUE
    '''), parameters: {'fixtureId': fixtureId});
    return rows
        .map((row) => {
              'installationId': row[0].toString(),
              'pushToken': row[1].toString(),
              'platform': row[2].toString(),
              'locale': row[3].toString(),
            })
        .toList(growable: false);
  }

  Future<void> recordPushDelivery({
    required String fixtureId,
    required String eventKey,
    required String installationId,
    required String status,
    String? providerResponse,
  }) async {
    final db = await connection();
    await db.execute(Sql.named('''
      INSERT INTO push_deliveries (
        fixture_id, event_key, installation_id, status,
        provider_response, attempted_at
      ) VALUES (
        @fixtureId, @eventKey, @installationId, @status,
        @providerResponse, NOW()
      ) ON CONFLICT (fixture_id, event_key, installation_id) DO UPDATE SET
        status = EXCLUDED.status,
        provider_response = EXCLUDED.provider_response,
        attempted_at = NOW()
    '''), parameters: {
      'fixtureId': fixtureId,
      'eventKey': eventKey,
      'installationId': installationId,
      'status': status,
      'providerResponse': providerResponse,
    });
  }

  Future<List<Map<String, String>>> footballNewsEntities() async {
    final db = await connection();
    final rows = await db.execute('''
      SELECT DISTINCT id, name, kind FROM (
        SELECT m.home_team_id AS id, m.home_team_name AS name, 'team' AS kind
        FROM football_matches m
        INNER JOIN football_leagues l ON l.league_id = m.league_id
        WHERE l.manual_status = 'whitelist'
        UNION ALL
        SELECT m.away_team_id, m.away_team_name, 'team'
        FROM football_matches m
        INNER JOIN football_leagues l ON l.league_id = m.league_id
        WHERE l.manual_status = 'whitelist'
        UNION ALL
        SELECT m.league_id, m.league_name, 'league'
        FROM football_matches m
        INNER JOIN football_leagues l ON l.league_id = m.league_id
        WHERE l.manual_status = 'whitelist'
      ) entities
      WHERE id <> '' AND name <> ''
    ''');
    return rows
        .map((row) => {
              'id': row[0].toString(),
              'name': row[1].toString(),
              'kind': row[2].toString(),
            })
        .toList(growable: false);
  }

  /// Liefert ausschließlich Spiele aus freigegebenen Ligen, für die Phoenix
  /// eigene Vor- oder Nachberichte erzeugen kann. Die neueste Analyse wird
  /// optional zugeladen – ein Spiel ohne Analyse bleibt als Ergebnisbericht
  /// nutzbar, bekommt aber keine erfundenen Wahrscheinlichkeiten.
  Future<List<Map<String, Object?>>> phoenixEditorialMatches() async {
    final db = await connection();
    final rows = await db.execute('''
      SELECT
        m.id,
        m.kickoff_utc,
        m.status,
        m.league_id,
        m.league_name,
        m.home_team_id,
        m.home_team_name,
        m.away_team_id,
        m.away_team_name,
        m.home_goals,
        m.away_goals,
        latest.payload AS analysis_payload
      FROM football_matches m
      INNER JOIN football_leagues l ON l.league_id = m.league_id
      LEFT JOIN LATERAL (
        SELECT a.payload
        FROM analyses a
        WHERE a.sport = 'football'
          AND a.match_id = m.id
          AND a.payload IS NOT NULL
        ORDER BY a.analyzed_at DESC
        LIMIT 1
      ) latest ON TRUE
      WHERE l.manual_status = 'whitelist'
        AND m.kickoff_utc >= NOW() - INTERVAL '5 days'
        AND m.kickoff_utc <= NOW() + INTERVAL '3 days'
      ORDER BY m.kickoff_utc DESC
    ''');
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<List<Map<String, String>>> seasonProjectionTargets(int season) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT league_id, league_name, country
      FROM football_leagues
      WHERE manual_status = 'whitelist'
        AND competition_level IS NOT NULL
      ORDER BY country, competition_level, league_name
    '''));
    return rows
        .map((row) => {
              'leagueId': row[0].toString(),
              'leagueName': row[1].toString(),
              'country': row[2].toString(),
            })
        .toList(growable: false);
  }

  Future<void> saveFootballDailyCombo({
    required DateTime date,
    required double combinedOdds,
    required double combinedProbability,
    required bool usesModelOdds,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    await db.execute(Sql.named('''
      INSERT INTO football_daily_combos (
        combo_date, combined_odds, combined_probability, uses_model_odds,
        assigned_units, payload
      ) VALUES (
        CAST(@date AS DATE), @combined_odds, @combined_probability,
        @uses_model_odds, @assigned_units, CAST(@payload AS JSONB)
      )
      ON CONFLICT (combo_date) DO UPDATE SET
        combined_odds = EXCLUDED.combined_odds,
        combined_probability = EXCLUDED.combined_probability,
        uses_model_odds = EXCLUDED.uses_model_odds,
        assigned_units = EXCLUDED.assigned_units,
        payload = EXCLUDED.payload,
        updated_at = NOW()
      WHERE football_daily_combos.result_status = 'pending'
    '''), parameters: {
      'date': date.toUtc().toIso8601String().substring(0, 10),
      'combined_odds': combinedOdds,
      'combined_probability': combinedProbability,
      'uses_model_odds': usesModelOdds,
      'assigned_units': usesModelOdds ? 0.0 : 1.0,
      'payload': jsonEncode(payload),
    });
  }

  Future<Map<String, Object?>?> footballDailyCombo(DateTime date) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT combo_date, combined_odds, combined_probability, uses_model_odds,
             result_status, assigned_units, profit_units, settled_at, payload
      FROM football_daily_combos
      WHERE combo_date = CAST(@date AS DATE)
    '''), parameters: {
      'date': date.toUtc().toIso8601String().substring(0, 10),
    });
    if (rows.isEmpty) return null;
    return Map<String, Object?>.from(rows.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> footballDailyCombosForSettlement({
    required DateTime date,
    bool reconcile = false,
  }) async {
    final db = await connection();
    final statusFilter = reconcile ? '' : "AND result_status = 'pending'";
    final rows = await db.execute(Sql.named('''
      SELECT combo_date, combined_odds, assigned_units, payload
      FROM football_daily_combos
      WHERE combo_date = CAST(@date AS DATE)
        $statusFilter
    '''), parameters: {
      'date': date.toUtc().toIso8601String().substring(0, 10),
    });
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<void> settleFootballDailyCombo({
    required DateTime date,
    required String resultStatus,
    required double profitUnits,
  }) async {
    final db = await connection();
    await db.execute(Sql.named('''
      UPDATE football_daily_combos
      SET result_status = @result_status,
          profit_units = @profit_units,
          settled_at = NOW(),
          updated_at = NOW()
      WHERE combo_date = CAST(@date AS DATE)
    '''), parameters: {
      'date': date.toUtc().toIso8601String().substring(0, 10),
      'result_status': resultStatus,
      'profit_units': profitUnits,
    });
  }

  Future<Map<String, Object?>> footballDailyComboPerformance() async {
    final db = await connection();
    final rows = await db.execute('''
      SELECT COUNT(*) AS total,
             COUNT(*) FILTER (WHERE result_status IN ('won', 'lost')) AS settled,
             COUNT(*) FILTER (WHERE result_status = 'won') AS won,
             COUNT(*) FILTER (WHERE result_status = 'lost') AS lost,
             COALESCE(SUM(assigned_units) FILTER (WHERE result_status IN ('won', 'lost')), 0) AS staked_units,
             COALESCE(SUM(profit_units) FILTER (WHERE result_status IN ('won', 'lost')), 0) AS profit_units
      FROM football_daily_combos
    ''');
    final values = Map<String, Object?>.from(rows.first.toColumnMap());
    final number =
        (String key) => double.tryParse(values[key]?.toString() ?? '') ?? 0;
    final integer =
        (String key) => int.tryParse(values[key]?.toString() ?? '') ?? 0;
    final won = integer('won');
    final lost = integer('lost');
    final staked = number('staked_units');
    final profit = number('profit_units');
    return {
      'total': integer('total'),
      'settled': integer('settled'),
      'won': won,
      'lost': lost,
      'hitRatePercent': won + lost == 0 ? 0 : won / (won + lost) * 100,
      'stakedUnits': staked,
      'profitUnits': profit,
      'roiPercent': staked == 0 ? 0 : profit / staked * 100,
    };
  }

  /// Coverage report for every manually whitelisted competition. It makes
  /// missing fixtures, analyses and low-quality scans visible before they turn
  /// into empty app sections.
  Future<List<Map<String, Object?>>> footballWhitelistCoverage({
    required DateTime date,
  }) async {
    final db = await connection();
    final day = date.toUtc().toIso8601String().substring(0, 10);
    final rows = await db.execute(Sql.named('''
      SELECT
        l.league_id,
        l.league_name,
        l.country,
        l.competition_level,
        COUNT(DISTINCT m.id)::INTEGER AS fixture_count,
        COUNT(DISTINCT a.match_id)::INTEGER AS analysis_count,
        COALESCE(ROUND(AVG(a.data_quality)), 0)::INTEGER AS average_quality
      FROM football_leagues l
      LEFT JOIN football_matches m
        ON m.league_id = l.league_id
       AND m.kickoff_utc >= CAST(@day AS DATE)
       AND m.kickoff_utc < CAST(@day AS DATE) + INTERVAL '1 day'
      LEFT JOIN analyses a
        ON a.sport = 'football' AND a.match_id = m.id
      WHERE l.manual_status = 'whitelist'
      GROUP BY l.league_id, l.league_name, l.country, l.competition_level
      ORDER BY l.competition_level NULLS LAST, l.country, l.league_name
    '''), parameters: {'day': day});
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<void> saveSeasonProjection({
    required String leagueId,
    required int season,
    required String modelVersion,
    required int simulations,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    await db.execute(Sql.named('''
      INSERT INTO football_season_projections (
        league_id, season, model_version, simulations, payload, calculated_at
      ) VALUES (
        @leagueId, @season, @modelVersion, @simulations, @payload::jsonb, NOW()
      ) ON CONFLICT (league_id, season) DO UPDATE SET
        model_version = EXCLUDED.model_version,
        simulations = EXCLUDED.simulations,
        payload = EXCLUDED.payload,
        calculated_at = NOW()
    '''), parameters: {
      'leagueId': leagueId,
      'season': season,
      'modelVersion': modelVersion,
      'simulations': simulations,
      'payload': jsonEncode(payload),
    });
  }

  Future<List<Map<String, Object?>>> seasonProjections({
    int? season,
    String? leagueId,
  }) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT p.league_id, l.league_name, l.country, p.season, p.model_version,
             p.simulations, p.payload, p.calculated_at
      FROM football_season_projections p
      INNER JOIN football_leagues l ON l.league_id = p.league_id
      WHERE (@season IS NULL OR p.season = @season)
        AND (@leagueId = '' OR p.league_id = @leagueId)
      ORDER BY l.country, l.competition_level, l.league_name
    '''), parameters: {'season': season, 'leagueId': leagueId ?? ''});
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<bool> upsertNewsArticle(Map<String, Object?> article) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      INSERT INTO news_articles (
        id, source_name, source_url, article_url, title_de, summary_de,
        body_de, article_type, image_url, category, importance, team_ids, team_names,
        league_ids, league_names, published_at
      ) VALUES (
        @id, @sourceName, @sourceUrl, @articleUrl, @title, @summary,
        @body, @articleType, @imageUrl, @category, @importance, @teamIds::jsonb, @teamNames::jsonb,
        @leagueIds::jsonb, @leagueNames::jsonb, @publishedAt
      ) ON CONFLICT (article_url) DO UPDATE SET
        title_de = EXCLUDED.title_de,
        summary_de = EXCLUDED.summary_de,
        body_de = EXCLUDED.body_de,
        article_type = EXCLUDED.article_type,
        image_url = EXCLUDED.image_url,
        category = EXCLUDED.category,
        importance = EXCLUDED.importance,
        team_ids = EXCLUDED.team_ids,
        team_names = EXCLUDED.team_names,
        league_ids = EXCLUDED.league_ids,
        league_names = EXCLUDED.league_names,
        published_at = EXCLUDED.published_at,
        fetched_at = NOW()
      RETURNING (xmax = 0) AS inserted
    '''), parameters: {
      'id': article['id'],
      'sourceName': article['sourceName'],
      'sourceUrl': article['sourceUrl'],
      'articleUrl': article['articleUrl'],
      'title': article['title'],
      'summary': article['summary'],
      'body': article['body'] ?? article['summary'] ?? '',
      'articleType': article['articleType'] ?? article['category'] ?? 'general',
      'imageUrl': article['imageUrl'],
      'category': article['category'],
      'importance': article['importance'],
      'teamIds': jsonEncode(article['teamIds']),
      'teamNames': jsonEncode(article['teamNames']),
      'leagueIds': jsonEncode(article['leagueIds']),
      'leagueNames': jsonEncode(article['leagueNames']),
      'publishedAt': article['publishedAt'],
    });
    return rows.isNotEmpty && rows.first[0] == true;
  }

  Future<List<Map<String, String>>> newsPushTargets({
    required List<String> teamIds,
    required List<String> leagueIds,
  }) async {
    if (teamIds.isEmpty && leagueIds.isEmpty) return const [];
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT DISTINCT d.installation_id, d.push_token
      FROM push_devices d
      JOIN football_favorite_entities f
        ON f.installation_id = d.installation_id
      WHERE d.enabled = TRUE AND d.news_enabled = TRUE
        AND ((f.entity_type = 'team' AND f.entity_id = ANY(CAST(@teamIds AS text[])))
          OR (f.entity_type = 'league' AND f.entity_id = ANY(CAST(@leagueIds AS text[]))))
    '''), parameters: {'teamIds': teamIds, 'leagueIds': leagueIds});
    return rows
        .map((row) => {
              'installationId': row[0].toString(),
              'pushToken': row[1].toString(),
            })
        .toList(growable: false);
  }

  Future<bool> claimNewsPush(String articleId, String installationId) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      INSERT INTO news_push_deliveries (article_id, installation_id)
      VALUES (@articleId, @installationId)
      ON CONFLICT DO NOTHING RETURNING article_id
    '''), parameters: {
      'articleId': articleId,
      'installationId': installationId,
    });
    return rows.isNotEmpty;
  }

  Future<List<Map<String, Object?>>> newsArticles({
    String? teamId,
    String? leagueId,
    String? category,
    String? sourceName,
    bool importantOnly = false,
    int hours = 168,
    int limit = 80,
  }) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT id, source_name, source_url, article_url, title_de, summary_de,
             body_de, article_type, image_url, category, importance, team_ids, team_names,
             league_ids, league_names, published_at
      FROM news_articles
      WHERE published_at >= NOW() - (@hours * INTERVAL '1 hour')
        -- Die gespeicherten Spalten heißen title_de/summary_de. Die alten
        -- Namen führten hier zu PostgreSQL-Fehlern und damit zu HTTP 500 für
        -- den kompletten News-Tab, noch bevor die Artikel ausgeliefert wurden.
        AND (title_de || ' ' || summary_de) !~* '(^|[^[:alnum:]])wm([^[:alnum:]]|\$)'
        AND LOWER(title_de || ' ' || summary_de) NOT LIKE ALL (ARRAY[
          '%weltmeisterschaft%', '%world cup%', '%klub-wm%',
          '%club world cup%', '%nationalmannschaft%', '%nationalteam%'
        ])
        AND (
          EXISTS (
            SELECT 1 FROM football_leagues l
            WHERE l.manual_status = 'whitelist'
              AND league_ids ? l.league_id
          )
          OR EXISTS (
            SELECT 1
            FROM football_matches m
            INNER JOIN football_leagues l ON l.league_id = m.league_id
            WHERE l.manual_status = 'whitelist'
              AND (team_ids ? m.home_team_id OR team_ids ? m.away_team_id)
          )
        )
        AND (@teamId = '' OR team_ids ? @teamId)
        AND (@leagueId = '' OR league_ids ? @leagueId)
        AND (@category = '' OR category = @category)
        AND (@sourceName = '' OR source_name = @sourceName)
        AND (@importantOnly = FALSE OR importance >= 70)
      ORDER BY importance DESC, published_at DESC
      LIMIT @limit
    '''), parameters: {
      'hours': hours.clamp(1, 336),
      'teamId': teamId ?? '',
      'leagueId': leagueId ?? '',
      'category': category ?? '',
      'sourceName': sourceName ?? '',
      'importantOnly': importantOnly,
      'limit': limit.clamp(1, 100),
    });
    return rows
        .map((row) => {
              'id': row[0],
              'sourceName': row[1],
              'sourceUrl': row[2],
              'articleUrl': row[3],
              'title': row[4],
              'summary': row[5],
              'body': row[6],
              'articleType': row[7],
              'imageUrl': row[8],
              'category': row[9],
              'importance': row[10],
              'teamIds': row[11],
              'teamNames': row[12],
              'leagueIds': row[13],
              'leagueNames': row[14],
              'publishedAt': (row[15] as DateTime).toUtc().toIso8601String(),
            })
        .toList(growable: false);
  }

  /// Reserviert genau einen Request aus dem produktbezogenen Tagesbudget.
  /// Null bedeutet: Die Schutzgrenze wurde bereits erreicht.
  Future<int?> consumeApiSportsRequest({
    required String apiName,
    required int safetyLimit,
  }) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        INSERT INTO api_sports_daily_usage (api_name, usage_date, requests)
        VALUES (@apiName, (NOW() AT TIME ZONE 'UTC')::DATE, 1)
        ON CONFLICT (api_name, usage_date) DO UPDATE
        SET requests = api_sports_daily_usage.requests + 1,
            updated_at = NOW()
        WHERE api_sports_daily_usage.requests < @safetyLimit
        RETURNING requests
      '''),
      parameters: {
        'apiName': apiName.toLowerCase(),
        'safetyLimit': safetyLimit.clamp(1, 100),
      },
    );
    return rows.isEmpty ? null : rows.first[0] as int?;
  }

  /// Section 25 (AN2): reine, ungedeckelte Zählung für Datenquellen ohne
  /// eigenes Free-Plan-Sicherheitslimit (aktuell: die echte
  /// API-Football-Hauptnutzung über FootballService). Kein Blocken, kein
  /// safetyLimit - nur Sichtbarkeit. Fire-and-forget vom Aufrufer.
  Future<void> recordApiSportsUsage(String apiName) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO api_sports_daily_usage (api_name, usage_date, requests)
        VALUES (@apiName, (NOW() AT TIME ZONE 'UTC')::DATE, 1)
        ON CONFLICT (api_name, usage_date) DO UPDATE
        SET requests = api_sports_daily_usage.requests + 1,
            updated_at = NOW()
      '''),
      parameters: {'apiName': apiName.toLowerCase()},
    );
  }

  /// Section 25 (AN2): "Fehlerquote" - Gegenstück zu [recordApiSportsUsage]
  /// für fehlgeschlagene Anfragen (HTTP-Fehler, Timeouts).
  Future<void> recordApiSportsError(String apiName) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO api_sports_daily_usage (api_name, usage_date, requests, errors)
        VALUES (@apiName, (NOW() AT TIME ZONE 'UTC')::DATE, 0, 1)
        ON CONFLICT (api_name, usage_date) DO UPDATE
        SET errors = api_sports_daily_usage.errors + 1,
            updated_at = NOW()
      '''),
      parameters: {'apiName': apiName.toLowerCase()},
    );
  }

  Future<bool> ping() async {
    if (!isConfigured) return false;
    final db = await connection();
    final result = await db.execute('SELECT 1 AS ok');
    return result.isNotEmpty;
  }

  Future<Map<String, Object?>?> leagueProfile(
    String leagueId,
    int season,
  ) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          l.league_id,
          l.league_name,
          l.country,
          l.gender,
          l.competition_level,
          l.manual_status,
          l.collection_tier,
          l.background_enabled,
          l.detail_refresh_hours,
          l.historical_status,
          l.total_samples,
          s.season,
          s.status AS season_status,
          s.samples
        FROM football_leagues l
        LEFT JOIN football_league_seasons s
          ON s.league_id = l.league_id AND s.season = @season
        WHERE l.league_id = @league_id
        LIMIT 1
      '''),
      parameters: {'league_id': leagueId, 'season': season},
    );

    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Die Phase-1-Pipeline braucht nur Ligen, die explizit freigegeben sind.
  /// Ein einzelner Lookup verhindert, dass für mehrere hundert fremde
  /// Tages-Factures jeweils zwei Datenbankabfragen ausgeführt werden.
  Future<Set<String>> whitelistedFootballLeagueIds() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT league_id
      FROM football_leagues
      WHERE manual_status = 'whitelist'
    ''');
    return result
        .map((row) => row[0]?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  /// Liefert die aktuelle Verarbeitungsstufe für eine Menge Provider-Ligen.
  /// Unbekannte Ligen gehören bewusst zum Datenpool: Sie werden gespeichert
  /// und können Daten aufbauen, erscheinen aber nie als öffentliche Tipps.
  Future<Map<String, FootballLeagueTier>> footballLeagueTiers(
    Iterable<String> leagueIds,
  ) async {
    final ids = leagueIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return const <String, FootballLeagueTier>{};

    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT league_id, collection_tier, manual_status
        FROM football_leagues
        WHERE league_id = ANY(@league_ids)
      '''),
      parameters: {'league_ids': ids},
    );
    return {
      for (final row in result)
        row[0].toString(): FootballLeagueTier.fromStorage(
          row[1] ?? row[2],
        ),
    };
  }

  Future<List<Map<String, Object?>>> footballLeagueBackgroundPolicies({
    int limit = 2000,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT league_id, league_name, country, collection_tier,
               detail_refresh_hours, last_seen_at
        FROM football_leagues
        WHERE background_enabled = TRUE
          AND collection_tier IN ('focus', 'watchlist', 'data_pool')
        ORDER BY
          CASE collection_tier
            WHEN 'focus' THEN 1
            WHEN 'watchlist' THEN 2
            ELSE 3
          END,
          last_seen_at DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit.clamp(1, 5000)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<String?> setFootballLeagueTier({
    required String leagueId,
    required FootballLeagueTier tier,
  }) async {
    final db = await connection();
    final previousRows = await db.execute(
      Sql.named('''
        SELECT collection_tier, manual_status
        FROM football_leagues
        WHERE league_id = @league_id
      '''),
      parameters: {'league_id': leagueId},
    );
    if (previousRows.isEmpty) return null;

    final previous = FootballLeagueTier.fromStorage(
      previousRows.first[0] ?? previousRows.first[1],
    );
    final manualStatus = switch (tier) {
      FootballLeagueTier.focus => 'whitelist',
      FootballLeagueTier.blocked => 'blacklist',
      _ => 'auto',
    };
    final refreshHours = switch (tier) {
      FootballLeagueTier.focus => 1,
      FootballLeagueTier.watchlist => 6,
      FootballLeagueTier.dataPool => 24,
      FootballLeagueTier.blocked => 0,
    };

    await db.execute(
      Sql.named('''
        UPDATE football_leagues
        SET collection_tier = @tier,
            manual_status = @manual_status,
            background_enabled = @enabled,
            detail_refresh_hours = @refresh_hours,
            updated_at = NOW()
        WHERE league_id = @league_id
      '''),
      parameters: {
        'league_id': leagueId,
        'tier': tier.storageKey,
        'manual_status': manualStatus,
        'enabled': tier.isBackgroundEnabled,
        'refresh_hours': refreshHours,
      },
    );
    return previous.storageKey;
  }

  /// Füllt die Beobachtungsliste ausschließlich mit belastbaren Erwachsenen-
  /// Wettbewerben aus dem Datenpool. Maßgeblich ist der Mittelwert der letzten
  /// 50 vollständigen Phase-2-Datensätze je Liga; unbekannte oder schwache
  /// Ligen bleiben bewusst im Datenpool.
  Future<List<Map<String, Object?>>> promoteEligibleDataPoolLeaguesToWatchlist({
    int minimumQuality = 30,
  }) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        WITH recent_quality AS (
          SELECT
            l.league_id,
            ROUND(AVG(p.data_quality))::INTEGER AS average_quality
          FROM football_leagues l
          JOIN LATERAL (
            SELECT data_quality
            FROM football_phase_two_results
            WHERE league_id = l.league_id
              AND data_quality IS NOT NULL
            ORDER BY created_at DESC
            LIMIT 50
          ) p ON TRUE
          WHERE l.collection_tier = 'data_pool'
            AND COALESCE(l.league_name, '') !~* @youth_pattern
          GROUP BY l.league_id
        ), promoted AS (
          UPDATE football_leagues l
          SET collection_tier = 'watchlist',
              manual_status = 'auto',
              background_enabled = TRUE,
              detail_refresh_hours = 6,
              updated_at = NOW()
          FROM recent_quality q
          WHERE l.league_id = q.league_id
            AND q.average_quality >= @minimum_quality
          RETURNING l.league_id, l.league_name, l.country
        )
        SELECT p.league_id, p.league_name, p.country, q.average_quality
        FROM promoted p
        INNER JOIN recent_quality q ON q.league_id = p.league_id
        ORDER BY p.country NULLS LAST, p.league_name
      '''),
      parameters: {
        'minimum_quality': minimumQuality.clamp(0, 100),
        'youth_pattern':
            r'(^|[^a-z0-9])(u[- ]?(1[0-9]|2[0-3])|under[- ]?(1[0-9]|2[0-3])|youth|junior|juniors)([^a-z0-9]|$)',
      },
    );
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<void> upsertLeagueSeen({
    required String leagueId,
    required String leagueName,
    required String country,
    required int season,
    required String gender,
    int? competitionLevel,
    required String initialHistoricalStatus,
    required String initialSeasonStatus,
  }) async {
    final db = await connection();

    await db.execute(
      Sql.named('''
        INSERT INTO football_leagues (
          league_id,
          league_name,
          country,
          gender,
          competition_level,
          historical_status,
          last_seen_at,
          updated_at
        )
        VALUES (
          @league_id,
          @league_name,
          @country,
          @gender,
          @competition_level,
          @historical_status,
          NOW(),
          NOW()
        )
        ON CONFLICT (league_id) DO UPDATE SET
          league_name = EXCLUDED.league_name,
          country = EXCLUDED.country,
          gender = CASE
            WHEN football_leagues.gender = 'unknown'
              THEN EXCLUDED.gender
            ELSE football_leagues.gender
          END,
          competition_level = COALESCE(
            football_leagues.competition_level,
            EXCLUDED.competition_level
          ),
          last_seen_at = NOW(),
          updated_at = NOW()
      '''),
      parameters: {
        'league_id': leagueId,
        'league_name': leagueName,
        'country': country,
        'gender': gender,
        'competition_level': competitionLevel,
        'historical_status': initialHistoricalStatus,
      },
    );

    await db.execute(
      Sql.named('''
        INSERT INTO football_league_seasons (
          league_id,
          season,
          status,
          updated_at
        )
        VALUES (
          @league_id,
          @season,
          @status,
          NOW()
        )
        ON CONFLICT (league_id, season) DO NOTHING
      '''),
      parameters: {
        'league_id': leagueId,
        'season': season,
        'status': initialSeasonStatus,
      },
    );
  }

  Future<int> createFootballScanRun(DateTime scanDate) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO football_scan_runs (scan_date, phase, status)
        VALUES (@scan_date, 1, 'running')
        RETURNING id
      '''),
      parameters: {'scan_date': _dateOnly(scanDate)},
    );
    return result.first[0] as int;
  }

  Future<void> savePhaseOneDecision({
    required int scanRunId,
    required String fixtureId,
    required String leagueId,
    required int season,
    required bool eligible,
    required String decisionStatus,
    String? exclusionReason,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO football_scan_matches (
          scan_run_id,
          fixture_id,
          league_id,
          season,
          eligible,
          decision_status,
          exclusion_reason,
          payload
        )
        VALUES (
          @scan_run_id,
          @fixture_id,
          @league_id,
          @season,
          @eligible,
          @decision_status,
          @exclusion_reason,
          CAST(@payload AS JSONB)
        )
        ON CONFLICT (scan_run_id, fixture_id) DO UPDATE SET
          eligible = EXCLUDED.eligible,
          decision_status = EXCLUDED.decision_status,
          exclusion_reason = EXCLUDED.exclusion_reason,
          payload = EXCLUDED.payload
      '''),
      parameters: {
        'scan_run_id': scanRunId,
        'fixture_id': fixtureId,
        'league_id': leagueId,
        'season': season,
        'eligible': eligible,
        'decision_status': decisionStatus,
        'exclusion_reason': exclusionReason,
        'payload': jsonEncode(payload),
      },
    );
  }

  Future<void> completeFootballScanRun({
    required int scanRunId,
    required int totalMatches,
    required int eligibleMatches,
    required int excludedMatches,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE football_scan_runs
        SET
          status = 'completed',
          total_matches = @total_matches,
          eligible_matches = @eligible_matches,
          excluded_matches = @excluded_matches,
          payload = CAST(@payload AS JSONB),
          completed_at = NOW()
        WHERE id = @scan_run_id
      '''),
      parameters: {
        'scan_run_id': scanRunId,
        'total_matches': totalMatches,
        'eligible_matches': eligibleMatches,
        'excluded_matches': excludedMatches,
        'payload': jsonEncode(payload),
      },
    );
  }

  Future<void> failFootballScanRun(int scanRunId, Object error) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE football_scan_runs
        SET
          status = 'failed',
          payload = CAST(@payload AS JSONB),
          completed_at = NOW()
        WHERE id = @scan_run_id
      '''),
      parameters: {
        'scan_run_id': scanRunId,
        'payload': jsonEncode({'error': error.toString()}),
      },
    );
  }

  Future<List<Map<String, Object?>>> listFootballLeagueProfiles({
    int limit = 200,
  }) async {
    final db = await connection();
    final safeLimit = limit.clamp(1, 1000);
    final result = await db.execute(
      Sql.named('''
        SELECT
          l.league_id,
          l.league_name,
          l.country,
          l.gender,
          l.competition_level,
          l.manual_status,
          l.collection_tier,
          l.background_enabled,
          l.detail_refresh_hours,
          l.historical_status,
          l.total_samples,
          l.successful_full_analyses,
          l.last_seen_at,
          EXISTS (
            SELECT 1 FROM football_assets fa
            WHERE fa.asset_type = 'league' AND fa.asset_id = l.league_id
          ) AS has_logo,
          COALESCE(
            jsonb_agg(
              jsonb_build_object(
                'season', s.season,
                'status', s.status,
                'samples', s.samples,
                'fullAnalysisAvailable', s.full_analysis_available
              ) ORDER BY s.season DESC
            ) FILTER (WHERE s.season IS NOT NULL),
            '[]'::jsonb
          ) AS seasons
        FROM football_leagues l
        LEFT JOIN football_league_seasons s
          ON s.league_id = l.league_id
        GROUP BY l.league_id
        ORDER BY l.last_seen_at DESC, l.league_name ASC
        LIMIT @limit
      '''),
      parameters: {'limit': safeLimit},
    );

    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Liefert `manual_status` für mehrere Ligen in einer einzigen Abfrage.
  /// Wird von PhoenixApiGuard genutzt, um pro Request nicht mehr eine
  /// sequenzielle DB-Anfrage je Spiel auszulösen.
  Future<Map<String, String>> footballLeagueManualStatuses(
    Iterable<String> leagueIds,
  ) async {
    final ids = leagueIds.toSet().toList();
    if (ids.isEmpty) return const <String, String>{};

    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT league_id, manual_status
        FROM football_leagues
        WHERE league_id = ANY(@league_ids)
      '''),
      parameters: {'league_ids': ids},
    );

    return {
      for (final row in result) row[0].toString(): row[1]?.toString() ?? '',
    };
  }

  /// Section 8: gibt jetzt den vorherigen Status mit zurück, damit der
  /// aufrufende Handler einen echten Vorher/Nachher-Audit-Log-Eintrag
  /// schreiben kann statt die Änderung stillschweigend durchzuführen.
  /// `null` bedeutet "Liga nicht gefunden" (unverändert vom bisherigen
  /// `bool`-Rückgabewert, nur jetzt als fehlender Eintrag ausgedrückt).
  Future<String?> setFootballLeagueManualStatus({
    required String leagueId,
    required String manualStatus,
  }) async {
    if (!const {'auto', 'whitelist', 'blacklist'}.contains(manualStatus)) {
      throw ArgumentError('Status muss auto, whitelist oder blacklist sein.');
    }

    final db = await connection();
    final previousRows = await db.execute(
      Sql.named(
          'SELECT manual_status FROM football_leagues WHERE league_id = @league_id'),
      parameters: {'league_id': leagueId},
    );
    if (previousRows.isEmpty) return null;
    final previousStatus =
        previousRows.first.toColumnMap()['manual_status']?.toString() ?? 'auto';

    final tier = FootballLeagueTier.fromLegacyManualStatus(manualStatus);
    final refreshHours = switch (tier) {
      FootballLeagueTier.focus => 1,
      FootballLeagueTier.blocked => 0,
      _ => 24,
    };
    await db.execute(
      Sql.named('''
        UPDATE football_leagues
        SET manual_status = @manual_status,
            collection_tier = @collection_tier,
            background_enabled = @background_enabled,
            detail_refresh_hours = @refresh_hours,
            updated_at = NOW()
        WHERE league_id = @league_id
      '''),
      parameters: {
        'league_id': leagueId,
        'manual_status': manualStatus,
        'collection_tier': tier.storageKey,
        'background_enabled': tier.isBackgroundEnabled,
        'refresh_hours': refreshHours,
      },
    );

    return previousStatus;
  }

  Future<List<Map<String, Object?>>> preparedFootballAnalyses({
    required DateTime date,
    int minimumDataQuality = 50,
  }) async {
    final db = await connection();
    final safeQuality = minimumDataQuality.clamp(0, 100);
    final day = _dateOnly(date);

    final result = await db.execute(
      Sql.named('''
        SELECT DISTINCT ON (a.match_id)
          m.id,
          m.kickoff_utc,
          m.status,
          m.league_id,
          m.league_name,
          m.country,
          m.home_team_id,
          m.home_team_name,
          m.home_logo,
          m.away_team_id,
          m.away_team_name,
          m.away_logo,
          m.home_goals,
          m.away_goals,
          m.raw_json,
          a.model_version,
          a.data_quality,
          a.confidence,
          a.recommendation,
          a.payload AS analysis_payload,
          a.analyzed_at
        FROM analyses a
        INNER JOIN football_matches m
          ON m.id = a.match_id
        WHERE a.sport = 'football'
          AND (m.kickoff_utc AT TIME ZONE 'Europe/Berlin')::date =
              CAST(@day AS DATE)
          AND a.data_quality >= @minimum_quality
          AND a.payload IS NOT NULL
          AND COALESCE(
            NULLIF(a.payload #>> '{probabilities,home}', '')::double precision,
            0
          ) > 0
          AND COALESCE(
            NULLIF(a.payload #>> '{probabilities,draw}', '')::double precision,
            0
          ) >= 0
          AND COALESCE(
            NULLIF(a.payload #>> '{probabilities,away}', '')::double precision,
            0
          ) > 0
        ORDER BY a.match_id, a.analyzed_at DESC
      '''),
      parameters: {'day': day, 'minimum_quality': safeQuality},
    );

    return result
        .map((row) {
          final values = Map<String, Object?>.from(row.toColumnMap());
          final rawMatch = _jsonMap(values.remove('raw_json'));
          final analysis = _normalizePreparedAnalysis(
            _jsonMap(values.remove('analysis_payload')),
          );

          return <String, Object?>{
            ...rawMatch,
            'id': values['id']?.toString() ?? '',
            'kickoff': values['kickoff_utc']?.toString() ?? '',
            'status': values['status']?.toString() ?? '',
            'leagueId': values['league_id']?.toString() ?? '',
            'league': values['league_name']?.toString() ?? '',
            'country': values['country']?.toString() ?? '',
            'homeTeamId': values['home_team_id']?.toString() ?? '',
            'homeTeam': values['home_team_name']?.toString() ?? '',
            'homeLogo': values['home_logo']?.toString() ?? '',
            'awayTeamId': values['away_team_id']?.toString() ?? '',
            'awayTeam': values['away_team_name']?.toString() ?? '',
            'awayLogo': values['away_logo']?.toString() ?? '',
            'homeGoals': values['home_goals'],
            'awayGoals': values['away_goals'],
            'analysis': {
              ...analysis,
              'modelVersion': values['model_version']?.toString() ?? '',
              'dataQuality': values['data_quality'],
              'confidence': values['confidence'],
              'recommendation': values['recommendation'],
              'analyzedAt': values['analyzed_at']?.toString() ?? '',
            },
          };
        })
        .where((row) => (row['id']?.toString() ?? '').isNotEmpty)
        .toList();
  }

  Map<String, Object?> _normalizePreparedAnalysis(
    Map<String, Object?> analysis,
  ) {
    if (analysis.isEmpty) return analysis;

    final normalized = Map<String, Object?>.from(analysis);
    final probabilities = _jsonMap(normalized['probabilities']);

    if (probabilities.isNotEmpty) {
      final result = <String, Object?>{...probabilities};

      for (final key in const <String>[
        'home',
        'draw',
        'away',
        'homeWin',
        'awayWin',
        'over25',
        'under25',
        'bttsYes',
        'bttsNo',
      ]) {
        final probability = _probability01(probabilities[key]);
        if (probability != null) result[key] = probability;
      }

      result['home'] = _probability01(
        probabilities['home'] ?? probabilities['homeWin'],
      );
      result['draw'] = _probability01(probabilities['draw']);
      result['away'] = _probability01(
        probabilities['away'] ?? probabilities['awayWin'],
      );

      normalized['probabilities'] = result;
    }

    final fairOdds = _jsonMap(normalized['fairOdds']);
    if (fairOdds.isNotEmpty) {
      normalized['fairOdds'] = <String, Object?>{
        ...fairOdds,
        'home': fairOdds['home'] ?? fairOdds['homeWin'],
        'draw': fairOdds['draw'],
        'away': fairOdds['away'] ?? fairOdds['awayWin'],
      };
    }

    final phoenixTip = _jsonMap(normalized['phoenixTip']);
    if (phoenixTip.isNotEmpty) {
      normalized['phoenixTip'] = <String, Object?>{
        ...phoenixTip,
        if (_probability01(phoenixTip['probability']) != null)
          'probability': _probability01(phoenixTip['probability']),
      };
    }

    return normalized;
  }

  double? _probability01(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString().replaceAll(',', '.') ?? '');

    if (parsed == null || !parsed.isFinite || parsed < 0) return null;
    final normalized = parsed > 1 ? parsed / 100.0 : parsed;
    return normalized.clamp(0.0, 1.0).toDouble();
  }

  Map<String, Object?> _jsonMap(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.from(value);
    }

    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return Map<String, Object?>.from(decoded);
      }
    }

    return <String, Object?>{};
  }

  Future<int> createFootballPhaseTwoScanRun(DateTime date) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO football_scan_runs (scan_date, phase, status)
        VALUES (@date, 2, 'running')
        RETURNING id
      '''),
      parameters: {'date': _dateOnly(date)},
    );
    return result.first[0] as int;
  }

  Future<List<Map<String, Object?>>> eligiblePhaseOneMatches({
    int? scanRunId,
    int limit = 1000000,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT sm.*, sr.scan_date
        FROM football_scan_matches sm
        INNER JOIN football_scan_runs sr ON sr.id = sm.scan_run_id
        WHERE sm.eligible = TRUE
          AND (@scan_run_id::BIGINT IS NULL OR sm.scan_run_id = @scan_run_id)
        ORDER BY sm.created_at ASC
        LIMIT @limit
      '''),
      parameters: {'scan_run_id': scanRunId, 'limit': limit.clamp(1, 100)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<void> savePhaseTwoResult({
    required int scanRunId,
    required String fixtureId,
    required String leagueId,
    required int season,
    required int dataQuality,
    required bool analysisAllowed,
    required Map<String, Object?> availability,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO football_phase_two_results (
          scan_run_id, fixture_id, league_id, season, data_quality,
          analysis_allowed, availability, payload
        ) VALUES (
          @scan_run_id, @fixture_id, @league_id, @season, @data_quality,
          @analysis_allowed, CAST(@availability AS JSONB), CAST(@payload AS JSONB)
        )
        ON CONFLICT (scan_run_id, fixture_id) DO UPDATE SET
          data_quality = EXCLUDED.data_quality,
          analysis_allowed = EXCLUDED.analysis_allowed,
          availability = EXCLUDED.availability,
          payload = EXCLUDED.payload
      '''),
      parameters: {
        'scan_run_id': scanRunId,
        'fixture_id': fixtureId,
        'league_id': leagueId,
        'season': season,
        'data_quality': dataQuality,
        'analysis_allowed': analysisAllowed,
        'availability': jsonEncode(availability),
        'payload': jsonEncode(payload),
      },
    );
  }

  /// Budgetierte Kandidaten für den Hintergrund-Detailscan. Sie verwenden
  /// exakt dieselben Phase-2-/Coverage-Tabellen wie Fokus-Ligen, werden aber
  /// mit `analysis_allowed=false` gespeichert und können daher nie als
  /// öffentlicher Tipp erscheinen.
  Future<List<Map<String, Object?>>> backgroundEnrichmentCandidates({
    required DateTime anchorDate,
    int limit = 30,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          m.id AS fixture_id,
          m.league_id,
          m.raw_json,
          l.collection_tier,
          COALESCE(NULLIF(m.raw_json->>'season', '')::INTEGER,
                   EXTRACT(YEAR FROM m.kickoff_utc)::INTEGER) AS season,
          -- Der PostgreSQL-Spezialwert -infinity kann vom Dart-Postgres-
          -- Treiber nicht als DateTime decodiert werden. Ein festes altes
          -- Datum erfüllt dieselbe Sortiersemantik, ohne den kompletten
          -- Hintergrundlauf bei noch nie angereicherten Spielen zu leeren.
          COALESCE(
            last_detail.created_at,
            TIMESTAMPTZ '1970-01-01 00:00:00+00'
          ) AS last_detail_at,
          l.detail_refresh_hours
        FROM football_matches m
        INNER JOIN football_leagues l ON l.league_id = m.league_id
        LEFT JOIN LATERAL (
          SELECT p.created_at
          FROM football_phase_two_results p
          WHERE p.fixture_id = m.id
          ORDER BY p.created_at DESC
          LIMIT 1
        ) last_detail ON TRUE
        WHERE l.background_enabled = TRUE
          AND l.collection_tier IN ('watchlist', 'data_pool')
          AND m.kickoff_utc >= @from_date
          AND m.kickoff_utc < @until_date
          AND (
            last_detail.created_at IS NULL
            OR last_detail.created_at < NOW()
              - make_interval(hours => l.detail_refresh_hours)
          )
        ORDER BY
          CASE l.collection_tier WHEN 'watchlist' THEN 1 ELSE 2 END,
          last_detail_at ASC,
          m.kickoff_utc ASC
        LIMIT @limit
      '''),
      parameters: {
        'from_date': anchorDate.toUtc().subtract(const Duration(days: 7)),
        'until_date': anchorDate.toUtc().add(const Duration(days: 3)),
        'limit': limit.clamp(1, 100),
      },
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> geminiPhaseTwoCandidates({
    required int phaseTwoScanRunId,
    int limit = 1000000,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT fixture_id, league_id, season, data_quality, availability, payload
        FROM football_phase_two_results
        WHERE scan_run_id = @scan_run_id
          AND analysis_allowed = TRUE
        ORDER BY data_quality DESC, fixture_id
      '''),
      parameters: {'scan_run_id': phaseTwoScanRunId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<void> saveFootballAiContextCheck({
    required int phaseTwoScanRunId,
    required String fixtureId,
    required String model,
    String? responseId,
    required String status,
    required Map<String, Object?> contextResult,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO football_ai_context_checks (
          phase_two_scan_run_id, fixture_id, model, response_id, status,
          context_result
        ) VALUES (
          @scan_run_id, @fixture_id, @model, @response_id, @status,
          CAST(@context_result AS JSONB)
        )
        ON CONFLICT (phase_two_scan_run_id, fixture_id) DO UPDATE SET
          model = EXCLUDED.model,
          response_id = EXCLUDED.response_id,
          status = EXCLUDED.status,
          context_result = EXCLUDED.context_result,
          created_at = NOW()
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'fixture_id': fixtureId,
        'model': model,
        'response_id': responseId,
        'status': status,
        'context_result': jsonEncode(contextResult),
      },
    );
  }

  Future<List<Map<String, Object?>>> phaseFourCandidates({
    required int phaseTwoScanRunId,
    int limit = 1000000,
    bool includeBackground = false,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          p.fixture_id,
          p.league_id,
          p.season,
          p.data_quality,
          p.availability,
          p.payload,
          COALESCE(
            current_context.context_result,
            fallback_context.context_result,
            '{}'::jsonb
          ) AS context_result,
          CASE
            WHEN current_context.context_result IS NOT NULL THEN 'current'
            WHEN fallback_context.context_result IS NOT NULL THEN 'fallback'
            ELSE 'missing'
          END AS context_source,
          COALESCE(
            current_context.phase_two_scan_run_id,
            fallback_context.phase_two_scan_run_id
          ) AS context_source_scan_run_id
        FROM football_phase_two_results p
        LEFT JOIN LATERAL (
          SELECT
            c.phase_two_scan_run_id,
            c.context_result
          FROM football_ai_context_checks c
          WHERE c.phase_two_scan_run_id = p.scan_run_id
            AND c.fixture_id = p.fixture_id
            AND c.status = 'completed'
          ORDER BY c.created_at DESC
          LIMIT 1
        ) current_context ON TRUE
        LEFT JOIN LATERAL (
          SELECT
            c.phase_two_scan_run_id,
            c.context_result
          FROM football_ai_context_checks c
          WHERE c.fixture_id = p.fixture_id
            AND c.phase_two_scan_run_id <> p.scan_run_id
            AND c.status = 'completed'
            AND c.created_at >= NOW() - INTERVAL '12 hours'
            AND COALESCE(
              NULLIF(
                c.context_result #>> '{context,applied}',
                ''
              )::boolean,
              FALSE
            ) = TRUE
          ORDER BY c.created_at DESC
          LIMIT 1
        ) fallback_context
          ON current_context.context_result IS NULL
        WHERE p.scan_run_id = @scan_run_id
          AND (p.analysis_allowed = TRUE OR @include_background = TRUE)
        ORDER BY p.data_quality DESC, p.fixture_id
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'include_background': includeBackground,
      },
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<void> saveFootballEngineInput({
    required int phaseTwoScanRunId,
    required String fixtureId,
    required String leagueId,
    required int season,
    required int dataQuality,
    required String modelVersion,
    required Map<String, Object?> normalizedInput,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO football_engine_inputs (
          phase_two_scan_run_id, fixture_id, league_id, season,
          data_quality, model_version, normalized_input
        ) VALUES (
          @scan_run_id, @fixture_id, @league_id, @season,
          @data_quality, @model_version, CAST(@normalized_input AS JSONB)
        )
        ON CONFLICT (phase_two_scan_run_id, fixture_id) DO UPDATE SET
          data_quality = EXCLUDED.data_quality,
          model_version = EXCLUDED.model_version,
          normalized_input = EXCLUDED.normalized_input,
          created_at = NOW()
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'fixture_id': fixtureId,
        'league_id': leagueId,
        'season': season,
        'data_quality': dataQuality,
        'model_version': modelVersion,
        'normalized_input': jsonEncode(normalizedInput),
      },
    );
  }

  Future<List<Map<String, Object?>>> engineInputsForSimulation({
    required int phaseTwoScanRunId,
    int limit = 1000000,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT fixture_id, normalized_input
        FROM football_engine_inputs
        WHERE phase_two_scan_run_id = @scan_run_id
        ORDER BY data_quality DESC, fixture_id
      '''),
      parameters: {'scan_run_id': phaseTwoScanRunId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<void> saveFootballSimulationResult({
    required int phaseTwoScanRunId,
    required String fixtureId,
    required String modelVersion,
    required int simulations,
    required Map<String, Object?> result,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO football_simulation_results (
          phase_two_scan_run_id, fixture_id, model_version, simulations, result
        ) VALUES (
          @scan_run_id, @fixture_id, @model_version, @simulations,
          CAST(@result AS JSONB)
        )
        ON CONFLICT (phase_two_scan_run_id, fixture_id) DO UPDATE SET
          model_version = EXCLUDED.model_version,
          simulations = EXCLUDED.simulations,
          result = EXCLUDED.result,
          created_at = NOW()
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'fixture_id': fixtureId,
        'model_version': modelVersion,
        'simulations': simulations,
        'result': jsonEncode(result),
      },
    );
  }

  Future<List<Map<String, Object?>>> simulationRowsForSelection({
    required int phaseTwoScanRunId,
    int limit = 1000000,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT fixture_id, result
        FROM football_simulation_results
        WHERE phase_two_scan_run_id = @scan_run_id
        ORDER BY fixture_id
      '''),
      parameters: {'scan_run_id': phaseTwoScanRunId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<void> saveFootballMarketSelection({
    required int phaseTwoScanRunId,
    required String fixtureId,
    required String modelVersion,
    required Map<String, Object?> selection,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO football_market_selections (
          phase_two_scan_run_id, fixture_id, model_version, selection
        ) VALUES (
          @scan_run_id, @fixture_id, @model_version, CAST(@selection AS JSONB)
        )
        ON CONFLICT (phase_two_scan_run_id, fixture_id) DO UPDATE SET
          model_version = EXCLUDED.model_version,
          selection = EXCLUDED.selection,
          created_at = NOW()
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'fixture_id': fixtureId,
        'model_version': modelVersion,
        'selection': jsonEncode(selection),
      },
    );
  }

  Future<List<Map<String, Object?>>> marketSelectionsForValue({
    required int phaseTwoScanRunId,
    int limit = 1000000,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT fixture_id, selection
        FROM football_market_selections
        WHERE phase_two_scan_run_id = @scan_run_id
        ORDER BY fixture_id
      '''),
      parameters: {'scan_run_id': phaseTwoScanRunId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<List<Map<String, Object?>>> finalizationCandidates({
    required int phaseTwoScanRunId,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          p.fixture_id,
          p.data_quality,
          p.payload,
          s.result AS simulation,
          m.selection
        FROM football_phase_two_results p
        INNER JOIN football_simulation_results s
          ON s.phase_two_scan_run_id = p.scan_run_id
         AND s.fixture_id = p.fixture_id
        INNER JOIN football_market_selections m
          ON m.phase_two_scan_run_id = p.scan_run_id
         AND m.fixture_id = p.fixture_id
        WHERE p.scan_run_id = @scan_run_id
          AND p.analysis_allowed = TRUE
        ORDER BY p.fixture_id
      '''),
      parameters: {'scan_run_id': phaseTwoScanRunId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Vollständig berechnete, aber nicht veröffentlichte Shadow-Analysen für
  /// Beobachtungsliste und Datenpool. Diese Fixtures durchlaufen dieselbe
  /// Engine, Simulation und Marktauswahl wie Fokus-Ligen, werden jedoch nie
  /// in [football_analysis_history] geschrieben. Dadurch bleiben öffentliche
  /// Tipps und deren ROI sauber, während das Control Center die Einschätzung
  /// für Learning und Qualitätskontrolle anzeigen kann.
  Future<List<Map<String, Object?>>> backgroundAnalysisCandidates({
    required int phaseTwoScanRunId,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          p.fixture_id,
          p.data_quality,
          p.payload,
          s.result AS simulation,
          m.selection
        FROM football_phase_two_results p
        INNER JOIN football_simulation_results s
          ON s.phase_two_scan_run_id = p.scan_run_id
         AND s.fixture_id = p.fixture_id
        LEFT JOIN football_market_selections m
          ON m.phase_two_scan_run_id = p.scan_run_id
         AND m.fixture_id = p.fixture_id
        WHERE p.scan_run_id = @scan_run_id
          AND p.analysis_allowed = FALSE
        ORDER BY p.fixture_id
      '''),
      parameters: {'scan_run_id': phaseTwoScanRunId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<void> upsertFootballMatchFromPayload({
    required String fixtureId,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    final kickoff = DateTime.tryParse(payload['kickoff']?.toString() ?? '') ??
        DateTime.now().toUtc();
    await db.execute(
      Sql.named('''
        INSERT INTO football_matches (
          id, kickoff_utc, status, league_id, league_name, country,
          home_team_id, home_team_name, home_logo,
          away_team_id, away_team_name, away_logo,
          home_goals, away_goals, raw_json
        ) VALUES (
          @id, @kickoff, @status, @league_id, @league_name, @country,
          @home_team_id, @home_team_name, @home_logo,
          @away_team_id, @away_team_name, @away_logo,
          @home_goals, @away_goals, CAST(@raw_json AS JSONB)
        )
        ON CONFLICT (id) DO UPDATE SET
          kickoff_utc = EXCLUDED.kickoff_utc,
          -- Section "manuelle Statusübersteuerung": ein von einem Mitarbeiter
          -- gesperrtes Spiel (z.B. manuell als "Abgesagt" markiert) darf
          -- nicht durch den nächsten Provider-Sync stillschweigend
          -- überschrieben werden. status_locked bleibt aktiv, bis ein
          -- Mitarbeiter es bewusst wieder aufhebt (clearFootballMatchStatusOverride).
          status = CASE WHEN football_matches.status_locked
            THEN football_matches.status ELSE EXCLUDED.status END,
          home_goals = CASE WHEN football_matches.status_locked
            THEN football_matches.home_goals ELSE EXCLUDED.home_goals END,
          away_goals = CASE WHEN football_matches.status_locked
            THEN football_matches.away_goals ELSE EXCLUDED.away_goals END,
          league_id = EXCLUDED.league_id,
          league_name = EXCLUDED.league_name,
          country = EXCLUDED.country,
          home_team_id = EXCLUDED.home_team_id,
          home_team_name = EXCLUDED.home_team_name,
          home_logo = EXCLUDED.home_logo,
          away_team_id = EXCLUDED.away_team_id,
          away_team_name = EXCLUDED.away_team_name,
          away_logo = EXCLUDED.away_logo,
          raw_json = EXCLUDED.raw_json,
          updated_at = NOW()
      '''),
      parameters: {
        'id': fixtureId,
        'kickoff': kickoff.toUtc(),
        'status': payload['status']?.toString() ?? 'NS',
        'league_id': payload['leagueId']?.toString() ?? '',
        'league_name': payload['league']?.toString() ?? '',
        'country': payload['country']?.toString() ?? '',
        'home_team_id': payload['homeTeamId']?.toString() ?? '',
        'home_team_name': payload['homeTeam']?.toString() ?? '',
        'home_logo': payload['homeLogo']?.toString() ?? '',
        'away_team_id': payload['awayTeamId']?.toString() ?? '',
        'away_team_name': payload['awayTeam']?.toString() ?? '',
        'away_logo': payload['awayLogo']?.toString() ?? '',
        'home_goals': payload['homeGoals'],
        'away_goals': payload['awayGoals'],
        'raw_json': jsonEncode(payload),
      },
    );
  }

  /// Analysierte, aber noch nicht final abgerechnete Spiele: Phase-2-Daten
  /// liegen vor, der Anstoß ist alt genug für ein Endergebnis, und der
  /// gespeicherte Status ist noch nicht final. Dieselbe Abfrage bedient sowohl
  /// den einmaligen Backfill als auch den wiederkehrenden Tages-Check, damit
  /// beide denselben "offen"-Begriff verwenden (Status, nicht Tore-NULL -
  /// ein 0:0-Endstand hat sonst fälschlich weiter als offen gegolten).
  /// Section 11: "Vor Start Kandidatenzahl ... zeigen" - dieselbe
  /// WHERE-Klausel wie [footballMatchResultCandidates], nur als reine
  /// COUNT-Abfrage ohne LIMIT, damit die UI vor dem Start weiß, wie viele
  /// Spiele (und damit ungefähr wie viele Provider-Anfragen) ein Lauf
  /// betreffen würde.
  Future<int> footballMatchResultCandidateCount({
    required int minHoursSinceKickoff,
  }) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        SELECT COUNT(*) AS total
        FROM football_matches
        WHERE raw_json ? 'phaseTwo'
          AND id <> ''
          AND kickoff_utc <= NOW() - make_interval(hours => @hours)
          AND status NOT IN ('FT','AET','PEN','AWD','WO','CANC','ABD')
      '''),
      parameters: {'hours': minHoursSinceKickoff.clamp(0, 24 * 30)},
    );
    return int.tryParse(rows.first.toColumnMap()['total']?.toString() ?? '') ??
        0;
  }

  Future<List<Map<String, Object?>>> footballMatchResultCandidates({
    required int minHoursSinceKickoff,
    required int limit,
  }) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        SELECT id, status
        FROM football_matches
        WHERE raw_json ? 'phaseTwo'
          AND id <> ''
          AND kickoff_utc <= NOW() - make_interval(hours => @hours)
          AND status NOT IN ('FT','AET','PEN','AWD','WO','CANC','ABD')
        ORDER BY kickoff_utc ASC
        LIMIT @limit
      '''),
      parameters: {
        'hours': minHoursSinceKickoff.clamp(0, 24 * 30),
        'limit': limit.clamp(1, 200),
      },
    );
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Schreibt ausschließlich Ergebnis-/Statusfelder für ein bereits
  /// gespeichertes Spiel. `raw_json` wird gezielt per JSONB-Merge ergänzt
  /// (`||`), niemals ersetzt - alle Pre-Match-Blöcke (phaseOne, phaseTwo,
  /// Quoten, Formdaten, H2H, Gemini-Kontext, ...) bleiben unangetastet.
  /// `jsonb_strip_nulls` verhindert, dass ein noch fehlendes Tor-Feld (z. B.
  /// bei abgesagten Spielen) einen zuvor gültigen Wert mit NULL überschreibt.
  Future<void> settleFootballMatchResult({
    required String fixtureId,
    required String status,
    int? homeGoals,
    int? awayGoals,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE football_matches SET
          status = @status,
          home_goals = @home_goals,
          away_goals = @away_goals,
          raw_json = raw_json || jsonb_strip_nulls(jsonb_build_object(
            'status', CAST(@status AS TEXT),
            'homeGoals', CAST(@home_goals AS INTEGER),
            'awayGoals', CAST(@away_goals AS INTEGER)
          )),
          updated_at = NOW()
        WHERE id = @id
      '''),
      parameters: {
        'id': fixtureId,
        'status': status,
        'home_goals': homeGoals,
        'away_goals': awayGoals,
      },
    );
  }

  Future<int> createFootballMatchSettlementJob({
    required int minHoursSinceKickoff,
    required int batchSize,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO football_match_settlement_jobs (
          min_hours_since_kickoff, batch_size
        ) VALUES (@hours, @batch_size)
        RETURNING id
      '''),
      parameters: {
        'hours': minHoursSinceKickoff,
        'batch_size': batchSize,
      },
    );
    return result.first[0] as int;
  }

  Future<void> updateFootballMatchSettlementJob({
    required int jobId,
    required String status,
    int? checked,
    int? settled,
    int? pending,
    int? failed,
    Object? error,
    // Letzte pro-Fixture-Fehlermeldung (z. B. "Football API HTTP 429").
    // Einzelne Fixture-Fehler brechen den Job nicht ab, sollen aber sichtbar
    // bleiben - deshalb per COALESCE nur bei einem neuen Fehler überschrieben.
    String? lastError,
    bool completed = false,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE football_match_settlement_jobs SET
          status = @status,
          checked = COALESCE(@checked, checked),
          settled = COALESCE(@settled, settled),
          pending = COALESCE(@pending, pending),
          failed = COALESCE(@failed, failed),
          error = @error,
          last_error = COALESCE(@last_error, last_error),
          completed_at = CASE WHEN @completed THEN NOW() ELSE completed_at END
        WHERE id = @job_id
      '''),
      parameters: {
        'job_id': jobId,
        'status': status,
        'checked': checked,
        'settled': settled,
        'pending': pending,
        'failed': failed,
        'error': error?.toString(),
        'last_error': lastError,
        'completed': completed,
      },
    );
  }

  /// Neueste Settlement-Backfill-Läufe, neueste zuerst. Read-only, für das
  /// Control-Center-Settlement-Panel (kein "list jobs"-Endpoint existierte
  /// bisher, nur die Einzelabfrage per ID).
  Future<List<Map<String, Object?>>> recentFootballMatchSettlementJobs({
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          id, status, min_hours_since_kickoff, batch_size,
          checked, settled, pending, failed, error, last_error,
          created_at::text AS created_at,
          completed_at::text AS completed_at
        FROM football_match_settlement_jobs
        ORDER BY id DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit.clamp(1, 100)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<Map<String, Object?>?> footballMatchSettlementJob(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          id, status, min_hours_since_kickoff, batch_size,
          checked, settled, pending, failed, error, last_error,
          created_at::text AS created_at,
          completed_at::text AS completed_at
        FROM football_match_settlement_jobs
        WHERE id = @id
        LIMIT 1
      '''),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Read-only Kontrollzahlen für den Phase-2-Ergebnis-Backfill. Rein
  /// lesend, keine Schreiboperation.
  Future<Map<String, Object?>> footballMatchResultCoverage() async {
    final db = await connection();
    final counts = await db.execute('''
      SELECT
        COUNT(*) FILTER (
          WHERE raw_json->'phaseTwo' IS NOT NULL
            AND raw_json->>'homeGoals' IS NOT NULL
            AND raw_json->>'awayGoals' IS NOT NULL
        ) AS phase2_mit_ergebnis,
        COUNT(*) FILTER (
          WHERE COALESCE((raw_json#>>'{phaseTwo,dataQuality}')::int, 0) >= 40
            AND raw_json->>'homeGoals' IS NOT NULL
            AND raw_json->>'awayGoals' IS NOT NULL
        ) AS qualitaet40_mit_ergebnis,
        COUNT(*) FILTER (
          WHERE COALESCE((raw_json#>>'{phaseTwo,dataQuality}')::int, 0) >= 50
            AND raw_json->>'homeGoals' IS NOT NULL
            AND raw_json->>'awayGoals' IS NOT NULL
        ) AS qualitaet50_mit_ergebnis
      FROM football_matches
    ''');
    final stillOpen = await db.execute('''
      SELECT COUNT(*) AS weiterhin_offen
      FROM football_matches
      WHERE raw_json->'phaseTwo' IS NOT NULL
        AND kickoff_utc < NOW() - INTERVAL '4 hours'
        AND (
          raw_json->>'homeGoals' IS NULL
          OR raw_json->>'awayGoals' IS NULL
        )
    ''');
    final row = Map<String, Object?>.from(counts.first.toColumnMap());
    row['weiterhin_offen'] = stillOpen.first[0];
    return row;
  }

  // ---------------------------------------------------------------------
  // Historical Twins V1
  // ---------------------------------------------------------------------

  Future<Map<String, Object?>?> footballMatchForTwin(String fixtureId) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        SELECT id, home_team_name, away_team_name, league_name, country,
               kickoff_utc, raw_json
        FROM football_matches
        WHERE id = @id
        LIMIT 1
      '''),
      parameters: {'id': fixtureId},
    );
    if (rows.isEmpty) return null;
    return Map<String, Object?>.from(rows.first.toColumnMap());
  }

  /// Neuestes Phase-4-Engine-Input für ein Fixture (Torraten-Heim-/Auswärts-
  /// Profil, siehe FootballEngineInputService). Historical Twins lesen
  /// ausschließlich Pre-Match-Felder daraus - niemals Simulation, faire
  /// Quote oder Tipp.
  Future<Map<String, Object?>?> latestFootballEngineInput(
    String fixtureId,
  ) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        SELECT normalized_input
        FROM football_engine_inputs
        WHERE fixture_id = @fixture_id
        ORDER BY created_at DESC
        LIMIT 1
      '''),
      parameters: {'fixture_id': fixtureId},
    );
    if (rows.isEmpty) return null;
    final value = rows.first[0];
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  /// Grobe SQL-Vorfilterung für die Similarity-Berechnung (siehe Vorgabe 23):
  /// schneidet den Suchraum anhand der Elo-Differenz und der Data Coverage
  /// zu, bevor die exakte, gewichtete Ähnlichkeit in Dart berechnet wird.
  /// KEIN harter Liga-/Ligastufen-Filter.
  Future<List<Map<String, Object?>>> historicalTwinCandidates({
    double? eloDifference,
    double eloTolerance = 220,
    double minDataCoverage = 40,
    int limit = 4000,
  }) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        SELECT
          id, source, division, match_date, home_team, away_team,
          home_goals, away_goals, result, home_elo, away_elo,
          elo_difference, absolute_elo_level, form3_home, form5_home,
          form3_away, form5_away, normalized_home_probability,
          normalized_draw_probability, normalized_away_probability,
          over25_probability, under25_probability, features,
          data_coverage_percent
        FROM historical_twin_matches
        WHERE data_coverage_percent >= @min_coverage
          AND (
            CAST(@elo_diff AS DOUBLE PRECISION) IS NULL
            OR elo_difference IS NULL
            OR ABS(elo_difference - CAST(@elo_diff AS DOUBLE PRECISION))
               < CAST(@elo_tolerance AS DOUBLE PRECISION)
          )
        ORDER BY data_coverage_percent DESC
        LIMIT @limit
      '''),
      parameters: {
        'min_coverage': minDataCoverage,
        'elo_diff': eloDifference,
        'elo_tolerance': eloTolerance,
        'limit': limit,
      },
    );
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Liefert den stabilen, zuletzt gespeicherten Spielplan einer Tages- und
  /// Liga-Whitelist. Phase-1-Datensätze ergänzen dabei Spiele, die bewusst
  /// keine Analyse erhalten haben (live, beendet, abgesagt oder ohne Details).
  /// Dadurch hängt die App-Anzeige nicht an einer neuen Provider-Abfrage.
  Future<List<Map<String, Object?>>> cachedWhitelistedFootballMatchesForDate(
    DateTime date,
  ) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        WITH candidates AS (
          SELECT
            m.id AS fixture_id,
            m.raw_json AS payload,
            m.kickoff_utc,
            2 AS source_priority
          FROM football_matches m
          INNER JOIN football_leagues l ON l.league_id = m.league_id
          WHERE l.manual_status = 'whitelist'
            AND (m.kickoff_utc AT TIME ZONE 'Europe/Berlin')::date =
                CAST(@day AS DATE)

          UNION ALL

          SELECT
            sm.fixture_id,
            sm.payload,
            NULL::TIMESTAMPTZ AS kickoff_utc,
            1 AS source_priority
          FROM football_scan_matches sm
          INNER JOIN football_scan_runs sr ON sr.id = sm.scan_run_id
          INNER JOIN football_leagues l ON l.league_id = sm.league_id
          WHERE l.manual_status = 'whitelist'
            AND sr.scan_date = CAST(@day AS DATE)
        ), chosen AS (
          SELECT DISTINCT ON (fixture_id)
            fixture_id, payload, kickoff_utc
          FROM candidates
          WHERE fixture_id <> ''
          ORDER BY fixture_id, source_priority DESC
        )
        SELECT payload
        FROM chosen
        ORDER BY kickoff_utc NULLS LAST, fixture_id
      '''),
      parameters: {'day': _dateOnly(date)},
    );

    return rows
        .map((row) => _jsonMap(row[0]))
        .where((payload) => payload.isNotEmpty)
        .toList(growable: false);
  }

  /// Publizierte Pre-Match-Analysen sind ein Snapshot. Nachfolgende Scans
  /// dürfen sie weder neu berechnen noch den Tipp austauschen; sie können
  /// lediglich Match-Status und Ergebnis in `football_matches` aktualisieren.
  Future<bool> saveFinalFootballAnalysis({
    required String fixtureId,
    required String modelVersion,
    required int dataQuality,
    required int confidence,
    String? recommendation,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        INSERT INTO analyses (
          sport, match_id, model_version, data_quality,
          confidence, recommendation, payload
        ) VALUES (
          'football', @match_id, @model_version, @data_quality,
          @confidence, @recommendation, CAST(@payload AS JSONB)
        )
        ON CONFLICT (sport, match_id, model_version) DO NOTHING
        RETURNING id
      '''),
      parameters: {
        'match_id': fixtureId,
        'model_version': modelVersion,
        'data_quality': dataQuality,
        'confidence': confidence,
        'recommendation': recommendation,
        'payload': jsonEncode(payload),
      },
    );
    return rows.isNotEmpty;
  }

  /// Speichert den aktuellen Learning-/Shadow-Stand eines Hintergrundspiels.
  /// Das eigene Model-Version-Suffix trennt ihn zuverlässig von der
  /// unveränderlichen, öffentlichen Pre-Match-Prognose.
  Future<void> upsertFootballShadowAnalysis({
    required String fixtureId,
    required int dataQuality,
    required int confidence,
    String? recommendation,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO analyses (
          sport, match_id, model_version, data_quality,
          confidence, recommendation, payload
        ) VALUES (
          'football', @match_id, 'phoenix_shadow_learning_v1',
          @data_quality, @confidence, @recommendation,
          CAST(@payload AS JSONB)
        )
        ON CONFLICT (sport, match_id, model_version) DO UPDATE SET
          data_quality = EXCLUDED.data_quality,
          confidence = EXCLUDED.confidence,
          recommendation = EXCLUDED.recommendation,
          payload = EXCLUDED.payload,
          analyzed_at = NOW()
      '''),
      parameters: {
        'match_id': fixtureId,
        'data_quality': dataQuality.clamp(0, 100),
        'confidence': confidence.clamp(0, 100),
        'recommendation': recommendation,
        'payload': jsonEncode(payload),
      },
    );
  }

  Future<void> saveFootballAnalysisHistory({
    required int phaseTwoScanRunId,
    required String fixtureId,
    required String modelVersion,
    required int dataQuality,
    required int confidence,
    required Map<String, Object?> payload,
  }) async {
    final db = await connection();
    final tip = _jsonMap(payload['phoenixTip']);
    final selection = _jsonMap(payload['selection']);
    final value = _jsonMap(selection['value']);
    final marketKey = tip['marketKey']?.toString() ?? '';
    final oddsByKey = _jsonMap(payload['marketOddsByKey']);
    final rawMarketOdds = oddsByKey[marketKey] ?? value['marketOdds'];
    final marketOdds = rawMarketOdds is num
        ? rawMarketOdds.toDouble()
        : double.tryParse(rawMarketOdds?.toString() ?? '');
    // New PHOENIX top tips get one comparable unit only when the same market
    // has a verified, practice-safe bookmaker quote. Model-only selections
    // remain in history but cannot distort ROI with a synthetic price.
    final assignedUnits = marketKey.isNotEmpty &&
            marketOdds != null &&
            marketOdds >= 1.20 &&
            marketOdds <= 4.0
        ? 1.0
        : 0.0;
    final kickoff = DateTime.tryParse(payload['kickoff']?.toString() ?? '');
    final predictionDate =
        kickoff?.toUtc().toIso8601String().substring(0, 10) ??
            DateTime.now().toUtc().toIso8601String().substring(0, 10);
    await db.execute(
      Sql.named('''
        INSERT INTO football_analysis_history (
          phase_two_scan_run_id, fixture_id, prediction_date, kickoff,
          model_version, market_key, market_label, model_probability,
          fair_odds, market_odds, assigned_units, data_quality, confidence,
          payload
        ) VALUES (
          @scan_run_id, @fixture_id, CAST(@prediction_date AS DATE),
          CAST(NULLIF(@kickoff, '') AS TIMESTAMPTZ), @model_version,
          @market_key, @market_label, @model_probability, @fair_odds,
          @market_odds, @assigned_units, @data_quality, @confidence,
          CAST(@payload AS JSONB)
        )
        ON CONFLICT (phase_two_scan_run_id, fixture_id) DO NOTHING
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'fixture_id': fixtureId,
        'prediction_date': predictionDate,
        'kickoff': kickoff?.toUtc().toIso8601String() ?? '',
        'model_version': modelVersion,
        'market_key': marketKey,
        'market_label': tip['market']?.toString() ?? '',
        'model_probability': tip['probability'],
        'fair_odds': tip['fairOdds'],
        'market_odds': marketOdds,
        'assigned_units': assignedUnits,
        'data_quality': dataQuality,
        'confidence': confidence,
        'payload': jsonEncode(payload),
      },
    );
  }

  /// Alle PHÖNIX-Tipps für das Control Center (Section 14) - dieselbe
  /// "letzte Analyse pro Fixture"-Auswahl wie die App
  /// (analyses/preparedFootballAnalyses), aber gespeist aus
  /// `football_analysis_history`, weil dort zusätzlich Settlement-Ergebnis
  /// (`result_status`/`profit_units`), Value-Flag und Modellversion pro Lauf
  /// erhalten bleiben. So zeigt das Control Center garantiert dieselben
  /// Tipps wie die App, nur mit mehr Kontext für Mitarbeiter.
  Future<Map<String, Object?>> listFootballTipsAdmin({
    String? dateFrom,
    String? dateTo,
    String? leagueId,
    String? teamId,
    String? marketKey,
    String? resultStatus,
    int? minDataQuality,
    int? minConfidence,
    String? modelVersion,
    bool? isValueTip,
    bool? hasTip,
    String? whitelistStatus,
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await connection();
    final conditions = <String>[];
    final parameters = <String, Object?>{};

    if (dateFrom != null && dateFrom.trim().isNotEmpty) {
      conditions.add('l.prediction_date >= CAST(@date_from AS DATE)');
      parameters['date_from'] = dateFrom.trim();
    }
    if (dateTo != null && dateTo.trim().isNotEmpty) {
      conditions.add('l.prediction_date <= CAST(@date_to AS DATE)');
      parameters['date_to'] = dateTo.trim();
    }
    if (leagueId != null && leagueId.trim().isNotEmpty) {
      conditions.add('m.league_id = @league_id');
      parameters['league_id'] = leagueId.trim();
    }
    if (teamId != null && teamId.trim().isNotEmpty) {
      conditions
          .add('(m.home_team_id = @team_id OR m.away_team_id = @team_id)');
      parameters['team_id'] = teamId.trim();
    }
    if (marketKey != null && marketKey.trim().isNotEmpty) {
      conditions.add('l.market_key = @market_key');
      parameters['market_key'] = marketKey.trim();
    }
    if (resultStatus != null && resultStatus.trim().isNotEmpty) {
      conditions.add('l.result_status = @result_status');
      parameters['result_status'] = resultStatus.trim();
    }
    if (minDataQuality != null) {
      conditions.add('l.data_quality >= @min_data_quality');
      parameters['min_data_quality'] = minDataQuality.clamp(0, 100);
    }
    if (minConfidence != null) {
      conditions.add('l.confidence >= @min_confidence');
      parameters['min_confidence'] = minConfidence.clamp(0, 100);
    }
    if (modelVersion != null && modelVersion.trim().isNotEmpty) {
      conditions.add('l.model_version = @model_version');
      parameters['model_version'] = modelVersion.trim();
    }
    if (isValueTip != null) {
      conditions.add(
        "COALESCE((l.payload #>> '{selection,value,isValueTip}')::boolean, false) = @is_value_tip",
      );
      parameters['is_value_tip'] = isValueTip;
    }
    if (hasTip != null) {
      conditions.add(hasTip ? "l.market_key <> ''" : "l.market_key = ''");
    }
    if (whitelistStatus != null && whitelistStatus.trim().isNotEmpty) {
      conditions.add('fl.manual_status = @whitelist_status');
      parameters['whitelist_status'] = whitelistStatus.trim();
    }

    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final rows = await db.execute(
      Sql.named('''
        WITH latest AS (
          SELECT DISTINCT ON (fixture_id) *
          FROM football_analysis_history
          ORDER BY fixture_id, created_at DESC
        )
        SELECT
          l.phase_two_scan_run_id, l.fixture_id, l.prediction_date, l.kickoff,
          l.model_version, l.market_key, l.market_label, l.model_probability,
          l.fair_odds, l.market_odds, l.assigned_units, l.data_quality,
          l.confidence, l.result_status, l.home_score, l.away_score,
          l.profit_units, l.settled_at, l.created_at,
          COALESCE((l.payload #>> '{selection,value,isValueTip}')::boolean, false)
            AS is_value_tip,
          COALESCE(
            NULLIF(l.payload #>> '{selection,value,valuePercent}', '')::double precision,
            0
          ) AS value_percent,
          COALESCE((l.payload->>'simulationCount')::int, 0) AS simulation_count,
          m.league_id, m.league_name, m.country,
          m.home_team_id, m.home_team_name, m.home_logo,
          m.away_team_id, m.away_team_name, m.away_logo,
          m.status AS match_status,
          fl.manual_status AS whitelist_status,
          COUNT(*) OVER () AS total_count
        FROM latest l
        INNER JOIN football_matches m ON m.id = l.fixture_id
        LEFT JOIN football_leagues fl ON fl.league_id = m.league_id
        $whereClause
        ORDER BY l.kickoff DESC NULLS LAST
        LIMIT @limit OFFSET @offset
      '''),
      parameters: {
        ...parameters,
        'limit': limit.clamp(1, 200),
        'offset': offset.clamp(0, 1 << 30)
      },
    );

    // COUNT(*) OVER() liefert die Gesamtzahl zusammen mit der Datenabfrage.
    // Zuvor wurde die teure DISTINCT-ON-Abfrage ein zweites Mal nur für den
    // Pagination-Count ausgeführt; das war die Hauptursache für Ladezeiten
    // von mehr als einer Minute im Control Center.
    final total = rows.isEmpty
        ? 0
        : int.tryParse(
                rows.first.toColumnMap()['total_count']?.toString() ?? '') ??
            0;

    final tips = rows.map((row) {
      final value = Map<String, Object?>.from(row.toColumnMap());
      value.remove('total_count');
      for (final key in const [
        'prediction_date',
        'kickoff',
        'settled_at',
        'created_at',
      ]) {
        final timestamp = value[key];
        if (timestamp is DateTime) {
          value[key] = timestamp.toUtc().toIso8601String();
        }
      }
      return value;
    }).toList(growable: false);

    return {
      'tips': tips,
      'total': total,
      'limit': limit,
      'offset': offset,
    };
  }

  /// Vollständige Analyse-Historie (alle Läufe, nicht nur der letzte) für ein
  /// einzelnes Fixture - Section 17 "Analyse-Historie" im Control Center.
  Future<List<Map<String, Object?>>> footballAnalysisHistoryForFixture(
    String fixtureId,
  ) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          phase_two_scan_run_id, fixture_id, prediction_date, kickoff,
          model_version, market_key, market_label, model_probability,
          fair_odds, market_odds, assigned_units, data_quality, confidence,
          result_status, home_score, away_score, profit_units, settled_at,
          created_at,
          COALESCE((payload #>> '{selection,value,isValueTip}')::boolean, false)
            AS is_value_tip,
          COALESCE(
            NULLIF(payload #>> '{selection,value,valuePercent}', '')::double precision,
            0
          ) AS value_percent
        FROM football_analysis_history
        WHERE fixture_id = @fixture_id
        ORDER BY created_at ASC
      '''),
      parameters: {'fixture_id': fixtureId},
    );
    return result.map((row) {
      final value = Map<String, Object?>.from(row.toColumnMap());
      for (final key in const [
        'prediction_date',
        'kickoff',
        'settled_at',
        'created_at',
      ]) {
        final timestamp = value[key];
        if (timestamp is DateTime) {
          value[key] = timestamp.toUtc().toIso8601String();
        }
      }
      return value;
    }).toList(growable: false);
  }

  /// Section "PHÖNIX Analytics-Profile", Punkt 23 (verbindlich): Trefferquote/
  /// ROI/Yield werden HIER, serverseitig, über den vollständigen gefilterten
  /// Datensatz berechnet - niemals im Frontend aus einer paginierten Zeilen-
  /// menge. Nutzt exakt dieselbe Formel wie [footballPerformanceSummary]
  /// (Punkt 24: eine zentrale Definition, nicht zweimal unterschiedlich
  /// erfunden): Trefferquote = gewonnen / (gewonnen + verloren), Void/Push
  /// zählen nicht als verloren; ROI = Gewinn / Einsatz. "Yield" ist bei
  /// PHÖNIX' einheitlicher 1-Unit-Einsatzgröße rechnerisch identisch zur ROI
  /// (Einsatz pro gezähltem Tipp ist konstant) - wird deshalb bewusst NICHT
  /// separat neu erfunden, sondern als derselbe Wert mit eigenem Label
  /// zurückgegeben (das Frontend erklärt das per Tooltip, keine stille
  /// Verdopplung ohne Erklärung).
  ///
  /// Basis ist wie bei [footballPerformanceSummary] die "first_predictions"-
  /// Auswahl (erste Analyse je Tag x Fixture) - ein späterer Rescan
  /// desselben Tages darf dieselbe Wette nicht doppelt zählen.
  Future<Map<String, Object?>> footballEntityPerformance({
    String? leagueId,
    String? teamId,
    String? marketKey,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? homeAway,
    int? minDataQuality,
    int? minConfidence,
    double? minValue,
    String? groupByTime,
    bool includeMarketBreakdown = false,
    bool includeTeamBreakdown = false,
    bool includePreviousPeriod = false,
  }) async {
    final db = await connection();
    final conditions = <String>[];
    final parameters = <String, Object?>{};

    if (leagueId != null && leagueId.trim().isNotEmpty) {
      conditions.add('m.league_id = @league_id');
      parameters['league_id'] = leagueId.trim();
    }
    if (teamId != null && teamId.trim().isNotEmpty) {
      if (homeAway == 'home') {
        conditions.add('m.home_team_id = @team_id');
      } else if (homeAway == 'away') {
        conditions.add('m.away_team_id = @team_id');
      } else {
        conditions
            .add('(m.home_team_id = @team_id OR m.away_team_id = @team_id)');
      }
      parameters['team_id'] = teamId.trim();
    }
    if (marketKey != null && marketKey.trim().isNotEmpty) {
      conditions.add('h.market_key = @market_key');
      parameters['market_key'] = marketKey.trim();
    }
    if (minDataQuality != null) {
      conditions.add('h.data_quality >= @min_dq');
      parameters['min_dq'] = minDataQuality.clamp(0, 100);
    }
    if (minConfidence != null) {
      conditions.add('h.confidence >= @min_conf');
      parameters['min_conf'] = minConfidence.clamp(0, 100);
    }
    if (minValue != null) {
      conditions.add('''
        COALESCE(NULLIF(h.payload #>> '{selection,value,valuePercent}', ''), '0')::double precision
          >= @min_value
      ''');
      parameters['min_value'] = minValue;
    }

    Future<Map<String, Object?>> summaryFor(
      DateTime? from,
      DateTime? to,
    ) async {
      final periodConditions = List<String>.from(conditions);
      final periodParameters = Map<String, Object?>.from(parameters);
      if (from != null) {
        periodConditions.add(
            'COALESCE(h.kickoff, h.prediction_date::timestamptz) >= @date_from');
        periodParameters['date_from'] = from.toUtc();
      }
      if (to != null) {
        periodConditions.add(
            'COALESCE(h.kickoff, h.prediction_date::timestamptz) < @date_to');
        periodParameters['date_to'] = to.toUtc();
      }
      final where = periodConditions.isEmpty
          ? ''
          : 'WHERE ${periodConditions.join(' AND ')}';

      final result = await db.execute(
        Sql.named('''
          WITH first_predictions AS (
            SELECT DISTINCT ON (h.prediction_date, h.fixture_id)
              h.market_key, h.market_odds, h.assigned_units, h.result_status,
              h.profit_units, h.kickoff,
              COALESCE(
                NULLIF(h.payload #>> '{selection,value,valuePercent}', ''), '0'
              )::double precision AS value_percent
            FROM football_analysis_history h
            INNER JOIN football_matches m ON m.id = h.fixture_id
            $where
            ORDER BY h.prediction_date, h.fixture_id, h.created_at ASC
          )
          SELECT
            COUNT(*) AS total,
            COUNT(*) FILTER (WHERE market_key <> '') AS with_tip,
            COUNT(*) FILTER (WHERE result_status = 'pending') AS pending,
            COUNT(*) FILTER (WHERE result_status = 'won' AND assigned_units > 0) AS won,
            COUNT(*) FILTER (WHERE result_status = 'lost' AND assigned_units > 0) AS lost,
            COUNT(*) FILTER (WHERE result_status = 'push' AND assigned_units > 0) AS push,
            COALESCE(SUM(assigned_units) FILTER (
              WHERE result_status IN ('won','lost','push') AND assigned_units > 0
            ), 0) AS staked_units,
            COALESCE(SUM(profit_units) FILTER (
              WHERE result_status IN ('won','lost','push') AND assigned_units > 0
            ), 0) AS profit_units,
            AVG(market_odds) FILTER (WHERE market_odds > 1) AS avg_odds,
            AVG(value_percent) FILTER (WHERE market_key <> '') AS avg_value
          FROM first_predictions
        '''),
        parameters: periodParameters,
      );
      final row = Map<String, Object?>.from(result.first.toColumnMap());

      int integer(String key) => int.tryParse(row[key]?.toString() ?? '') ?? 0;
      double number(String key) =>
          double.tryParse(row[key]?.toString() ?? '') ?? 0;

      final won = integer('won');
      final lost = integer('lost');
      final decided = won + lost;
      final staked = number('staked_units');
      final profit = number('profit_units');
      final roiPercent = staked == 0 ? null : profit / staked * 100;

      return {
        'sampleSize': integer('total'),
        'withTip': integer('with_tip'),
        'pending': integer('pending'),
        'won': won,
        'lost': lost,
        'push': integer('push'),
        'hitRatePercent': decided == 0 ? null : won / decided * 100,
        'stakedUnits': staked,
        'profitUnits': profit,
        'roiPercent': roiPercent,
        'yieldPercent': roiPercent,
        'avgOdds': row['avg_odds'] == null ? null : number('avg_odds'),
        'avgValuePercent':
            row['avg_value'] == null ? null : number('avg_value'),
      };
    }

    final summary = await summaryFor(dateFrom, dateTo);

    Map<String, Object?>? previousPeriod;
    if (includePreviousPeriod && dateFrom != null && dateTo != null) {
      final spanMs = dateTo.difference(dateFrom).inMilliseconds;
      if (spanMs > 0) {
        final prevTo = dateFrom;
        final prevFrom = dateFrom.subtract(Duration(milliseconds: spanMs));
        previousPeriod = await summaryFor(prevFrom, prevTo);
      }
    }

    List<Map<String, Object?>>? byMarket;
    if (includeMarketBreakdown) {
      final marketConditions = List<String>.from(conditions);
      final marketParameters = Map<String, Object?>.from(parameters);
      if (dateFrom != null) {
        marketConditions.add(
            'COALESCE(h.kickoff, h.prediction_date::timestamptz) >= @date_from');
        marketParameters['date_from'] = dateFrom.toUtc();
      }
      if (dateTo != null) {
        marketConditions.add(
            'COALESCE(h.kickoff, h.prediction_date::timestamptz) < @date_to');
        marketParameters['date_to'] = dateTo.toUtc();
      }
      final where = marketConditions.isEmpty
          ? ''
          : 'WHERE ${marketConditions.join(' AND ')}';

      final rows = await db.execute(
        Sql.named('''
          WITH first_predictions AS (
            SELECT DISTINCT ON (h.prediction_date, h.fixture_id)
              h.market_key, h.market_label, h.market_odds, h.assigned_units,
              h.result_status, h.profit_units, h.kickoff
            FROM football_analysis_history h
            INNER JOIN football_matches m ON m.id = h.fixture_id
            $where
            ORDER BY h.prediction_date, h.fixture_id, h.created_at ASC
          )
          SELECT
            market_key, MAX(market_label) AS market_label,
            COUNT(*) FILTER (WHERE result_status = 'won' AND assigned_units > 0) AS won,
            COUNT(*) FILTER (WHERE result_status = 'lost' AND assigned_units > 0) AS lost,
            COUNT(*) FILTER (WHERE result_status = 'push' AND assigned_units > 0) AS push,
            COALESCE(SUM(assigned_units) FILTER (
              WHERE result_status IN ('won','lost','push') AND assigned_units > 0
            ), 0) AS staked_units,
            COALESCE(SUM(profit_units) FILTER (
              WHERE result_status IN ('won','lost','push') AND assigned_units > 0
            ), 0) AS profit_units,
            AVG(market_odds) FILTER (WHERE market_odds > 1) AS avg_odds
          FROM first_predictions
          WHERE market_key <> ''
          GROUP BY market_key
          ORDER BY market_key
        '''),
        parameters: marketParameters,
      );
      byMarket = rows.map((r) {
        final row = Map<String, Object?>.from(r.toColumnMap());
        int integer(String key) =>
            int.tryParse(row[key]?.toString() ?? '') ?? 0;
        double number(String key) =>
            double.tryParse(row[key]?.toString() ?? '') ?? 0;
        final won = integer('won');
        final lost = integer('lost');
        final decided = won + lost;
        final staked = number('staked_units');
        final profit = number('profit_units');
        final roiPercent = staked == 0 ? null : profit / staked * 100;
        return {
          'marketKey': row['market_key'],
          'marketLabel': row['market_label'],
          'won': won,
          'lost': lost,
          'push': integer('push'),
          'sampleSize': won + lost + integer('push'),
          'hitRatePercent': decided == 0 ? null : won / decided * 100,
          'profitUnits': profit,
          'roiPercent': roiPercent,
          'yieldPercent': roiPercent,
          'avgOdds': row['avg_odds'] == null ? null : number('avg_odds'),
        };
      }).toList(growable: false);
    }

    // Liga-Rangliste: Ein Tipp gehört für die Auswertung zu beiden beteiligten
    // Teams. Dadurch lässt sich transparent sehen, bei welchen Teams PHÖNIX
    // in dieser Liga bisher am besten bzw. schwächsten lag. Grundlage ist
    // derselbe deduplizierte Tippbestand wie Summary, Markt-Tabelle und Chart.
    List<Map<String, Object?>>? byTeam;
    if (includeTeamBreakdown &&
        leagueId != null &&
        leagueId.trim().isNotEmpty) {
      final teamConditions = List<String>.from(conditions);
      final teamParameters = Map<String, Object?>.from(parameters);
      if (dateFrom != null) {
        teamConditions.add(
            'COALESCE(h.kickoff, h.prediction_date::timestamptz) >= @date_from');
        teamParameters['date_from'] = dateFrom.toUtc();
      }
      if (dateTo != null) {
        teamConditions.add(
            'COALESCE(h.kickoff, h.prediction_date::timestamptz) < @date_to');
        teamParameters['date_to'] = dateTo.toUtc();
      }
      final where =
          teamConditions.isEmpty ? '' : 'WHERE ${teamConditions.join(' AND ')}';
      final rows = await db.execute(
        Sql.named('''
          WITH first_predictions AS (
            SELECT DISTINCT ON (h.prediction_date, h.fixture_id)
              h.market_key, h.market_odds, h.assigned_units, h.result_status,
              h.profit_units,
              m.home_team_id, m.home_team_name, m.home_logo,
              m.away_team_id, m.away_team_name, m.away_logo
            FROM football_analysis_history h
            INNER JOIN football_matches m ON m.id = h.fixture_id
            $where
            ORDER BY h.prediction_date, h.fixture_id, h.created_at ASC
          ), team_predictions AS (
            SELECT home_team_id AS team_id, home_team_name AS team_name,
                   home_logo AS team_logo, market_key, market_odds,
                   assigned_units, result_status, profit_units
            FROM first_predictions
            UNION ALL
            SELECT away_team_id, away_team_name, away_logo, market_key,
                   market_odds, assigned_units, result_status, profit_units
            FROM first_predictions
          )
          SELECT
            team_id, MAX(team_name) AS team_name, MAX(team_logo) AS team_logo,
            COUNT(*) FILTER (WHERE market_key <> '') AS tip_count,
            COUNT(*) FILTER (WHERE result_status = 'won' AND assigned_units > 0) AS won,
            COUNT(*) FILTER (WHERE result_status = 'lost' AND assigned_units > 0) AS lost,
            COUNT(*) FILTER (WHERE result_status = 'push' AND assigned_units > 0) AS push,
            COUNT(*) FILTER (WHERE result_status = 'pending' AND market_key <> '') AS pending,
            COALESCE(SUM(assigned_units) FILTER (
              WHERE result_status IN ('won','lost','push') AND assigned_units > 0
            ), 0) AS staked_units,
            COALESCE(SUM(profit_units) FILTER (
              WHERE result_status IN ('won','lost','push') AND assigned_units > 0
            ), 0) AS profit_units,
            AVG(market_odds) FILTER (WHERE market_odds > 1) AS avg_odds
          FROM team_predictions
          WHERE market_key <> ''
          GROUP BY team_id
          ORDER BY profit_units DESC, won DESC, tip_count DESC, team_name ASC
        '''),
        parameters: teamParameters,
      );
      byTeam = rows.map((r) {
        final row = Map<String, Object?>.from(r.toColumnMap());
        int integer(String key) =>
            int.tryParse(row[key]?.toString() ?? '') ?? 0;
        double number(String key) =>
            double.tryParse(row[key]?.toString() ?? '') ?? 0;
        final won = integer('won');
        final lost = integer('lost');
        final staked = number('staked_units');
        final profit = number('profit_units');
        return {
          'teamId': row['team_id'],
          'teamName': row['team_name'],
          'teamLogo': row['team_logo'],
          'tipCount': integer('tip_count'),
          'won': won,
          'lost': lost,
          'push': integer('push'),
          'pending': integer('pending'),
          'hitRatePercent': won + lost == 0 ? null : won / (won + lost) * 100,
          'profitUnits': profit,
          'roiPercent': staked == 0 ? null : profit / staked * 100,
          'avgOdds': row['avg_odds'] == null ? null : number('avg_odds'),
        };
      }).toList(growable: false);
    }

    List<Map<String, Object?>>? timeSeries;
    if (groupByTime != null && {'day', 'week', 'month'}.contains(groupByTime)) {
      final seriesConditions = List<String>.from(conditions);
      final seriesParameters = Map<String, Object?>.from(parameters);
      if (dateFrom != null) {
        seriesConditions.add(
            'COALESCE(h.kickoff, h.prediction_date::timestamptz) >= @date_from');
        seriesParameters['date_from'] = dateFrom.toUtc();
      }
      if (dateTo != null) {
        seriesConditions.add(
            'COALESCE(h.kickoff, h.prediction_date::timestamptz) < @date_to');
        seriesParameters['date_to'] = dateTo.toUtc();
      }
      final where = seriesConditions.isEmpty
          ? ''
          : 'WHERE ${seriesConditions.join(' AND ')}';

      final rows = await db.execute(
        Sql.named('''
          WITH first_predictions AS (
            SELECT DISTINCT ON (h.prediction_date, h.fixture_id)
              h.assigned_units, h.result_status, h.profit_units,
              COALESCE(h.kickoff, h.prediction_date::timestamptz) AS performance_at,
              h.market_key, h.market_odds,
              COALESCE(
                NULLIF(h.payload #>> '{selection,value,valuePercent}', ''), '0'
              )::double precision AS value_percent
            FROM football_analysis_history h
            INNER JOIN football_matches m ON m.id = h.fixture_id
            $where
            ORDER BY h.prediction_date, h.fixture_id, h.created_at ASC
          )
          SELECT
            date_trunc(@bucket, performance_at) AS period,
            COUNT(*) FILTER (WHERE result_status = 'won' AND assigned_units > 0) AS won,
            COUNT(*) FILTER (WHERE result_status = 'lost' AND assigned_units > 0) AS lost,
            COUNT(*) FILTER (WHERE result_status = 'push' AND assigned_units > 0) AS push,
            COUNT(*) FILTER (WHERE market_key <> '') AS tip_count,
            COALESCE(SUM(assigned_units) FILTER (
              WHERE result_status IN ('won','lost','push') AND assigned_units > 0
            ), 0) AS staked_units,
            COALESCE(SUM(profit_units) FILTER (
              WHERE result_status IN ('won','lost','push') AND assigned_units > 0
            ), 0) AS profit_units,
            AVG(market_odds) FILTER (WHERE market_odds > 1) AS avg_odds,
            AVG(value_percent) FILTER (WHERE market_key <> '') AS avg_value
          FROM first_predictions
          WHERE performance_at IS NOT NULL
          GROUP BY period
          ORDER BY period
        '''),
        parameters: {...seriesParameters, 'bucket': groupByTime},
      );
      timeSeries = rows.map((r) {
        final row = Map<String, Object?>.from(r.toColumnMap());
        int integer(String key) =>
            int.tryParse(row[key]?.toString() ?? '') ?? 0;
        double number(String key) =>
            double.tryParse(row[key]?.toString() ?? '') ?? 0;
        final won = integer('won');
        final lost = integer('lost');
        final decided = won + lost;
        final staked = number('staked_units');
        final profit = number('profit_units');
        final roiPercent = staked == 0 ? null : profit / staked * 100;
        final period = row['period'];
        return {
          'period':
              period is DateTime ? period.toUtc().toIso8601String() : period,
          'won': won,
          'lost': lost,
          'push': integer('push'),
          'tipCount': integer('tip_count'),
          'hitRatePercent': decided == 0 ? null : won / decided * 100,
          'roiPercent': roiPercent,
          'yieldPercent': roiPercent,
          'profitUnits': profit,
          'avgOdds': row['avg_odds'] == null ? null : number('avg_odds'),
          'avgValuePercent':
              row['avg_value'] == null ? null : number('avg_value'),
        };
      }).toList(growable: false);
    }

    return {
      'summary': summary,
      if (previousPeriod != null) 'previousPeriod': previousPeriod,
      if (byMarket != null) 'byMarket': byMarket,
      if (byTeam != null) 'byTeam': byTeam,
      if (timeSeries != null) 'timeSeries': timeSeries,
    };
  }

  /// Section "DATEN – extrem wichtig": beantwortet "was hat PHÖNIX
  /// tatsächlich über diese Liga/dieses Team gespeichert" - NICHTS wird hier
  /// hardcodiert, jede Prozentzahl kommt aus echten `availability`-Flags,
  /// die `FootballService.coverageForFixture()` beim Scan pro Spiel setzt
  /// (siehe dort für die genaue Bedeutung jedes Flags). `xg`/`lineups` sind
  /// bei API-Football strukturell nie verfügbar (dort im Code fest auf
  /// `false` gesetzt) - das wird hier ehrlich als 0 % ausgegeben, nicht
  /// versteckt oder umgangen.
  Future<Map<String, Object?>> footballDataCoverage({
    String? leagueId,
    String? teamId,
  }) async {
    final db = await connection();
    final conditions = <String>[];
    final parameters = <String, Object?>{};
    if (leagueId != null && leagueId.trim().isNotEmpty) {
      conditions.add('p.league_id = @league_id');
      parameters['league_id'] = leagueId.trim();
    }
    if (teamId != null && teamId.trim().isNotEmpty) {
      conditions
          .add('(m.home_team_id = @team_id OR m.away_team_id = @team_id)');
      parameters['team_id'] = teamId.trim();
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final result = await db.execute(
      Sql.named('''
        WITH latest AS (
          SELECT DISTINCT ON (p.fixture_id)
            p.fixture_id, p.league_id, p.data_quality, p.availability,
            p.created_at
          FROM football_phase_two_results p
          INNER JOIN football_matches m ON m.id = p.fixture_id
          $where
          ORDER BY p.fixture_id, p.created_at DESC
        )
        SELECT
          COUNT(*) AS total,
          COUNT(*) FILTER (WHERE (availability->>'standings')::boolean) AS standings,
          COUNT(*) FILTER (
            WHERE (availability->>'homeRecent')::boolean
              AND (availability->>'awayRecent')::boolean
          ) AS form,
          COUNT(*) FILTER (WHERE (availability->>'h2h')::boolean) AS h2h,
          COUNT(*) FILTER (WHERE (availability->>'odds')::boolean) AS odds,
          COUNT(*) FILTER (WHERE (availability->>'injuries')::boolean) AS injuries,
          COUNT(*) FILTER (
            WHERE (availability->>'homeTeamStatistics')::boolean
              AND (availability->>'awayTeamStatistics')::boolean
          ) AS statistics,
          AVG(data_quality) AS avg_data_quality,
          MAX(created_at) AS last_updated
        FROM latest
      '''),
      parameters: parameters,
    );
    final row = Map<String, Object?>.from(result.first.toColumnMap());
    final total = int.tryParse(row['total']?.toString() ?? '') ?? 0;

    int countOf(String key) => int.tryParse(row[key]?.toString() ?? '') ?? 0;

    double coverage(String key) {
      if (total == 0) return 0;
      return countOf(key) / total * 100;
    }

    String status(double pct) {
      if (total == 0) return 'unknown';
      if (pct >= 90) return 'available';
      if (pct > 0) return 'partial';
      return 'missing';
    }

    // Section 18: jede Kategorie liefert zusätzlich zur Prozentzahl die
    // rohen Zähler (mit/ohne), damit ein Klick auf die Kategorie eine echte
    // Drilldown-Ansicht mit "Spiele insgesamt / mit X / ohne X" zeigen kann,
    // statt nur den Prozentwert zu wiederholen.
    Map<String, Object?> categoryOf(String key, double pct) {
      final withCount = key == 'results' ? total : countOf(key);
      return {
        'coveragePercent': pct,
        'status': status(pct),
        'withCount': withCount,
        'withoutCount': total - withCount,
      };
    }

    final categories = {
      'results': categoryOf('results', total == 0 ? 0.0 : 100.0),
      'standings': categoryOf('standings', coverage('standings')),
      'form': categoryOf('form', coverage('form')),
      'h2h': categoryOf('h2h', coverage('h2h')),
      'odds': categoryOf('odds', coverage('odds')),
      'injuries': categoryOf('injuries', coverage('injuries')),
      'statistics': categoryOf('statistics', coverage('statistics')),
      // Strukturell nie verfügbar (siehe Doc-Kommentar) - ehrlich als 0
      // ausgegeben statt weggelassen.
      'lineups': {
        'coveragePercent': 0.0,
        'status': 'missing',
        'withCount': 0,
        'withoutCount': total
      },
      'xg': {
        'coveragePercent': 0.0,
        'status': 'missing',
        'withCount': 0,
        'withoutCount': total
      },
    };

    final avgDq = row['avg_data_quality'];
    final lastUpdated = row['last_updated'];
    return {
      'sampleSize': total,
      'overallCoveragePercent':
          avgDq == null ? null : double.tryParse(avgDq.toString()),
      'lastUpdated': lastUpdated is DateTime
          ? lastUpdated.toUtc().toIso8601String()
          : null,
      'categories': categories,
    };
  }

  /// "Liga-/Tor-Kontext"-Feature für [GlobalGoalsV1Engine]: durchschnittliche
  /// Heim-/Auswärtstore je Spiel dieser Liga über die letzten 400 Tage.
  /// `football_matches` hat keine `season`-Spalte (bekannte Lücke) - ein
  /// gleitendes Zeitfenster ist die ehrlichste verfügbare Näherung.
  Future<Map<String, Object?>> footballLeagueGoalContext({
    required String leagueId,
  }) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        SELECT
          COUNT(*) AS sample_size,
          AVG(home_goals) AS avg_home_goals,
          AVG(away_goals) AS avg_away_goals
        FROM football_matches
        WHERE league_id = @league_id
          AND home_goals IS NOT NULL
          AND away_goals IS NOT NULL
          AND kickoff_utc >= NOW() - INTERVAL '400 days'
      '''),
      parameters: {'league_id': leagueId},
    );
    final row = rows.first.toColumnMap();
    final sampleSize = int.tryParse(row['sample_size']?.toString() ?? '') ?? 0;
    return {
      'sampleSize': sampleSize,
      'avgHomeGoalsPerGame': sampleSize == 0
          ? null
          : double.tryParse(row['avg_home_goals'].toString()),
      'avgAwayGoalsPerGame': sampleSize == 0
          ? null
          : double.tryParse(row['avg_away_goals'].toString()),
    };
  }

  /// Für den GLOBAL_GOALS_V1-Vergleich (Model Lab, rein lesend): liefert den
  /// zuletzt gespeicherten Availability-Snapshot eines Spiels plus die
  /// Team-IDs aus `football_matches` (Availability selbst enthält keine
  /// Team-IDs, nur die abgeleiteten Kennzahlen).
  Future<Map<String, Object?>?> footballLatestPhaseTwoResultForFixture(
    String fixtureId,
  ) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        SELECT p.availability, p.league_id, m.home_team_id, m.away_team_id,
               m.home_team_name, m.away_team_name
        FROM football_phase_two_results p
        INNER JOIN football_matches m ON m.id = p.fixture_id
        WHERE p.fixture_id = @fixture_id
        ORDER BY p.created_at DESC
        LIMIT 1
      '''),
      parameters: {'fixture_id': fixtureId},
    );
    if (rows.isEmpty) return null;
    return Map<String, Object?>.from(rows.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> footballTipsForSettlement({
    DateTime? date,
    bool reconcile = false,
  }) async {
    final db = await connection();
    final statusFilter = reconcile ? '' : "AND result_status = 'pending'";
    final dateFilter = date == null
        ? ''
        : 'AND prediction_date = CAST(@prediction_date AS DATE)';
    final result = await db.execute(
      Sql.named('''
        SELECT phase_two_scan_run_id, fixture_id, market_key, market_label,
               market_odds, assigned_units, payload
        FROM football_analysis_history
        WHERE TRUE
          AND market_key <> ''
          $statusFilter
          $dateFilter
        ORDER BY kickoff
      '''),
      parameters: {
        if (date != null)
          'prediction_date': date.toUtc().toIso8601String().substring(0, 10),
      },
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Immutable PHÖNIX recommendations for the in-app history. The app must
  /// read these server snapshots instead of its device cache so settled tips
  /// remain visible after reinstalling or changing phones.
  Future<List<Map<String, Object?>>> footballHistory({
    required DateTime since,
    int limit = 500,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        WITH first_predictions AS (
          -- Ein täglicher Neu-Scan darf nie mehrere sichtbare Wetten für
          -- dasselbe Spiel erzeugen. Für Historie, Quote und ROI zählt stets
          -- die erste, also tatsächlich vor Spielbeginn veröffentlichte
          -- PHÖNIX-Prognose. Spätere Scans bleiben intern erhalten.
          SELECT DISTINCT ON (prediction_date, fixture_id)
            phase_two_scan_run_id, fixture_id, prediction_date, kickoff,
            market_key, market_label, model_probability, fair_odds,
            market_odds, assigned_units, data_quality, confidence,
            result_status, home_score, away_score, profit_units, settled_at,
            created_at, payload
          FROM football_analysis_history
          WHERE prediction_date >= CAST(@since AS DATE)
          ORDER BY prediction_date, fixture_id, created_at ASC
        )
        SELECT phase_two_scan_run_id, fixture_id, prediction_date, kickoff,
               market_key, market_label, model_probability, fair_odds,
               market_odds, assigned_units, data_quality, confidence, result_status,
               home_score, away_score, profit_units, settled_at, created_at,
                 COALESCE((payload #>> '{selection,value,isValueTip}')::BOOLEAN, FALSE)
                   AS is_value_tip,
                 COALESCE(
                   NULLIF(payload #>> '{selection,value,valuePercent}', '')::DOUBLE PRECISION,
                   0
                 ) AS value_percent,
               COALESCE(payload->>'homeTeam', payload #>> '{selection,homeTeam}', '')
                 AS home_team,
               COALESCE(payload->>'awayTeam', payload #>> '{selection,awayTeam}', '')
                 AS away_team,
               COALESCE(payload->>'league', payload #>> '{selection,league}', '')
                 AS league
        FROM first_predictions
        ORDER BY kickoff DESC NULLS LAST, created_at DESC
        LIMIT @limit
      '''),
      parameters: {
        'since': since.toUtc().toIso8601String().substring(0, 10),
        'limit': limit.clamp(1, 500),
      },
    );
    return result.map((row) {
      final value = Map<String, Object?>.from(row.toColumnMap());
      for (final key in const [
        'prediction_date',
        'kickoff',
        'settled_at',
        'created_at',
      ]) {
        final timestamp = value[key];
        if (timestamp is DateTime) {
          value[key] = timestamp.toUtc().toIso8601String();
        }
      }
      return value;
    }).toList(growable: false);
  }

  Future<void> settleFootballTip({
    required int phaseTwoScanRunId,
    required String fixtureId,
    required int homeScore,
    required int awayScore,
    required String resultStatus,
    required double profitUnits,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE football_analysis_history SET
          home_score = @home_score, away_score = @away_score,
          result_status = @result_status, profit_units = @profit_units,
          settled_at = NOW()
        WHERE phase_two_scan_run_id = @scan_run_id AND fixture_id = @fixture_id
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'fixture_id': fixtureId,
        'home_score': homeScore,
        'away_score': awayScore,
        'result_status': resultStatus,
        'profit_units': profitUnits,
      },
    );
  }

  Future<Map<String, Object?>> footballPerformanceSummary() async {
    final db = await connection();
    Map<String, Object?> metrics(Map<String, Object?> row) {
      int integer(String key) => int.tryParse(row[key]?.toString() ?? '') ?? 0;
      double number(String key) =>
          double.tryParse(row[key]?.toString() ?? '') ?? 0;
      final won = integer('won');
      final lost = integer('lost');
      final decided = won + lost;
      final staked = number('staked_units');
      final profit = number('profit_units');
      return {
        'totalAnalyses': integer('total'),
        'pricedAnalyses': integer('priced'),
        'settledAnalyses': integer('settled'),
        'won': won,
        'lost': lost,
        'push': integer('push'),
        'hitRatePercent': decided == 0 ? 0 : won / decided * 100,
        'stakedUnits': staked,
        'profitUnits': profit,
        'roiPercent': staked == 0 ? 0 : profit / staked * 100,
      };
    }

    Future<Map<String, Object?>> period(String condition) async {
      final result = await db.execute('''
        WITH first_predictions AS (
          SELECT DISTINCT ON (prediction_date, fixture_id) *
          FROM football_analysis_history
          ORDER BY prediction_date, fixture_id, created_at ASC
        )
        SELECT COUNT(*) AS total,
               COUNT(*) FILTER (WHERE market_odds > 1) AS priced,
               COUNT(*) FILTER (WHERE result_status IN ('won','lost','push')
                 AND assigned_units > 0) AS settled,
               COUNT(*) FILTER (WHERE result_status = 'won'
                 AND assigned_units > 0) AS won,
               COUNT(*) FILTER (WHERE result_status = 'lost'
                 AND assigned_units > 0) AS lost,
               COUNT(*) FILTER (WHERE result_status = 'push'
                 AND assigned_units > 0) AS push,
               COALESCE(SUM(assigned_units) FILTER (WHERE result_status IN
                 ('won','lost','push') AND assigned_units > 0), 0) AS staked_units,
               COALESCE(SUM(profit_units) FILTER (WHERE result_status IN
                 ('won','lost','push') AND assigned_units > 0), 0) AS profit_units
        FROM first_predictions
        WHERE $condition
      ''');
      return metrics(Map<String, Object?>.from(result.first.toColumnMap()));
    }

    Future<List<Map<String, Object?>>> grouped(String expression) async {
      final result = await db.execute('''
        WITH first_predictions AS (
          SELECT DISTINCT ON (prediction_date, fixture_id) *
          FROM football_analysis_history
          ORDER BY prediction_date, fixture_id, created_at ASC
        )
        SELECT $expression AS name, COUNT(*) AS total,
               COUNT(*) FILTER (WHERE market_odds > 1) AS priced,
               COUNT(*) FILTER (WHERE result_status IN ('won','lost','push')
                 AND assigned_units > 0) AS settled,
               COUNT(*) FILTER (WHERE result_status = 'won'
                 AND assigned_units > 0) AS won,
               COUNT(*) FILTER (WHERE result_status = 'lost'
                 AND assigned_units > 0) AS lost,
               COUNT(*) FILTER (WHERE result_status = 'push'
                 AND assigned_units > 0) AS push,
               COALESCE(SUM(assigned_units) FILTER (WHERE result_status IN
                 ('won','lost','push') AND assigned_units > 0), 0) AS staked_units,
               COALESCE(SUM(profit_units) FILTER (WHERE result_status IN
                 ('won','lost','push') AND assigned_units > 0), 0) AS profit_units
        FROM first_predictions
        GROUP BY 1
        ORDER BY settled DESC, name
      ''');
      return result.map((row) {
        final values = Map<String, Object?>.from(row.toColumnMap());
        return {'name': values['name']?.toString() ?? '', ...metrics(values)};
      }).toList();
    }

    final all = await period('TRUE');
    return {
      ...all,
      'periods': {
        'days7':
            await period("prediction_date >= CURRENT_DATE - INTERVAL '6 days'"),
        'days30': await period(
            "prediction_date >= CURRENT_DATE - INTERVAL '29 days'"),
        'all': all,
      },
      'byMarket':
          await grouped("COALESCE(NULLIF(market_label, ''), 'Unbekannt')"),
      'byLeague': await grouped(
        "COALESCE(NULLIF(payload->>'league', ''), 'Unbekannt')",
      ),
      'stakingModel': 'flat_1_unit_when_market_odds_available',
    };
  }

  Future<void> saveBaseballAnalysisHistory({
    required Map<String, dynamic> game,
    required Map<String, dynamic> analysis,
  }) async {
    final db = await connection();
    final id = game['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final teams = _jsonMap(game['teams']);
    final home = _jsonMap(teams['home']);
    final away = _jsonMap(teams['away']);
    final kickoff = DateTime.tryParse(game['date']?.toString() ?? '');
    final pickSide = analysis['pickSide']?.toString() ?? 'home';
    final rawMarketOdds = analysis['marketOdds'];
    final marketOdds = rawMarketOdds is num
        ? rawMarketOdds.toDouble()
        : double.tryParse(rawMarketOdds?.toString() ?? '');
    final isValue = analysis['isValueBet'] == true;
    final assignedUnits =
        isValue && marketOdds != null && marketOdds > 1 ? 1.0 : 0.0;
    final date =
        (kickoff ?? DateTime.now()).toUtc().toIso8601String().substring(0, 10);
    await db.execute(
      Sql.named('''
        INSERT INTO baseball_analysis_history (
          game_id, prediction_date, scheduled_at, home_team, away_team,
          pick_side, market_label, model_probability, fair_odds, market_odds,
          assigned_units, payload
        ) VALUES (
          @game_id, CAST(@prediction_date AS DATE),
          CAST(NULLIF(@scheduled_at, '') AS TIMESTAMPTZ), @home_team,
          @away_team, @pick_side, @market_label, @model_probability,
          @fair_odds, @market_odds, @assigned_units, CAST(@payload AS JSONB)
        ) ON CONFLICT (game_id) DO NOTHING
      '''),
      parameters: {
        'game_id': id,
        'prediction_date': date,
        'scheduled_at': kickoff?.toUtc().toIso8601String() ?? '',
        'home_team': home['name']?.toString() ?? 'Home',
        'away_team': away['name']?.toString() ?? 'Away',
        'pick_side': pickSide,
        'market_label': analysis['bestPick']?.toString() ?? '',
        'model_probability': analysis['bestPickProbability'],
        'fair_odds': analysis['fairOdds'],
        'market_odds': marketOdds,
        'assigned_units': assignedUnits,
        'payload': jsonEncode({'game': game, 'analysis': analysis}),
      },
    );
  }

  Future<List<Map<String, Object?>>> pendingBaseballAnalyses() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT game_id, home_team, away_team, pick_side, market_odds,
             assigned_units
      FROM baseball_analysis_history
      WHERE result_status = 'pending'
        AND prediction_date >= CURRENT_DATE - INTERVAL '14 days'
      ORDER BY scheduled_at
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList(growable: false);
  }

  Future<void> settleBaseballAnalysis({
    required String gameId,
    required int homeScore,
    required int awayScore,
    required String resultStatus,
    required double profitUnits,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE baseball_analysis_history SET
          home_score = @home_score, away_score = @away_score,
          result_status = @result_status, profit_units = @profit_units,
          settled_at = NOW()
        WHERE game_id = @game_id
      '''),
      parameters: {
        'game_id': gameId,
        'home_score': homeScore,
        'away_score': awayScore,
        'result_status': resultStatus,
        'profit_units': profitUnits,
      },
    );
  }

  Future<Map<String, Object?>> baseballPerformanceSummary() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT COUNT(*) AS total,
             COUNT(*) FILTER (WHERE result_status IN ('won', 'lost')) AS settled,
             COUNT(*) FILTER (WHERE result_status = 'won') AS won,
             COUNT(*) FILTER (WHERE result_status = 'lost') AS lost,
             COALESCE(SUM(assigned_units) FILTER (WHERE result_status IN
               ('won', 'lost') AND assigned_units > 0), 0) AS staked_units,
             COALESCE(SUM(profit_units) FILTER (WHERE result_status IN
               ('won', 'lost') AND assigned_units > 0), 0) AS profit_units
      FROM baseball_analysis_history
    ''');
    final row = Map<String, Object?>.from(result.first.toColumnMap());
    int integer(String key) => int.tryParse(row[key]?.toString() ?? '') ?? 0;
    double number(String key) =>
        double.tryParse(row[key]?.toString() ?? '') ?? 0;
    final won = integer('won');
    final lost = integer('lost');
    final staked = number('staked_units');
    final profit = number('profit_units');
    return {
      'totalAnalyses': integer('total'),
      'settledAnalyses': integer('settled'),
      'won': won,
      'lost': lost,
      'hitRatePercent': won + lost == 0 ? 0 : won / (won + lost) * 100,
      'stakedUnits': staked,
      'profitUnits': profit,
      'roiPercent': staked == 0 ? 0 : profit / staked * 100,
      'stakingModel': 'flat_1_unit_only_when_verified_market_odds_available',
    };
  }

  /// Startet atomar einen neuen Tages-Scan oder liefert den bereits aktiven
  /// Scan zurück. Es gibt bewusst kein Limit pro Tag – nur keine parallelen,
  /// ressourcenfressenden Pipeline-Läufe.
  Future<Map<String, Object?>> startFootballDailyPipelineJob({
    required DateTime date,
    required int limit,
    required int minimumDataQuality,
    required int simulations,
  }) async {
    final db = await connection();

    // Ein abgestürzter Railway-Prozess kann seinen Status nicht selbst
    // zurücksetzen. Der Heartbeat neuer Läufe schützt gültige lange Scans;
    // ohne Herzschlag wird ein Job nach 15 Minuten freigegeben.
    await db.execute('''
      UPDATE football_daily_pipeline_jobs
      SET status = 'failed',
          current_step = 'timed_out',
          error = 'Scan wegen fehlender Aktivität automatisch beendet.',
          completed_at = NOW(),
          last_activity_at = NOW()
      WHERE status = 'running'
        AND last_activity_at < NOW() - INTERVAL '15 minutes'
    ''');

    final result = await db.execute(
      Sql.named('''
        INSERT INTO football_daily_pipeline_jobs (
          scan_date, requested_limit, minimum_data_quality, simulations
        ) VALUES (@date, @limit, @quality, @simulations)
        ON CONFLICT DO NOTHING
        RETURNING id
      '''),
      parameters: {
        'date': _dateOnly(date),
        'limit': limit,
        'quality': minimumDataQuality,
        'simulations': simulations < 100000
            ? 100000
            : simulations.clamp(100000, 100000).toInt(),
      },
    );
    if (result.isNotEmpty) {
      return {'started': true, 'jobId': result.first[0] as int};
    }

    final running = await db.execute('''
      SELECT id FROM football_daily_pipeline_jobs
      WHERE status = 'running'
      ORDER BY created_at DESC
      LIMIT 1
    ''');
    if (running.isEmpty) {
      throw StateError('Tagesscan konnte nicht exklusiv gestartet werden.');
    }
    return {'started': false, 'jobId': running.first[0] as int};
  }

  Future<void> updateFootballDailyPipelineJob({
    required int jobId,
    required String status,
    required String currentStep,
    int? phaseOneScanRunId,
    int? phaseTwoScanRunId,
    int? processed,
    int? published,
    Object? error,
    bool completed = false,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE football_daily_pipeline_jobs SET
          status = @status,
          current_step = @current_step,
          phase_one_scan_run_id =
            COALESCE(@phase_one_scan_run_id, phase_one_scan_run_id),
          phase_two_scan_run_id =
            COALESCE(@phase_two_scan_run_id, phase_two_scan_run_id),
          processed = COALESCE(@processed, processed),
          published = COALESCE(@published, published),
          error = @error,
          completed_at = CASE WHEN @completed THEN NOW() ELSE completed_at END,
          last_activity_at = NOW()
        WHERE id = @job_id
      '''),
      parameters: {
        'job_id': jobId,
        'status': status,
        'current_step': currentStep,
        'phase_one_scan_run_id': phaseOneScanRunId,
        'phase_two_scan_run_id': phaseTwoScanRunId,
        'processed': processed,
        'published': published,
        'error': error?.toString(),
        'completed': completed,
      },
    );
  }

  Future<void> touchFootballDailyPipelineJob(int jobId) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE football_daily_pipeline_jobs
        SET last_activity_at = NOW()
        WHERE id = @job_id AND status = 'running'
      '''),
      parameters: {'job_id': jobId},
    );
  }

  /// Ein Railway-Deploy beendet alle In-Process-Pipelines des alten
  /// Containers. Diese Jobs dürfen danach keinen neuen Scan blockieren.
  Future<int> failPipelineJobsFromEarlierServer() async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE football_daily_pipeline_jobs
        SET status = 'failed',
            current_step = 'interrupted_by_restart',
            error = 'Scan durch Server-Neustart unterbrochen.',
            completed_at = NOW(),
            last_activity_at = NOW()
        WHERE status = 'running'
        RETURNING id
      '''),
    );
    return result.length;
  }

  Future<Map<String, Object?>?> footballDailyPipelineJob(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          id,
          scan_date::text AS scan_date,
          status,
          current_step,
          phase_one_scan_run_id,
          phase_two_scan_run_id,
          requested_limit,
          minimum_data_quality,
          simulations,
          processed,
          published,
          error,
          created_at::text AS created_at,
          completed_at::text AS completed_at
        FROM football_daily_pipeline_jobs
        WHERE id = @id
        LIMIT 1
      '''),
      parameters: {'id': id},
    );

    if (result.isEmpty) return null;

    final row = Map<String, Object?>.from(result.first.toColumnMap());
    return <String, Object?>{
      'id': row['id'],
      'scan_date': row['scan_date']?.toString(),
      'status': row['status']?.toString() ?? 'unknown',
      'current_step': row['current_step']?.toString() ?? '',
      'phase_one_scan_run_id': row['phase_one_scan_run_id'],
      'phase_two_scan_run_id': row['phase_two_scan_run_id'],
      'requested_limit': row['requested_limit'],
      'minimum_data_quality': row['minimum_data_quality'],
      'simulations': row['simulations'],
      'processed': row['processed'] ?? 0,
      'published': row['published'] ?? 0,
      'error': row['error']?.toString(),
      'created_at': row['created_at']?.toString(),
      'completed_at': row['completed_at']?.toString(),
    };
  }

  // ===========================================================================
  // PHÖNIX MODEL LAB (Self-Learning Engine V0)
  // ===========================================================================

  static const List<String> modelLabFinishedMatchStatuses = [
    'FT',
    'AET',
    'PEN',
    'AWD',
    'WO',
  ];

  /// Section 19/21: Leakage-sicherer Rohdatensatz für das Learning-System -
  /// ein Datensatz je Fixture (der letzte VOR dem Kickoff gespeicherte
  /// Pre-Match-Snapshot), nur für Fokus- und Beobachtungs-Ligen, nur für
  /// abgeschlossene
  /// Matches mit bekanntem Endstand. Das Outcome (home_goals/away_goals)
  /// stammt ausschließlich aus dem NACH Matchende befüllten football_matches
  /// - niemals aus denselben Feldern, die als Pre-Match-Feature dienen.
  /// `football_analysis_history` wird bewusst NICHT als Quelle verwendet:
  /// dort steht nur der EINE ausgewählte Top-Tipp-Markt je Fixture, während
  /// football_engine_inputs + football_matches für JEDES Fixture alle drei
  /// Model-Lab-Märkte (1X2/O-U 2.5/BTTS) direkt aus dem echten Endstand
  /// ableiten lassen - deutlich vollständiger und ohne die Grading-Textlogik
  /// der Tipp-Abrechnung nachbauen zu müssen.
  Future<List<Map<String, Object?>>> modelLabRawDataset({
    String? leagueId,
    required int minDataQuality,
  }) async {
    final db = await connection();
    final leagueFilter =
        leagueId == null ? '' : 'AND ei.league_id = @league_id';
    final result = await db.execute(
      Sql.named('''
        SELECT DISTINCT ON (ei.fixture_id)
          ei.phase_two_scan_run_id,
          ei.fixture_id,
          ei.league_id,
          ei.data_quality,
          ei.normalized_input,
          ei.created_at AS snapshot_created_at,
          m.kickoff_utc,
          m.status,
          m.home_goals,
          m.away_goals,
          rc.earliest_red_card_minute
        FROM football_engine_inputs ei
        JOIN football_matches m ON m.id = ei.fixture_id
        JOIN football_leagues fl ON fl.league_id = ei.league_id
        LEFT JOIN LATERAL (
          SELECT MIN(NULLIF(payload ->> 'minute', '')::int)
            AS earliest_red_card_minute
          FROM football_live_events
          WHERE fixture_id = ei.fixture_id AND event_type = 'redCard'
        ) rc ON TRUE
        WHERE fl.collection_tier IN ('focus', 'watchlist')
          AND m.status = ANY(@finished_statuses)
          AND m.home_goals IS NOT NULL
          AND m.away_goals IS NOT NULL
          AND m.kickoff_utc IS NOT NULL
          AND ei.created_at < m.kickoff_utc
          AND ei.data_quality >= @min_data_quality
          $leagueFilter
        ORDER BY ei.fixture_id, ei.created_at DESC
      '''),
      parameters: {
        'finished_statuses': modelLabFinishedMatchStatuses,
        'min_data_quality': minDataQuality,
        if (leagueId != null) 'league_id': leagueId,
      },
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Section 23/89: Rohdaten für den Eligibility-Audit (Dry Run). Anders als
  /// [modelLabRawDataset] filtert diese Abfrage NICHT vor, sondern liefert je
  /// Fixture (letzter Snapshot vor dem aktuellen Zeitpunkt) alle Felder, die
  /// der Aufrufer braucht, um jedes Fixture einem exakten Ausschlussgrund
  /// zuzuordnen (Section 23: Data Quality / Snapshot fehlt / Timestamp
  /// ungültig / Outcome fehlt / League nicht Whitelist).
  Future<List<Map<String, Object?>>> modelLabEligibilityAuditRows() async {
    final db = await connection();
    // Bugfix: ein Fixture kann mehrere Engine-Input-Snapshots haben, z.B.
    // wenn es nach dem Anpfiff (Debugging, manueller Re-Scan) erneut
    // durchlaufen wurde. Vorher wählte DISTINCT ON hier IMMER den zeitlich
    // letzten Snapshot - auch wenn der nach dem Kickoff lag - und markierte
    // das Fixture dadurch fälschlich als "timestamp_invalid", obwohl ein
    // gültiger Pre-Match-Snapshot längst vorhanden war. Live in Produktion
    // bestätigt: 23 Fixtures waren betroffen. [modelLabRawDataset] (das
    // tatsächliche Training) hatte dieses Problem nicht, weil es
    // `created_at < kickoff_utc` schon in der WHERE-Klausel filtert - hier
    // wird stattdessen der Snapshot mit Sortierpriorität ausgewählt: ein
    // gültiger Pre-Match-Snapshot geht immer vor, erst wenn keiner existiert
    // wird (korrekt) der überhaupt letzte Snapshot als Grundlage für die
    // "timestamp_invalid"-Einordnung genutzt.
    final result = await db.execute('''
      SELECT DISTINCT ON (ei.fixture_id)
        ei.fixture_id,
        ei.league_id,
        ei.data_quality,
        ei.created_at AS snapshot_created_at,
        m.kickoff_utc,
        m.status,
        m.home_goals,
        m.away_goals,
        fl.manual_status,
        fl.collection_tier
      FROM football_engine_inputs ei
      LEFT JOIN football_matches m ON m.id = ei.fixture_id
      LEFT JOIN football_leagues fl ON fl.league_id = ei.league_id
      ORDER BY ei.fixture_id,
        CASE
          WHEN m.kickoff_utc IS NOT NULL AND ei.created_at < m.kickoff_utc
            THEN 0
          ELSE 1
        END,
        ei.created_at DESC
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Section 33/34: Pre-Match-Snapshots für Fixtures, deren Kickoff noch in
  /// der Zukunft liegt - Grundlage für Shadow Predictions. Nutzt exakt
  /// denselben bereits gespeicherten Snapshot wie der Champion (keine
  /// zusätzlichen API-Football-/KI-Aufrufe).
  Future<List<Map<String, Object?>>> modelLabUpcomingSnapshots({
    required int minDataQuality,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT DISTINCT ON (ei.fixture_id)
          ei.phase_two_scan_run_id,
          ei.fixture_id,
          ei.league_id,
          ei.data_quality,
          ei.normalized_input,
          ei.created_at AS snapshot_created_at,
          m.kickoff_utc
        FROM football_engine_inputs ei
        JOIN football_matches m ON m.id = ei.fixture_id
        JOIN football_leagues fl ON fl.league_id = ei.league_id
        WHERE fl.collection_tier IN ('focus', 'watchlist')
          AND m.kickoff_utc IS NOT NULL
          AND m.kickoff_utc > NOW()
          AND ei.created_at < m.kickoff_utc
          AND ei.data_quality >= @min_data_quality
        ORDER BY ei.fixture_id, ei.created_at DESC
      '''),
      parameters: {'min_data_quality': minDataQuality},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Alle für das Model Lab zugelassenen Fokus- und Beobachtungs-Ligen.
  /// Der Datenpool bleibt bewusst ein reiner Datensammler, damit ein späterer
  /// Modelllauf nicht tausende noch unzureichend geprüfte Ligen trainiert.
  Future<List<Map<String, Object?>>> modelLabWhitelistedLeagues() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT league_id, league_name, country, gender, competition_level,
             total_samples, successful_full_analyses, collection_tier
      FROM football_leagues
      WHERE collection_tier IN ('focus', 'watchlist')
      ORDER BY league_name
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<int> insertModelVersion({
    required String readableVersion,
    int? parentModelId,
    required int generation,
    String? leagueId,
    required String market,
    required String modelType,
    required Map<String, Object?> featureConfig,
    required Map<String, Object?> weights,
    DateTime? trainingStart,
    DateTime? trainingEnd,
    required int trainingCount,
    required int validationCount,
    required int holdoutCount,
    required int shadowCount,
    required String status,
    required String configHash,
    required String codeSchemaVersion,
    Map<String, Object?> evaluationSummary = const {},
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO phoenix_model_versions (
          readable_version, parent_model_id, generation, league_id, market,
          model_type, feature_config, weights, training_start, training_end,
          training_count, validation_count, holdout_count, shadow_count,
          status, config_hash, code_schema_version, evaluation_summary
        ) VALUES (
          @readable_version, @parent_model_id, @generation, @league_id, @market,
          @model_type, CAST(@feature_config AS JSONB), CAST(@weights AS JSONB),
          @training_start, @training_end,
          @training_count, @validation_count, @holdout_count, @shadow_count,
          @status, @config_hash, @code_schema_version,
          CAST(@evaluation_summary AS JSONB)
        )
        ON CONFLICT (market, COALESCE(league_id, '__GLOBAL__'), config_hash)
        DO UPDATE SET readable_version = phoenix_model_versions.readable_version
        RETURNING id
      '''),
      parameters: {
        'readable_version': readableVersion,
        'parent_model_id': parentModelId,
        'generation': generation,
        'league_id': leagueId,
        'market': market,
        'model_type': modelType,
        'feature_config': jsonEncode(featureConfig),
        'weights': jsonEncode(weights),
        'training_start': trainingStart?.toUtc().toIso8601String(),
        'training_end': trainingEnd?.toUtc().toIso8601String(),
        'training_count': trainingCount,
        'validation_count': validationCount,
        'holdout_count': holdoutCount,
        'shadow_count': shadowCount,
        'status': status,
        'config_hash': configHash,
        'code_schema_version': codeSchemaVersion,
        'evaluation_summary': jsonEncode(evaluationSummary),
      },
    );
    return result.first[0] as int;
  }

  Future<Map<String, Object?>?> modelVersion(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT * FROM phoenix_model_versions WHERE id = @id'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> globalBaselineModel(String market) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_model_versions
        WHERE market = @market AND league_id IS NULL
          AND model_type = 'global_baseline'
        ORDER BY created_at ASC
        LIMIT 1
      '''),
      parameters: {'market': market},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> championModel({
    String? leagueId,
    required String market,
  }) async {
    final db = await connection();
    final leagueFilter = leagueId == null ? 'IS NULL' : '= @league_id';
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_model_versions
        WHERE market = @market AND league_id $leagueFilter
          AND status = 'champion'
        LIMIT 1
      '''),
      parameters: {
        'market': market,
        if (leagueId != null) 'league_id': leagueId,
      },
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> challengerModels({
    String? leagueId,
    required String market,
  }) async {
    final db = await connection();
    final leagueFilter = leagueId == null ? 'IS NULL' : '= @league_id';
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_model_versions
        WHERE market = @market AND league_id $leagueFilter
          AND status = 'challenger'
        ORDER BY created_at DESC
      '''),
      parameters: {
        'market': market,
        if (leagueId != null) 'league_id': leagueId,
      },
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Batch-Variante von [championModel]/[challengerModels] für den Model-Lab-
  /// Übersichts-Endpoint (Section 70): lädt Champions und Challenger für ALLE
  /// übergebenen Liga x Markt-Kombinationen mit einem einzigen Query, statt
  /// wie bei einzeln aufgerufenen [championModel]/[challengerModels] 2
  /// sequenzielle DB-Roundtrips je Kombination auszulösen (siehe
  /// [footballLeagueManualStatuses] für dasselbe Muster).
  Future<List<Map<String, Object?>>> modelVersionsForLeagueMarkets({
    required List<String> leagueIds,
    required List<String> markets,
  }) async {
    if (leagueIds.isEmpty || markets.isEmpty) return const [];

    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_model_versions
        WHERE market = ANY(@markets)
          AND league_id = ANY(@league_ids)
          AND status IN ('champion', 'challenger')
        ORDER BY created_at DESC
      '''),
      parameters: {
        'markets': markets,
        'league_ids': leagueIds,
      },
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<List<Map<String, Object?>>> allModelVersions({
    String? status,
    int limit = 500,
  }) async {
    final db = await connection();
    final statusFilter = status == null ? '' : 'WHERE status = @status';
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_model_versions
        $statusFilter
        ORDER BY created_at DESC
        LIMIT @limit
      '''),
      parameters: {if (status != null) 'status': status, 'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Section 53/54: Promotion nur, wenn `PHOENIX_MODEL_PROMOTION_ENABLED`
  /// serverseitig aktiv ist - der Aufrufer (Route) muss dies bereits vorher
  /// geprüft haben. Diese Methode selbst führt den atomaren DB-Wechsel aus:
  /// alter Champion -> 'retired' (bleibt erhalten, Section 57), neuer
  /// Champion -> 'champion'.
  Future<void> promoteModel({
    required int newChampionId,
    int? previousChampionId,
  }) async {
    final db = await connection();
    await db.runTx((session) async {
      if (previousChampionId != null) {
        await session.execute(
          Sql.named('''
            UPDATE phoenix_model_versions
            SET status = 'retired'
            WHERE id = @id
          '''),
          parameters: {'id': previousChampionId},
        );
      }
      await session.execute(
        Sql.named('''
          UPDATE phoenix_model_versions
          SET status = 'champion',
              champion_since = NOW(),
              last_promotion_at = NOW(),
              previous_champion_id = @previous_champion_id
          WHERE id = @id
        '''),
        parameters: {
          'id': newChampionId,
          'previous_champion_id': previousChampionId,
        },
      );
    });
  }

  /// Section 57: Rollback ist ein reiner, atomarer Statuswechsel zurück -
  /// nichts wird gelöscht, jede historische Prediction behält ihre damalige
  /// Modellversion (payload/model_version bleiben unverändert).
  Future<void> rollbackModel({
    required int currentChampionId,
    required int rollbackToModelId,
  }) async {
    final db = await connection();
    await db.runTx((session) async {
      await session.execute(
        Sql.named('''
          UPDATE phoenix_model_versions
          SET status = 'retired', rollback_model_id = @rollback_to
          WHERE id = @current
        '''),
        parameters: {
          'current': currentChampionId,
          'rollback_to': rollbackToModelId,
        },
      );
      await session.execute(
        Sql.named('''
          UPDATE phoenix_model_versions
          SET status = 'champion', champion_since = NOW(), last_promotion_at = NOW()
          WHERE id = @id
        '''),
        parameters: {'id': rollbackToModelId},
      );
    });
  }

  Future<void> recordModelAssignment({
    String? leagueId,
    required String market,
    required int modelVersionId,
    required bool isGlobal,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO phoenix_model_assignments (
          league_id, market, model_version_id, is_global
        ) VALUES (@league_id, @market, @model_version_id, @is_global)
      '''),
      parameters: {
        'league_id': leagueId,
        'market': market,
        'model_version_id': modelVersionId,
        'is_global': isGlobal,
      },
    );
  }

  Future<int> createLearningRun({required String triggerType}) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO phoenix_learning_runs (trigger_type)
        VALUES (@trigger_type)
        RETURNING id
      '''),
      parameters: {'trigger_type': triggerType},
    );
    return result.first[0] as int;
  }

  Future<void> updateLearningRunStep({
    required int id,
    required String currentStep,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE phoenix_learning_runs SET current_step = @step WHERE id = @id
      '''),
      parameters: {'id': id, 'step': currentStep},
    );
  }

  /// Aktualisiert die sichtbaren Zwischenstände eines laufenden Learning-Runs.
  /// Damit zeigt das Control Center während langer Auswertungen echten
  /// Fortschritt statt dauerhaft 0/0 bis zur finalen Speicherung.
  Future<void> updateLearningRunProgress({
    required int id,
    required String currentStep,
    required int leaguesProcessed,
    required int marketsProcessed,
    required int eligibleMatches,
    required int excludedMatches,
    required int challengersCreated,
    Map<String, Object?> summary = const {},
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE phoenix_learning_runs SET
          current_step = @step,
          leagues_processed = @leagues_processed,
          markets_processed = @markets_processed,
          eligible_matches = @eligible_matches,
          excluded_matches = @excluded_matches,
          challengers_created = @challengers_created,
          summary = CAST(@summary AS JSONB)
        WHERE id = @id AND status = 'running'
      '''),
      parameters: {
        'id': id,
        'step': currentStep,
        'leagues_processed': leaguesProcessed,
        'markets_processed': marketsProcessed,
        'eligible_matches': eligibleMatches,
        'excluded_matches': excludedMatches,
        'challengers_created': challengersCreated,
        'summary': jsonEncode(summary),
      },
    );
  }

  Future<void> completeLearningRun({
    required int id,
    required String status,
    required int leaguesProcessed,
    required int marketsProcessed,
    required int eligibleMatches,
    required int excludedMatches,
    required Map<String, Object?> exclusionsByReason,
    required int challengersCreated,
    List<Object?> errors = const [],
    Map<String, Object?> summary = const {},
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE phoenix_learning_runs SET
          status = @status,
          completed_at = NOW(),
          current_step = 'completed',
          leagues_processed = @leagues_processed,
          markets_processed = @markets_processed,
          eligible_matches = @eligible_matches,
          excluded_matches = @excluded_matches,
          exclusions_by_reason = CAST(@exclusions_by_reason AS JSONB),
          challengers_created = @challengers_created,
          errors = CAST(@errors AS JSONB),
          summary = CAST(@summary AS JSONB)
        WHERE id = @id
      '''),
      parameters: {
        'id': id,
        'status': status,
        'leagues_processed': leaguesProcessed,
        'markets_processed': marketsProcessed,
        'eligible_matches': eligibleMatches,
        'excluded_matches': excludedMatches,
        'exclusions_by_reason': jsonEncode(exclusionsByReason),
        'challengers_created': challengersCreated,
        'errors': jsonEncode(errors),
        'summary': jsonEncode(summary),
      },
    );
  }

  Future<Map<String, Object?>?> learningRun(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT * FROM phoenix_learning_runs WHERE id = @id'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> listLearningRuns({
    int limit = 50,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_learning_runs
        ORDER BY started_at DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<void> addLearningCandidate({
    required int learningRunId,
    required int modelVersionId,
    String? leagueId,
    required String market,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO phoenix_learning_candidates (
          learning_run_id, model_version_id, league_id, market
        ) VALUES (@run_id, @model_id, @league_id, @market)
      '''),
      parameters: {
        'run_id': learningRunId,
        'model_id': modelVersionId,
        'league_id': leagueId,
        'market': market,
      },
    );
  }

  /// Section 64: einfaches Advisory-Lock. Gibt `true` zurück, wenn der Lock
  /// erfolgreich erworben wurde (kein anderer Learning Run/Review aktiv).
  ///
  /// Ist der bestehende Lock älter als [staleAfterMinutes], gilt er als
  /// verwaist (der Prozess, der ihn hielt, wurde vermutlich durch einen
  /// Deploy/Crash beendet, bevor `releaseModelLabLock` je erreicht wurde) und
  /// wird atomar neu vergeben, statt für immer jeden künftigen Lauf zu
  /// blockieren.
  Future<bool> acquireModelLabLock(
    String lockName, {
    required int staleAfterMinutes,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO phoenix_model_lab_locks (lock_name, locked_by)
        VALUES (@name, 'model_lab')
        ON CONFLICT (lock_name) DO UPDATE SET
          locked_at = NOW(),
          locked_by = 'model_lab'
        WHERE phoenix_model_lab_locks.locked_at
          < NOW() - make_interval(mins => @stale_minutes)
        RETURNING lock_name
      '''),
      parameters: {'name': lockName, 'stale_minutes': staleAfterMinutes},
    );
    return result.isNotEmpty;
  }

  /// Section 64/65: markiert Learning Runs, die noch als "running" gelten,
  /// aber älter als [staleAfterMinutes] sind, als "failed" nach. Wird direkt
  /// nach dem (ggf. per Stale-Reclaim erfolgreichen) Lock-Erwerb aufgerufen,
  /// damit die UI nie unbegrenzt einen toten Run als RUNNING anzeigt.
  /// Repariert einen abgebrochenen Learning-Run inklusive seines Locks.
  ///
  /// Ein normaler Run schreibt seinen Status immer in [completeLearningRun]
  /// und entfernt den Lock im finally-Block. Bleibt nach einem Deploy/Crash
  /// trotzdem eine alte `running`-Zeile zurück, darf sie keinen neuen
  /// Spieltag blockieren. Die Bereinigung greift ausschließlich, wenn es
  /// KEINEN frischen Learning-Run innerhalb der konfigurierten Lease-Zeit
  /// gibt. Sie markiert den alten Lauf nachvollziehbar als failed und gibt
  /// seinen Lock frei; Modelle oder Produktionsprognosen werden nie gelöscht.
  Future<int> recoverOrphanedLearningRunAndLock({
    required int staleAfterMinutes,
  }) async {
    final db = await connection();
    return db.runTx((session) async {
      final orphaned = await session.execute(
        Sql.named('''
        UPDATE phoenix_learning_runs SET
          status = 'failed',
          completed_at = NOW(),
          current_step = 'orphaned',
          errors = CAST(@errors AS JSONB)
        WHERE status = 'running'
          AND started_at < NOW() - make_interval(mins => @stale_minutes)
        RETURNING id
      '''),
        parameters: {
          'stale_minutes': staleAfterMinutes,
          'errors': jsonEncode([
            'Orphaned: Prozess wurde vor Abschluss beendet (z.B. durch einen '
                'Deploy) und automatisch per Stale-Lock-Reconciliation als '
                'failed markiert.',
          ]),
        },
      );

      if (orphaned.isEmpty) return 0;

      // Nur wenn nach der Bereinigung kein frischer Run existiert, darf ein
      // alter Lock entfernt werden. Das verhindert Paralleltraining bei
      // einem tatsächlich aktiven Run.
      await session.execute(
        Sql.named('''
          DELETE FROM phoenix_model_lab_locks
          WHERE lock_name = 'learning_run'
            AND NOT EXISTS (
              SELECT 1 FROM phoenix_learning_runs
              WHERE status = 'running'
                AND started_at >= NOW() - make_interval(mins => @stale_minutes)
            )
        '''),
        parameters: {'stale_minutes': staleAfterMinutes},
      );
      return orphaned.length;
    });
  }

  /// Rückwärtskompatibler Name für bestehende Aufrufer.
  Future<void> reconcileOrphanedLearningRuns({
    required int staleAfterMinutes,
  }) async {
    await recoverOrphanedLearningRunAndLock(
      staleAfterMinutes: staleAfterMinutes,
    );
  }

  Future<void> releaseModelLabLock(String lockName) async {
    final db = await connection();
    await db.execute(
      Sql.named('DELETE FROM phoenix_model_lab_locks WHERE lock_name = @name'),
      parameters: {'name': lockName},
    );
  }

  Future<int> insertModelEvaluation({
    required int modelVersionId,
    int? comparedAgainstModelId,
    String? leagueId,
    required String market,
    required String evaluationType,
    required String matchScope,
    required int sampleSize,
    double? brierScore,
    double? logLoss,
    List<Object?> calibration = const [],
    double? accuracy,
    double? roi,
    double? avgProbability,
    Map<String, Object?> uncertainty = const {},
    DateTime? periodStart,
    DateTime? periodEnd,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO phoenix_model_evaluations (
          model_version_id, compared_against_model_id, league_id, market,
          evaluation_type, match_scope, sample_size, brier_score, log_loss,
          calibration, accuracy, roi, avg_probability, uncertainty,
          period_start, period_end
        ) VALUES (
          @model_version_id, @compared_against_model_id, @league_id, @market,
          @evaluation_type, @match_scope, @sample_size, @brier_score, @log_loss,
          CAST(@calibration AS JSONB), @accuracy, @roi, @avg_probability,
          CAST(@uncertainty AS JSONB), @period_start, @period_end
        )
        RETURNING id
      '''),
      parameters: {
        'model_version_id': modelVersionId,
        'compared_against_model_id': comparedAgainstModelId,
        'league_id': leagueId,
        'market': market,
        'evaluation_type': evaluationType,
        'match_scope': matchScope,
        'sample_size': sampleSize,
        'brier_score': brierScore,
        'log_loss': logLoss,
        'calibration': jsonEncode(calibration),
        'accuracy': accuracy,
        'roi': roi,
        'avg_probability': avgProbability,
        'uncertainty': jsonEncode(uncertainty),
        'period_start': periodStart?.toUtc().toIso8601String(),
        'period_end': periodEnd?.toUtc().toIso8601String(),
      },
    );
    return result.first[0] as int;
  }

  Future<List<Map<String, Object?>>> modelEvaluations({
    required int modelVersionId,
    String? evaluationType,
  }) async {
    final db = await connection();
    final typeFilter =
        evaluationType == null ? '' : 'AND evaluation_type = @type';
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_model_evaluations
        WHERE model_version_id = @model_version_id
        $typeFilter
        ORDER BY created_at DESC
      '''),
      parameters: {
        'model_version_id': modelVersionId,
        if (evaluationType != null) 'type': evaluationType,
      },
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Speichert eine Shadow Prediction idempotent und meldet zurück, ob dabei
  /// wirklich eine neue Zeile entstanden ist. Damit sind Cron-Protokoll und
  /// Monitoring nach Wiederholungen/Deploys korrekt statt künstlich erhöht.
  Future<bool> upsertShadowPrediction({
    required int modelVersionId,
    required String fixtureId,
    required String leagueId,
    required String market,
    int? phaseTwoScanRunId,
    DateTime? kickoff,
    required List<String> classLabels,
    required List<double> classProbabilities,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO phoenix_shadow_predictions (
          model_version_id, fixture_id, league_id, market,
          phase_two_scan_run_id, kickoff, class_labels, class_probabilities
        ) VALUES (
          @model_version_id, @fixture_id, @league_id, @market,
          @phase_two_scan_run_id, @kickoff,
          CAST(@class_labels AS JSONB), CAST(@class_probabilities AS JSONB)
        )
        ON CONFLICT (model_version_id, fixture_id, market) DO NOTHING
        RETURNING id
      '''),
      parameters: {
        'model_version_id': modelVersionId,
        'fixture_id': fixtureId,
        'league_id': leagueId,
        'market': market,
        'phase_two_scan_run_id': phaseTwoScanRunId,
        'kickoff': kickoff?.toUtc().toIso8601String(),
        'class_labels': jsonEncode(classLabels),
        'class_probabilities': jsonEncode(classProbabilities),
      },
    );
    return result.isNotEmpty;
  }

  /// Fixtures, für die bereits mind. ein aktiver Champion/Challenger eine
  /// Shadow-/Live-Prediction erzeugt hat, aber noch kein Ergebnis vorliegt.
  Future<List<Map<String, Object?>>> pendingShadowPredictions({
    int limit = 500,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT sp.*, m.status AS match_status, m.home_goals, m.away_goals
        FROM phoenix_shadow_predictions sp
        JOIN football_matches m ON m.id = sp.fixture_id
        WHERE sp.settled = FALSE
        ORDER BY sp.kickoff ASC NULLS LAST
        LIMIT @limit
      '''),
      parameters: {'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<void> settleShadowPrediction({
    required int id,
    required int outcomeIndex,
    required double brierScore,
    required double logLoss,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE phoenix_shadow_predictions
        SET settled = TRUE, outcome_index = @outcome_index,
            brier_score = @brier_score, log_loss = @log_loss,
            settled_at = NOW()
        WHERE id = @id
      '''),
      parameters: {
        'id': id,
        'outcome_index': outcomeIndex,
        'brier_score': brierScore,
        'log_loss': logLoss,
      },
    );
  }

  Future<List<Map<String, Object?>>> settledShadowPredictions({
    required int modelVersionId,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_shadow_predictions
        WHERE model_version_id = @model_version_id AND settled = TRUE
        ORDER BY kickoff ASC
      '''),
      parameters: {'model_version_id': modelVersionId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<bool> monthlyReviewExists({
    required int year,
    required int month,
    String? leagueId,
    required String market,
  }) async {
    final db = await connection();
    final leagueFilter = leagueId == null ? 'IS NULL' : '= @league_id';
    final result = await db.execute(
      Sql.named('''
        SELECT id FROM phoenix_monthly_reviews
        WHERE review_year = @year AND review_month = @month
          AND market = @market AND league_id $leagueFilter
      '''),
      parameters: {
        'year': year,
        'month': month,
        'market': market,
        if (leagueId != null) 'league_id': leagueId,
      },
    );
    return result.isNotEmpty;
  }

  Future<int> insertMonthlyReview({
    required int year,
    required int month,
    String? leagueId,
    required String market,
    int? championModelId,
    int? challengerModelId,
    required int sameMatchSample,
    required Map<String, Object?> metrics,
    required Map<String, Object?> uncertainty,
    required String recommendation,
    required String reason,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO phoenix_monthly_reviews (
          review_year, review_month, league_id, market, champion_model_id,
          challenger_model_id, same_match_sample, metrics, uncertainty,
          recommendation, reason
        ) VALUES (
          @year, @month, @league_id, @market, @champion_model_id,
          @challenger_model_id, @sample, CAST(@metrics AS JSONB),
          CAST(@uncertainty AS JSONB), @recommendation, @reason
        )
        ON CONFLICT (review_year, review_month, market, COALESCE(league_id, '__GLOBAL__'))
        DO NOTHING
        RETURNING id
      '''),
      parameters: {
        'year': year,
        'month': month,
        'league_id': leagueId,
        'market': market,
        'champion_model_id': championModelId,
        'challenger_model_id': challengerModelId,
        'sample': sameMatchSample,
        'metrics': jsonEncode(metrics),
        'uncertainty': jsonEncode(uncertainty),
        'recommendation': recommendation,
        'reason': reason,
      },
    );
    if (result.isEmpty) {
      throw StateError(
        'Monthly Review für $year-$month/$market/$leagueId existiert bereits.',
      );
    }
    return result.first[0] as int;
  }

  Future<List<Map<String, Object?>>> listMonthlyReviews({
    int limit = 100,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_monthly_reviews
        ORDER BY reviewed_at DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<void> insertModelLabAuditLog({
    required String action,
    required String actor,
    int? modelVersionId,
    String? leagueId,
    String? market,
    int? learningRunId,
    Map<String, Object?> details = const {},
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO phoenix_model_audit_log (
          action, actor, model_version_id, league_id, market,
          learning_run_id, details
        ) VALUES (
          @action, @actor, @model_version_id, @league_id, @market,
          @learning_run_id, CAST(@details AS JSONB)
        )
      '''),
      parameters: {
        'action': action,
        'actor': actor,
        'model_version_id': modelVersionId,
        'league_id': leagueId,
        'market': market,
        'learning_run_id': learningRunId,
        'details': jsonEncode(details),
      },
    );
  }

  Future<List<Map<String, Object?>>> listModelLabAuditLog({
    int limit = 200,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_model_audit_log
        ORDER BY occurred_at DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<int> countShadowPredictions() async {
    final db = await connection();
    final result =
        await db.execute('SELECT COUNT(*) FROM phoenix_shadow_predictions');
    return (result.first[0] as int?) ?? 0;
  }

  Future<void> upsertMatchLearningFlag({
    required String fixtureId,
    required String leagueId,
    required String market,
    required bool eligible,
    String? exclusionReason,
    int? dataQuality,
    DateTime? snapshotTimestamp,
    DateTime? kickoff,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO phoenix_match_learning_flags (
          fixture_id, league_id, market, eligible, exclusion_reason,
          data_quality, snapshot_timestamp, kickoff
        ) VALUES (
          @fixture_id, @league_id, @market, @eligible, @exclusion_reason,
          @data_quality, @snapshot_timestamp, @kickoff
        )
        ON CONFLICT (fixture_id, market) DO UPDATE SET
          eligible = EXCLUDED.eligible,
          exclusion_reason = EXCLUDED.exclusion_reason,
          data_quality = EXCLUDED.data_quality,
          snapshot_timestamp = EXCLUDED.snapshot_timestamp,
          kickoff = EXCLUDED.kickoff,
          checked_at = NOW()
      '''),
      parameters: {
        'fixture_id': fixtureId,
        'league_id': leagueId,
        'market': market,
        'eligible': eligible,
        'exclusion_reason': exclusionReason,
        'data_quality': dataQuality,
        'snapshot_timestamp': snapshotTimestamp?.toUtc().toIso8601String(),
        'kickoff': kickoff?.toUtc().toIso8601String(),
      },
    );
  }

  // ---------------------------------------------------------------------
  // PHÖNIX CONTROL CENTER (internes Admin-Webapp-Backend, additiv). Eigene
  // Mitarbeiter-/Session-/Audit-Queries, komplett getrennt vom bestehenden
  // `PHOENIX_ADMIN_TOKEN`-Mechanismus. Tabellen siehe
  // `_migrateControlCenter`.
  // ---------------------------------------------------------------------

  Future<int> countAdminEmployees() async {
    final db = await connection();
    final result = await db.execute('SELECT COUNT(*) FROM admin_employees');
    return (result.first[0] as int?) ?? 0;
  }

  Future<Map<String, Object?>> insertAdminEmployee({
    required String name,
    required String login,
    required String email,
    required String passwordHash,
    required String role,
    String? department,
    Map<String, Object?> permissionOverrides = const {},
    String status = 'active',
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO admin_employees (
          name, login, email, password_hash, role, permission_overrides,
          department, status
        ) VALUES (
          @name, @login, @email, @password_hash, @role,
          CAST(@permission_overrides AS JSONB), @department, @status
        )
        RETURNING *
      '''),
      parameters: {
        'name': name,
        'login': login,
        'email': email,
        'password_hash': passwordHash,
        'role': role,
        'permission_overrides': jsonEncode(permissionOverrides),
        'department': department,
        'status': status,
      },
    );
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> adminEmployeeByLogin(String login) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM admin_employees WHERE login = @login LIMIT 1
      '''),
      parameters: {'login': login},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Abschnitt "MITARBEITER" (gemeinsamer App/Center-Login): wird bei jeder
  /// App-Session-Ausstellung aufgerufen. Verknüpft die `users`-Zeile
  /// dauerhaft mit dem passenden `admin_employees`-Datensatz (per E-Mail,
  /// case-insensitive), falls einer existiert, und liefert die App-seitigen
  /// Bypass-Flags zurück. Ein deaktivierter Mitarbeiter (`status <> 'active'`)
  /// bekommt bewusst KEINEN Bypass mehr, bleibt aber verknüpft (Historie).
  Future<Map<String, Object?>?> linkEmployeeAppAccess({
    required int userId,
    required String email,
  }) async {
    final db = await connection();
    final employeeRows = await db.execute(
      Sql.named('''
        SELECT id, role, status, staff_app_access, maintenance_bypass,
               premium_bypass, beta_access, feature_flag_bypass, user_id
        FROM admin_employees
        WHERE LOWER(email) = LOWER(@email)
        LIMIT 1
      '''),
      parameters: {'email': email},
    );
    if (employeeRows.isEmpty) return null;
    final employee =
        Map<String, Object?>.from(employeeRows.first.toColumnMap());
    final employeeId = employee['id'] as int;

    if (employee['user_id'] == null) {
      await db.execute(
        Sql.named('''
          UPDATE admin_employees SET user_id = @user_id WHERE id = @id
        '''),
        parameters: {'user_id': userId, 'id': employeeId},
      );
    }

    final accountType = employee['role'] == 'OWNER' ? 'OWNER' : 'EMPLOYEE';
    await db.execute(
      Sql.named('''
        UPDATE users SET account_type = @account_type, updated_at = NOW()
        WHERE id = @id AND account_type <> @account_type
      '''),
      parameters: {'id': userId, 'account_type': accountType},
    );

    final isActive = employee['status'] == 'active';
    return {
      'role': employee['role'],
      'active': isActive,
      'staffAppAccess': isActive && employee['staff_app_access'] == true,
      'maintenanceBypass': isActive && employee['maintenance_bypass'] == true,
      'premiumBypass': isActive && employee['premium_bypass'] == true,
      'betaAccess': isActive && employee['beta_access'] == true,
      'featureFlagBypass': isActive && employee['feature_flag_bypass'] == true,
    };
  }

  Future<Map<String, Object?>?> adminEmployeeById(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT * FROM admin_employees WHERE id = @id LIMIT 1'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Section "GET /employees": Mitarbeiterliste inkl. Anzahl aktuell aktiver
  /// (nicht abgelaufener, nicht widerrufener) Sessions je Mitarbeiter.
  Future<List<Map<String, Object?>>>
      listAdminEmployeesWithActiveSessionCounts() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT
        e.*,
        COUNT(s.token) FILTER (
          WHERE s.revoked_at IS NULL AND s.expires_at > NOW()
        ) AS active_session_count
      FROM admin_employees e
      LEFT JOIN admin_sessions s ON s.employee_id = e.id
      GROUP BY e.id
      ORDER BY e.created_at ASC
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Minimaler Mitarbeiterauszug (nur id/name, keine Login/E-Mail/Rolle) für
  /// z.B. Ticket-Zuweisungs-Dropdowns - erlaubt Rollen ohne `employees.view`
  /// (etwa SUPPORT) trotzdem, Kollegen für die Zuweisung auszuwählen, ohne
  /// die vollen Mitarbeiterdaten offenzulegen.
  Future<List<Map<String, Object?>>> listActiveAdminEmployeesMinimal() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT id, name FROM admin_employees
      WHERE status = 'active'
      ORDER BY name ASC
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Aktualisiert nur die übergebenen Felder. `department` kann bewusst auf
  /// NULL gesetzt werden - dafür muss [departmentProvided] `true` sein.
  Future<Map<String, Object?>?> updateAdminEmployee({
    required int id,
    String? role,
    bool departmentProvided = false,
    String? department,
    Map<String, Object?>? permissionOverrides,
    String? status,
  }) async {
    final db = await connection();
    final setClauses = <String>[];
    final parameters = <String, Object?>{'id': id};

    if (role != null) {
      setClauses.add('role = @role');
      parameters['role'] = role;
    }
    if (departmentProvided) {
      setClauses.add('department = @department');
      parameters['department'] = department;
    }
    if (permissionOverrides != null) {
      setClauses
          .add('permission_overrides = CAST(@permission_overrides AS JSONB)');
      parameters['permission_overrides'] = jsonEncode(permissionOverrides);
    }
    if (status != null) {
      setClauses.add('status = @status');
      parameters['status'] = status;
    }

    if (setClauses.isEmpty) {
      return adminEmployeeById(id);
    }

    final result = await db.execute(
      Sql.named('''
        UPDATE admin_employees
        SET ${setClauses.join(', ')}
        WHERE id = @id
        RETURNING *
      '''),
      parameters: parameters,
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Setzt `status = 'disabled'` und widerruft in derselben Transaktion alle
  /// noch aktiven Sessions dieses Mitarbeiters (Section "disable revokes
  /// sessions"). Der Aufrufer muss den Last-Owner-Schutz vorher separat über
  /// [countActiveOwners] prüfen.
  /// Break-glass-Passwort-Reset: setzt den Passwort-Hash für [login] und
  /// beendet alle aktiven Sessions dieses Mitarbeiters. Nur über den
  /// statischen `PHOENIX_ADMIN_TOKEN` erreichbar (routes.dart) - gedacht für
  /// den Fall, dass sich niemand mehr einloggen kann (kein Passwort-Reset-
  /// Flow über die Session-Auth selbst, das wäre ein Henne-Ei-Problem).
  Future<bool> resetAdminEmployeePasswordByLogin({
    required String login,
    required String passwordHash,
  }) async {
    final db = await connection();
    return db.runTx((session) async {
      final result = await session.execute(
        Sql.named('''
          UPDATE admin_employees
          SET password_hash = @password_hash
          WHERE login = @login
          RETURNING id
        '''),
        parameters: {'login': login, 'password_hash': passwordHash},
      );
      if (result.isEmpty) return false;
      final employeeId = result.first[0] as int;
      await session.execute(
        Sql.named('''
          UPDATE admin_sessions
          SET revoked_at = NOW()
          WHERE employee_id = @id AND revoked_at IS NULL
        '''),
        parameters: {'id': employeeId},
      );
      return true;
    });
  }

  Future<Map<String, Object?>?> disableAdminEmployeeAndRevokeSessions(
    int id,
  ) async {
    final db = await connection();
    return db.runTx((session) async {
      final result = await session.execute(
        Sql.named('''
          UPDATE admin_employees
          SET status = 'disabled'
          WHERE id = @id
          RETURNING *
        '''),
        parameters: {'id': id},
      );
      if (result.isEmpty) return null;
      await session.execute(
        Sql.named('''
          UPDATE admin_sessions
          SET revoked_at = NOW()
          WHERE employee_id = @id AND revoked_at IS NULL
        '''),
        parameters: {'id': id},
      );
      // Mitarbeiter-Sicherheit: ein deaktivierter Mitarbeiter verliert auch
      // seinen App-Zugriff sofort - nicht nur die Bypass-Flags (die werden
      // bereits reaktiv über linkEmployeeAppAccess()'s status-Prüfung
      // false), sondern auch jede bereits laufende App-Session.
      final employeeRow = Map<String, Object?>.from(result.first.toColumnMap());
      final linkedUserId = employeeRow['user_id'];
      if (linkedUserId != null) {
        await session.execute(
          Sql.named('''
            UPDATE user_sessions
            SET revoked_at = NOW()
            WHERE user_id = @user_id AND revoked_at IS NULL
          '''),
          parameters: {'user_id': linkedUserId},
        );
      }
      return employeeRow;
    });
  }

  Future<int> countActiveOwners() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT COUNT(*) FROM admin_employees
      WHERE role = 'OWNER' AND status = 'active'
    ''');
    return (result.first[0] as int?) ?? 0;
  }

  Future<void> touchAdminEmployeeLastLogin(int id) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE admin_employees SET last_login_at = NOW() WHERE id = @id
      '''),
      parameters: {'id': id},
    );
  }

  Future<void> createAdminSession({
    required int employeeId,
    required String token,
    required DateTime expiresAt,
    String? ip,
    String? userAgent,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO admin_sessions (
          token, employee_id, expires_at, ip, user_agent
        ) VALUES (@token, @employee_id, @expires_at, @ip, @user_agent)
      '''),
      parameters: {
        'token': token,
        'employee_id': employeeId,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'ip': ip,
        'user_agent': userAgent,
      },
    );
  }

  /// Liefert eine Session zusammen mit dem zugehörigen Mitarbeiter in einer
  /// einzigen Abfrage (Auth-Guard, Section "GET /auth/me" etc.). Die
  /// Employee-Spalten sind so benannt, dass `Employee.fromRow` sie direkt
  /// einlesen kann; die Session-Gültigkeit selbst wird zusätzlich über
  /// `session_expires_at`/`session_revoked_at` im Aufrufer geprüft
  /// (`isSessionActive`).
  Future<Map<String, Object?>?> adminSessionWithEmployee(String token) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          e.id, e.name, e.login, e.email, e.role, e.permission_overrides,
          e.department, e.status, e.created_at, e.last_login_at,
          s.token AS session_token,
          s.expires_at AS session_expires_at,
          s.revoked_at AS session_revoked_at
        FROM admin_sessions s
        JOIN admin_employees e ON e.id = s.employee_id
        WHERE s.token = @token
        LIMIT 1
      '''),
      parameters: {'token': token},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<void> revokeAdminSession(String token) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE admin_sessions
        SET revoked_at = NOW()
        WHERE token = @token AND revoked_at IS NULL
      '''),
      parameters: {'token': token},
    );
  }

  Future<void> insertAdminAuditLog({
    int? employeeId,
    String? employeeLogin,
    required String area,
    String? objectType,
    String? objectId,
    required String action,
    Map<String, Object?>? previousValue,
    Map<String, Object?>? newValue,
    String? reason,
    String? comment,
    String? ip,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO admin_audit_log (
          employee_id, employee_login, area, object_type, object_id, action,
          previous_value, new_value, reason, comment, ip
        ) VALUES (
          @employee_id, @employee_login, @area, @object_type, @object_id,
          @action, CAST(@previous_value AS JSONB), CAST(@new_value AS JSONB),
          @reason, @comment, @ip
        )
      '''),
      parameters: {
        'employee_id': employeeId,
        'employee_login': employeeLogin,
        'area': area,
        'object_type': objectType,
        'object_id': objectId,
        'action': action,
        'previous_value':
            previousValue == null ? null : jsonEncode(previousValue),
        'new_value': newValue == null ? null : jsonEncode(newValue),
        'reason': reason,
        'comment': comment,
        'ip': ip,
      },
    );
  }

  /// Section 4 (Audit Log): joins `admin_employees` for a real name+role
  /// (not just the raw login) and returns camelCase keys - the previous
  /// `SELECT * ... toColumnMap()` handed the frontend raw snake_case column
  /// names (`employee_login`, `object_id`, ...) while the UI read camelCase
  /// properties, so every field silently came back `undefined`. Also adds
  /// action/date-range filters, offset-based pagination, and a total count -
  /// none of which existed before (the old signature only supported a fixed
  /// `limit`, no `offset`).
  Future<Map<String, Object?>> listAdminAuditLog({
    String? area,
    int? employeeId,
    String? action,
    String? objectId,
    DateTime? dateFrom,
    DateTime? dateTo,
    int limit = 100,
    int offset = 0,
  }) async {
    final db = await connection();
    final safeLimit = limit.clamp(1, 500);
    final safeOffset = offset.clamp(0, 1 << 30);
    final conditions = <String>[];
    final parameters = <String, Object?>{};

    if (area != null && area.trim().isNotEmpty) {
      conditions.add('a.area = @area');
      parameters['area'] = area;
    }
    if (employeeId != null) {
      conditions.add('a.employee_id = @employee_id');
      parameters['employee_id'] = employeeId;
    }
    if (action != null && action.trim().isNotEmpty) {
      conditions.add('a.action = @action');
      parameters['action'] = action;
    }
    // Section 20 (AN2): "Historie" auf News/FAQ-Artikeln - dieselbe
    // Audit-Log-Tabelle, gefiltert auf ein einzelnes Objekt.
    if (objectId != null && objectId.trim().isNotEmpty) {
      conditions.add('a.object_id = @object_id');
      parameters['object_id'] = objectId;
    }
    if (dateFrom != null) {
      conditions.add('a.created_at >= @date_from');
      parameters['date_from'] = dateFrom;
    }
    if (dateTo != null) {
      conditions.add('a.created_at <= @date_to');
      parameters['date_to'] = dateTo;
    }

    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final result = await db.execute(
      Sql.named('''
        SELECT
          a.id, a.employee_id, a.employee_login, e.name AS employee_name,
          e.role AS employee_role, a.area, a.object_type, a.object_id,
          a.action, a.previous_value, a.new_value, a.reason, a.comment,
          a.ip, a.created_at, a.reverted, a.reverted_at
        FROM admin_audit_log a
        LEFT JOIN admin_employees e ON e.id = a.employee_id
        $whereClause
        ORDER BY a.created_at DESC
        LIMIT @limit OFFSET @offset
      '''),
      parameters: {...parameters, 'limit': safeLimit, 'offset': safeOffset},
    );

    final countResult = await db.execute(
      Sql.named('SELECT COUNT(*) AS total FROM admin_audit_log a $whereClause'),
      parameters: parameters,
    );
    final total = int.tryParse(
            countResult.first.toColumnMap()['total']?.toString() ?? '') ??
        0;

    final entries = result.map((row) {
      final m = row.toColumnMap();
      return <String, Object?>{
        'id': m['id'],
        'employeeId': m['employee_id'],
        'employeeLogin': m['employee_login'],
        'employeeName': m['employee_name'] ?? m['employee_login'],
        'employeeRole': m['employee_role'],
        'area': m['area'],
        'objectType': m['object_type'],
        'objectId': m['object_id'],
        'action': m['action'],
        'previousValue': m['previous_value'],
        'newValue': m['new_value'],
        'reason': m['reason'],
        'comment': m['comment'],
        'ip': m['ip'],
        'createdAt': m['created_at'],
        'reverted': m['reverted'],
        'revertedAt': m['reverted_at'],
      };
    }).toList();

    return {'entries': entries, 'total': total};
  }

  // -- PHÖNIX CONTROL CENTER PHASE 2: Football-Domain-Admin-APIs ---------
  // Matches-Browsing, Pro-Match-Flags, Teams/Wappen & Assets, Datenqualität.
  // Bleibt bewusst getrennt von den obigen Control-Center-Methoden: diese
  // Endpunkte hängen an `/api/admin/football/...` mit dem statischen
  // PHOENIX_ADMIN_TOKEN (siehe `_isAdmin()` in routes.dart), nicht an der
  // Mitarbeiter-Session-Auth. `insertAdminAuditLog`/`listAdminAuditLog`
  // oben werden trotzdem wiederverwendet - ein Audit-Log reicht für beide
  // Auth-Wege.

  /// Paginierte, gefilterte Match-Liste für
  /// `GET /api/admin/football/matches`. Alle Filter sind additiv (AND
  /// verknüpft) und optional.
  Future<Map<String, Object?>> listFootballMatchesAdmin({
    String? date,
    String? leagueId,
    String? collectionTier,
    String? teamId,
    String? status,
    bool? visible,
    bool? hasAnalysis,
    bool? hasTip,
    bool? settled,
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await connection();
    final conditions = <String>[];
    final filterParameters = <String, Object?>{};

    if (date != null && date.trim().isNotEmpty) {
      conditions.add('m.kickoff_utc::date = CAST(@date AS DATE)');
      filterParameters['date'] = date.trim();
    }
    if (leagueId != null && leagueId.trim().isNotEmpty) {
      conditions.add('m.league_id = @league_id');
      filterParameters['league_id'] = leagueId.trim();
    }
    // Die Kategorie ist an der Liga hinterlegt, nicht am einzelnen Match.
    // EXISTS hält die Match-Abfrage und die COUNT-Abfrage identisch, ohne
    // Duplikate durch einen Join zu erzeugen.
    const allowedCollectionTiers = {'focus', 'watchlist', 'data_pool'};
    final normalizedCollectionTier = collectionTier?.trim().toLowerCase();
    if (normalizedCollectionTier != null &&
        allowedCollectionTiers.contains(normalizedCollectionTier)) {
      conditions.add('''
        EXISTS (
          SELECT 1
          FROM football_leagues l
          WHERE l.league_id = m.league_id
            AND l.collection_tier = @collection_tier
        )
      ''');
      filterParameters['collection_tier'] = normalizedCollectionTier;
    }
    if (teamId != null && teamId.trim().isNotEmpty) {
      conditions
          .add('(m.home_team_id = @team_id OR m.away_team_id = @team_id)');
      filterParameters['team_id'] = teamId.trim();
    }
    if (status != null && status.trim().isNotEmpty) {
      conditions.add('m.status = @status');
      filterParameters['status'] = status.trim();
    }
    if (visible != null) {
      conditions.add('m.visible = @visible');
      filterParameters['visible'] = visible;
    }
    if (hasAnalysis != null) {
      conditions.add(
        hasAnalysis
            ? "EXISTS (SELECT 1 FROM analyses a WHERE a.sport = 'football' AND a.match_id = m.id)"
            : "NOT EXISTS (SELECT 1 FROM analyses a WHERE a.sport = 'football' AND a.match_id = m.id)",
      );
    }
    // Section 6: "Tipp vorhanden"-Filter - separat von hasAnalysis, weil eine
    // Analyse existieren kann, ohne dass PHÖNIX daraus einen Tipp
    // veröffentlicht hat (z.B. zu geringer Value).
    if (hasTip != null) {
      conditions.add(
        hasTip
            ? "EXISTS (SELECT 1 FROM football_analysis_history h WHERE h.fixture_id = m.id AND h.market_key <> '')"
            : "NOT EXISTS (SELECT 1 FROM football_analysis_history h WHERE h.fixture_id = m.id AND h.market_key <> '')",
      );
    }
    if (settled != null) {
      conditions.add(
        settled
            ? '(m.home_goals IS NOT NULL AND m.away_goals IS NOT NULL)'
            : '(m.home_goals IS NULL OR m.away_goals IS NULL)',
      );
    }

    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final rows = await db.execute(
      Sql.named('''
        SELECT
          m.id, m.kickoff_utc, m.status, m.league_id, m.league_name, m.country,
          m.home_team_id, m.home_team_name, m.home_logo,
          m.away_team_id, m.away_team_name, m.away_logo,
          m.home_goals, m.away_goals, m.updated_at,
          m.visible, m.analysis_enabled, m.tip_enabled, m.learning_enabled,
          m.live_enabled, m.status_locked, m.status_lock_reason,
          EXISTS (
            SELECT 1 FROM analyses a
            WHERE a.sport = 'football' AND a.match_id = m.id
          ) AS has_analysis,
          top_tip.market_key AS top_tip_market_key,
          top_tip.market_label AS top_tip_market_label
        FROM football_matches m
        LEFT JOIN LATERAL (
          SELECT h.market_key, h.market_label
          FROM football_analysis_history h
          WHERE h.fixture_id = m.id AND h.market_key <> ''
          ORDER BY h.created_at DESC
          LIMIT 1
        ) top_tip ON TRUE
        $whereClause
        ORDER BY m.kickoff_utc DESC
        LIMIT @limit OFFSET @offset
      '''),
      parameters: {...filterParameters, 'limit': limit, 'offset': offset},
    );

    final countRows = await db.execute(
      Sql.named('''
        SELECT COUNT(*) AS total FROM football_matches m $whereClause
      '''),
      parameters: filterParameters,
    );
    final total = int.tryParse(
          countRows.first.toColumnMap()['total']?.toString() ?? '',
        ) ??
        0;

    return {
      'matches': rows
          .map((row) => Map<String, Object?>.from(row.toColumnMap()))
          .toList(),
      'total': total,
      'limit': limit,
      'offset': offset,
    };
  }

  /// Voller Match-Detail-Datensatz für
  /// `GET /api/admin/football/matches/<id>`: die Match-Zeile inklusive der
  /// fünf Steuerflags, plus - falls vorhanden - der eingefrorene
  /// Pre-Match-Analyse-Snapshot aus `football_analysis_history` (die erste
  /// je veröffentlichte Prognose, siehe Tabellenkommentar dort) und die
  /// zuletzt berechnete `analyses`-Zeile. Gibt `null` zurück, wenn das Match
  /// nicht existiert.
  Future<Map<String, Object?>?> footballMatchAdminDetail(String id) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        SELECT
          m.id, m.kickoff_utc, m.status, m.league_id, m.league_name, m.country,
          m.home_team_id, m.home_team_name, m.home_logo,
          m.away_team_id, m.away_team_name, m.away_logo,
          m.home_goals, m.away_goals, m.raw_json,
          m.visible, m.analysis_enabled, m.tip_enabled, m.learning_enabled,
          m.live_enabled, m.status_locked, m.status_lock_reason,
          m.status_locked_at, m.updated_at
        FROM football_matches m
        WHERE m.id = @id
      '''),
      parameters: {'id': id},
    );
    if (rows.isEmpty) return null;
    final match = Map<String, Object?>.from(rows.first.toColumnMap());

    // Erste jemals gespeicherte Prognose für dieses Fixture - der
    // unveränderliche Pre-Match-Snapshot, nicht ein späterer Rescan
    // (dieselbe "first predictions"-Semantik wie in `footballHistory()`
    // oben).
    final snapshotRows = await db.execute(
      Sql.named('''
        SELECT phase_two_scan_run_id, fixture_id, prediction_date, kickoff,
               model_version, market_key, market_label, model_probability,
               fair_odds, market_odds, assigned_units, data_quality,
               confidence, result_status, home_score, away_score,
               profit_units, settled_at, payload, created_at
        FROM football_analysis_history
        WHERE fixture_id = @id
        ORDER BY created_at ASC
        LIMIT 1
      '''),
      parameters: {'id': id},
    );

    final latestAnalysisRows = await db.execute(
      Sql.named('''
        SELECT model_version, data_quality, confidence, recommendation,
               analyzed_at,
               COALESCE(payload->>'analysisScope', 'public') AS analysis_scope,
               NULLIF(payload->>'collectionTier', '') AS collection_tier
        FROM analyses
        WHERE sport = 'football' AND match_id = @id
        ORDER BY analyzed_at DESC
        LIMIT 1
      '''),
      parameters: {'id': id},
    );

    match['analysisSnapshot'] = snapshotRows.isEmpty
        ? null
        : Map<String, Object?>.from(snapshotRows.first.toColumnMap());
    match['latestAnalysis'] = latestAnalysisRows.isEmpty
        ? null
        : Map<String, Object?>.from(latestAnalysisRows.first.toColumnMap());

    return match;
  }

  /// Aktualisiert ein Subset der fünf Pro-Match-Steuerflags. [flags] ist
  /// bereits keyed by DB-Spaltenname (siehe `matchFlagJsonToColumn` in
  /// `football_admin_logic.dart`) - diese Methode selbst validiert die
  /// Spaltennamen nicht mehr, das übernimmt der Aufrufer über die feste
  /// Allowlist dort, damit hier keine beliebigen Spaltennamen interpoliert
  /// werden können.
  ///
  /// Gibt die vorherigen Werte der geänderten Spalten zurück (für den
  /// Audit-Log-Diff), oder `null`, wenn das Match nicht existiert.
  Future<Map<String, Object?>?> updateFootballMatchFlags({
    required String id,
    required Map<String, bool> flags,
  }) async {
    if (flags.isEmpty) return null;
    const allowedColumns = {
      'visible',
      'analysis_enabled',
      'tip_enabled',
      'learning_enabled',
      'live_enabled',
    };
    if (flags.keys.any((column) => !allowedColumns.contains(column))) {
      throw ArgumentError('Ungültige Flag-Spalte.');
    }

    final db = await connection();
    final columns = flags.keys.toList();

    final previousRows = await db.execute(
      Sql.named('''
        SELECT ${columns.join(', ')} FROM football_matches WHERE id = @id
      '''),
      parameters: {'id': id},
    );
    if (previousRows.isEmpty) return null;
    final previous =
        Map<String, Object?>.from(previousRows.first.toColumnMap());

    final setClause = columns.map((column) => '$column = @$column').join(', ');
    await db.execute(
      Sql.named('''
        UPDATE football_matches
        SET $setClause, updated_at = NOW()
        WHERE id = @id
      '''),
      parameters: {'id': id, ...flags},
    );

    return previous;
  }

  static const Set<String> footballMatchStatusCodes = {
    'TBD',
    'NS',
    '1H',
    'HT',
    '2H',
    'ET',
    'BT',
    'P',
    'SUSP',
    'INT',
    'LIVE',
    'FT',
    'AET',
    'PEN',
    'PST',
    'CANC',
    'ABD',
    'AWD',
    'WO',
  };

  /// Manuelle Statusübersteuerung (z.B. ein abgesagtes Spiel, bevor der
  /// Provider das selbst meldet). Setzt `status_locked = TRUE`, wodurch der
  /// nächste automatische Sync (`upsertFootballMatchFromPayload`) diesen
  /// Status NICHT mehr überschreibt, bis ein Mitarbeiter die Sperre bewusst
  /// wieder aufhebt. Wirkt sofort auf alle Leseabfragen, die `m.status`
  /// verwenden (u.a. `/api/football/analyses/*`, an die die App sich hält) -
  /// keine separate "Override"-Spalte, die extra durchgereicht werden müsste.
  Future<Map<String, Object?>?> setFootballMatchStatusOverride({
    required String id,
    required String status,
    required String reason,
    int? employeeId,
  }) async {
    if (!footballMatchStatusCodes.contains(status)) {
      throw ArgumentError('Ungültiger Status-Code: $status');
    }
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE football_matches SET
          status = @status,
          status_locked = TRUE,
          status_lock_reason = @reason,
          status_locked_by_employee_id = @employee_id,
          status_locked_at = NOW(),
          updated_at = NOW()
        WHERE id = @id
        RETURNING id, status, status_locked, status_lock_reason
      '''),
      parameters: {
        'id': id,
        'status': status,
        'reason': reason,
        'employee_id': employeeId,
      },
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Hebt die manuelle Sperre wieder auf - der zuletzt gesetzte Status bleibt
  /// stehen, bis der nächste reguläre Provider-Sync ihn aktualisiert.
  Future<Map<String, Object?>?> clearFootballMatchStatusOverride(
    String id,
  ) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE football_matches SET
          status_locked = FALSE,
          updated_at = NOW()
        WHERE id = @id
        RETURNING id, status, status_locked
      '''),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Team-/Liga-Wappen-Inventar für `GET /api/admin/football/assets`:
  /// jede in den letzten [sinceDays] Tagen in `football_matches` gesehene
  /// Team- oder Liga-ID, links gejoined gegen den `football_assets`-Cache.
  /// Fehlt eine Zeile im Cache, kommt sie trotzdem mit `mime_type = NULL`
  /// zurück (MISSING) - der Aufrufer berechnet den Status über
  /// `computeAssetStatus()` in `football_admin_logic.dart`.
  /// Team-Katalog fürs Control Center (Section "Ligen/Teams
  /// zusammenlegen"): jedes Team, das jemals als Heim- oder Auswärtsteam in
  /// einem gespeicherten Match vorkam - das deckt praktisch jedes Team ab,
  /// sobald seine Liga mindestens einmal gescannt wurde. Kein Live-Aufruf
  /// beim Provider nötig, keine zusätzliche API-Quota.
  /// Section 10: Teams-Hauptseite braucht echte serverseitige Filter/
  /// Sortierung statt nur Suche+Pagination - jedes Team wird hier einmal
  /// mit Liga, Logo-Status, Datenabdeckung, Analysen/Tipps-Vorhandensein
  /// und Performance angereichert, damit Filter wie "Logo fehlt" oder
  /// "keine Analysen" echte Datensätze treffen statt nur die UI zu zeigen.
  Future<Map<String, Object?>> listFootballTeamsAdmin({
    String? search,
    String? leagueId,
    String? country,
    String? activeStatus,
    String? dataStatus,
    String? logoStatus,
    String? analysesStatus,
    String? tipsStatus,
    String sortBy = 'name',
    String sortDir = 'asc',
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await connection();

    const baseCte = '''
      WITH teams AS (
        SELECT home_team_id AS id, home_team_name AS name,
               home_logo AS logo, league_id, league_name, country,
               kickoff_utc
        FROM football_matches WHERE home_team_id <> ''
        UNION ALL
        SELECT away_team_id, away_team_name, away_logo, league_id,
               league_name, country, kickoff_utc
        FROM football_matches WHERE away_team_id <> ''
      ),
      latest AS (
        SELECT DISTINCT ON (id) id, name, logo, league_id, league_name,
               country
        FROM teams
        ORDER BY id, kickoff_utc DESC
      ),
      activity AS (
        SELECT id AS team_id, COUNT(*) AS stored_matches,
               MAX(kickoff_utc) AS last_kickoff
        FROM teams
        GROUP BY id
      ),
      team_fixtures AS (
        SELECT home_team_id AS team_id, id AS fixture_id
        FROM football_matches WHERE home_team_id <> ''
        UNION ALL
        SELECT away_team_id, id
        FROM football_matches WHERE away_team_id <> ''
      ),
      first_predictions AS (
        SELECT DISTINCT ON (prediction_date, fixture_id)
          fixture_id, market_key, result_status, assigned_units, profit_units
        FROM football_analysis_history
        ORDER BY prediction_date, fixture_id, created_at ASC
      ),
      team_predictions AS (
        SELECT tf.team_id, fp.fixture_id, fp.market_key, fp.result_status,
               fp.assigned_units, fp.profit_units
        FROM team_fixtures tf
        INNER JOIN first_predictions fp ON fp.fixture_id = tf.fixture_id
      ),
      predicted AS (
        SELECT team_id,
          COUNT(DISTINCT fixture_id) AS analyzed_matches,
          COUNT(DISTINCT fixture_id)
            FILTER (WHERE market_key <> '') AS tips_count,
          COUNT(*) FILTER (
            WHERE assigned_units > 0 AND result_status = 'won'
          ) AS won,
          COUNT(*) FILTER (
            WHERE assigned_units > 0 AND result_status = 'lost'
          ) AS lost,
          COALESCE(SUM(assigned_units) FILTER (WHERE assigned_units > 0), 0)
            AS staked_units,
          COALESCE(SUM(profit_units) FILTER (WHERE assigned_units > 0), 0)
            AS profit_units
        FROM team_predictions
        GROUP BY team_id
      ),
      combined AS (
        SELECT
          l.id, l.name, l.logo, l.league_id, l.league_name, l.country,
          COALESCE(a.stored_matches, 0) AS stored_matches,
          COALESCE(p.analyzed_matches, 0) AS analyzed_matches,
          COALESCE(p.tips_count, 0) AS tips_count,
          COALESCE(p.won, 0) AS won,
          COALESCE(p.lost, 0) AS lost,
          COALESCE(p.staked_units, 0) AS staked_units,
          COALESCE(p.profit_units, 0) AS profit_units,
          (l.logo <> '') AS has_logo,
          CASE
            WHEN COALESCE(a.stored_matches, 0) = 0 THEN 'missing'
            WHEN COALESCE(p.analyzed_matches, 0) = 0 THEN 'missing'
            WHEN p.analyzed_matches < a.stored_matches THEN 'partial'
            ELSE 'full'
          END AS data_status,
          CASE
            WHEN a.last_kickoff IS NOT NULL
              AND a.last_kickoff >= NOW() - INTERVAL '365 days'
            THEN 'active' ELSE 'inactive'
          END AS active_status,
          CASE WHEN COALESCE(p.won, 0) + COALESCE(p.lost, 0) = 0 THEN NULL
            ELSE p.won::double precision / (p.won + p.lost) * 100
          END AS hit_rate_percent,
          CASE WHEN COALESCE(p.staked_units, 0) = 0 THEN NULL
            ELSE p.profit_units / p.staked_units * 100
          END AS roi_percent,
          CASE WHEN COALESCE(a.stored_matches, 0) = 0 THEN NULL
            ELSE COALESCE(p.analyzed_matches, 0)::double precision
              / a.stored_matches * 100
          END AS coverage_percent
        FROM latest l
        LEFT JOIN activity a ON a.team_id = l.id
        LEFT JOIN predicted p ON p.team_id = l.id
      )
    ''';

    final conditions = <String>[];
    final parameters = <String, Object?>{};
    if (search != null && search.trim().isNotEmpty) {
      conditions.add('name ILIKE @search');
      parameters['search'] = '%${search.trim()}%';
    }
    if (leagueId != null && leagueId.trim().isNotEmpty) {
      conditions.add('league_id = @league_id');
      parameters['league_id'] = leagueId.trim();
    }
    if (country != null && country.trim().isNotEmpty) {
      conditions.add('country = @country');
      parameters['country'] = country.trim();
    }
    if (activeStatus == 'active' || activeStatus == 'inactive') {
      conditions.add('active_status = @active_status');
      parameters['active_status'] = activeStatus;
    }
    if (dataStatus == 'present') {
      conditions.add("data_status = 'full'");
    } else if (dataStatus == 'partial') {
      conditions.add("data_status = 'partial'");
    } else if (dataStatus == 'missing') {
      conditions.add("data_status = 'missing'");
    }
    if (logoStatus == 'present') {
      conditions.add('has_logo = TRUE');
    } else if (logoStatus == 'missing') {
      conditions.add('has_logo = FALSE');
    }
    if (analysesStatus == 'present') {
      conditions.add('analyzed_matches > 0');
    } else if (analysesStatus == 'missing') {
      conditions.add('analyzed_matches = 0');
    }
    if (tipsStatus == 'present') {
      conditions.add('tips_count > 0');
    } else if (tipsStatus == 'missing') {
      conditions.add('tips_count = 0');
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    const sortColumns = {
      'name': 'name',
      'league': 'league_name',
      'hitRate': 'hit_rate_percent',
      'roi': 'roi_percent',
      'tips': 'tips_count',
      'coverage': 'coverage_percent',
    };
    final sortColumn = sortColumns[sortBy] ?? 'name';
    final direction = sortDir == 'desc' ? 'DESC' : 'ASC';
    final orderBy = 'ORDER BY $sortColumn $direction NULLS LAST, name ASC';

    final rows = await db.execute(
      Sql.named('''
        $baseCte
        SELECT * FROM combined
        $where
        $orderBy
        LIMIT @limit OFFSET @offset
      '''),
      parameters: {
        ...parameters,
        'limit': limit.clamp(1, 200),
        'offset': offset.clamp(0, 1 << 30),
      },
    );

    final countRows = await db.execute(
      Sql.named('''
        $baseCte
        SELECT COUNT(*) AS total FROM combined
        $where
      '''),
      parameters: parameters,
    );
    final total = int.tryParse(
          countRows.first.toColumnMap()['total']?.toString() ?? '',
        ) ??
        0;

    return {
      'teams':
          rows.map((r) => Map<String, Object?>.from(r.toColumnMap())).toList(),
      'total': total,
      'limit': limit,
      'offset': offset,
    };
  }

  Future<Map<String, Object?>?> footballTeamDetail(String teamId) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        WITH teams AS (
          SELECT home_team_id AS id, home_team_name AS name,
                 home_logo AS logo, league_id, league_name, country,
                 kickoff_utc
          FROM football_matches WHERE home_team_id = @id
          UNION ALL
          SELECT away_team_id, away_team_name, away_logo, league_id,
                 league_name, country, kickoff_utc
          FROM football_matches WHERE away_team_id = @id
        )
        SELECT DISTINCT ON (id) id, name, logo, league_id, league_name, country
        FROM teams
        ORDER BY id, kickoff_utc DESC
      '''),
      parameters: {'id': teamId},
    );
    if (rows.isEmpty) return null;
    return Map<String, Object?>.from(rows.first.toColumnMap());
  }

  /// "Teams"-Tab im Liga-Analytics-Profil: alle Teams dieser Liga mit
  /// gespeicherten/analysierten Spielen, PHÖNIX-Tipps und Performance -
  /// reine Wiederverwendung derselben Trefferquote-/ROI-Formel wie
  /// [footballEntityPerformance] (Section 24), nicht neu erfunden.
  Future<List<Map<String, Object?>>> footballLeagueTeams(
    String leagueId,
  ) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        WITH team_fixtures AS (
          SELECT home_team_id AS team_id, id AS fixture_id
          FROM football_matches
          WHERE league_id = @league_id AND home_team_id <> ''
          UNION ALL
          SELECT away_team_id, id
          FROM football_matches
          WHERE league_id = @league_id AND away_team_id <> ''
        ),
        teams AS (
          SELECT DISTINCT ON (id) id, name, logo
          FROM (
            SELECT home_team_id AS id, home_team_name AS name,
                   home_logo AS logo, kickoff_utc
            FROM football_matches
            WHERE league_id = @league_id AND home_team_id <> ''
            UNION ALL
            SELECT away_team_id, away_team_name, away_logo, kickoff_utc
            FROM football_matches
            WHERE league_id = @league_id AND away_team_id <> ''
          ) t
          ORDER BY id, kickoff_utc DESC
        ),
        stored AS (
          SELECT team_id, COUNT(DISTINCT fixture_id) AS stored_matches
          FROM team_fixtures
          GROUP BY team_id
        ),
        first_predictions AS (
          SELECT DISTINCT ON (prediction_date, fixture_id)
            fixture_id, market_key, result_status, assigned_units,
            profit_units, data_quality
          FROM football_analysis_history
          ORDER BY prediction_date, fixture_id, created_at ASC
        ),
        team_predictions AS (
          SELECT tf.team_id, fp.fixture_id, fp.market_key, fp.result_status,
                 fp.assigned_units, fp.profit_units, fp.data_quality
          FROM team_fixtures tf
          INNER JOIN first_predictions fp ON fp.fixture_id = tf.fixture_id
        ),
        predicted AS (
          SELECT
            team_id,
            COUNT(DISTINCT fixture_id) AS analyzed_matches,
            COUNT(DISTINCT fixture_id)
              FILTER (WHERE market_key IS NOT NULL) AS tips_count,
            COUNT(*) FILTER (
              WHERE assigned_units > 0 AND result_status = 'won'
            ) AS won,
            COUNT(*) FILTER (
              WHERE assigned_units > 0 AND result_status = 'lost'
            ) AS lost,
            SUM(assigned_units) FILTER (WHERE assigned_units > 0) AS staked_units,
            SUM(profit_units) FILTER (WHERE assigned_units > 0) AS profit_units,
            ROUND(AVG(data_quality))::INTEGER AS avg_data_quality
          FROM team_predictions
          GROUP BY team_id
        )
        SELECT
          t.id, t.name, t.logo,
          COALESCE(s.stored_matches, 0) AS stored_matches,
          COALESCE(p.analyzed_matches, 0) AS analyzed_matches,
          COALESCE(p.tips_count, 0) AS tips_count,
          COALESCE(p.won, 0) AS won,
          COALESCE(p.lost, 0) AS lost,
          COALESCE(p.staked_units, 0) AS staked_units,
          COALESCE(p.profit_units, 0) AS profit_units,
          p.avg_data_quality
        FROM teams t
        LEFT JOIN stored s ON s.team_id = t.id
        LEFT JOIN predicted p ON p.team_id = t.id
        ORDER BY t.name
      '''),
      parameters: {'league_id': leagueId},
    );

    double? asDouble(Object? value) =>
        value == null ? null : double.tryParse(value.toString());

    return rows.map((row) {
      final map = Map<String, Object?>.from(row.toColumnMap());
      final won = int.tryParse(map['won']?.toString() ?? '') ?? 0;
      final lost = int.tryParse(map['lost']?.toString() ?? '') ?? 0;
      final staked = asDouble(map['staked_units']) ?? 0;
      final profit = asDouble(map['profit_units']) ?? 0;
      map['hitRatePercent'] =
          (won + lost) == 0 ? null : won / (won + lost) * 100;
      map['roiPercent'] = staked == 0 ? null : profit / staked * 100;
      return map;
    }).toList(growable: false);
  }

  Future<List<Map<String, Object?>>> footballAssetInventory({
    int sinceDays = 180,
  }) async {
    final db = await connection();
    final rows = await db.execute(
      Sql.named('''
        WITH recent_entities AS (
          SELECT DISTINCT home_team_id AS entity_id,
                 home_team_name AS entity_name, 'team' AS entity_type
          FROM football_matches
          WHERE kickoff_utc >= NOW() - make_interval(days => @since_days)
            AND home_team_id <> ''
          UNION
          SELECT DISTINCT away_team_id, away_team_name, 'team'
          FROM football_matches
          WHERE kickoff_utc >= NOW() - make_interval(days => @since_days)
            AND away_team_id <> ''
          UNION
          SELECT DISTINCT league_id, league_name, 'league'
          FROM football_matches
          WHERE kickoff_utc >= NOW() - make_interval(days => @since_days)
            AND league_id <> ''
        )
        SELECT e.entity_type, e.entity_id, e.entity_name,
               a.mime_type, a.updated_at,
               (a.content IS NOT NULL AND length(a.content) > 0) AS has_bytes
        FROM recent_entities e
        LEFT JOIN football_assets a
          ON a.asset_type = e.entity_type AND a.asset_id = e.entity_id
        ORDER BY e.entity_type, e.entity_name
      '''),
      parameters: {'since_days': sinceDays},
    );
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Rein lesende Datenqualitäts-Sicht je Match für einen Tag
  /// (`GET /api/admin/football/data-quality`) - eine Ergänzung zu
  /// `footballWhitelistCoverage()` (dort: aggregiert je Liga), hier: einzeln
  /// je Match, sortiert nach schlechtester Qualität zuerst. Nutzt
  /// ausschließlich real gespeicherte Spalten (`analyses.data_quality`,
  /// `analyses.confidence`) - keine neu erfundenen Scores.
  Future<List<Map<String, Object?>>> footballDataQualityRows({
    required DateTime date,
    int limit = 200,
  }) async {
    final db = await connection();
    final day = date.toUtc().toIso8601String().substring(0, 10);
    final rows = await db.execute(
      Sql.named('''
        SELECT
          m.id, m.kickoff_utc, m.league_id, m.league_name,
          m.home_team_name, m.away_team_name, m.status,
          a.data_quality, a.confidence, a.model_version, a.analyzed_at,
          (a.match_id IS NOT NULL) AS has_analysis
        FROM football_matches m
        LEFT JOIN LATERAL (
          SELECT match_id, data_quality, confidence, model_version, analyzed_at
          FROM analyses
          WHERE sport = 'football' AND match_id = m.id
          ORDER BY analyzed_at DESC
          LIMIT 1
        ) a ON TRUE
        WHERE m.kickoff_utc::date = CAST(@day AS DATE)
        ORDER BY COALESCE(a.data_quality, -1) ASC, m.kickoff_utc ASC
        LIMIT @limit
      '''),
      parameters: {'day': day, 'limit': limit.clamp(1, 500)},
    );
    return rows
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  // -- Control Center /overview -----------------------------------------

  Future<List<Map<String, Object?>>> apiSportsDailyUsageToday() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT api_name, usage_date::text AS usage_date, requests, updated_at
      FROM api_sports_daily_usage
      WHERE usage_date = CURRENT_DATE
      ORDER BY api_name ASC
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Letzte [days] Tage (inkl. heute) je `api_name`, neueste zuerst. Für das
  /// Control-Center-API-Usage-Panel - `apiSportsDailyUsageToday` bleibt für
  /// den bestehenden `/overview`-Aufruf unverändert.
  Future<List<Map<String, Object?>>> apiSportsDailyUsageHistory({
    int days = 14,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT api_name, usage_date::text AS usage_date, requests, updated_at
        FROM api_sports_daily_usage
        WHERE usage_date >= CURRENT_DATE - (@days - 1)
        ORDER BY usage_date DESC, api_name ASC
      '''),
      parameters: {'days': days.clamp(1, 90)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<Map<String, int>> footballLeagueManualStatusCounts() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT manual_status, COUNT(*) FROM football_leagues
      GROUP BY manual_status
    ''');
    return {
      for (final row in result) row[0].toString(): (row[1] as int?) ?? 0,
    };
  }

  /// Section 5 (Overview-Warnbereich "fehlende Assets") - nur Whitelist-
  /// Ligen zählen, weil nur die tatsächlich in der App sichtbar sind (siehe
  /// dieselbe Einschränkung bei den Wappen & Assets-Standardfiltern).
  Future<int> countWhitelistedLeaguesMissingLogo() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT COUNT(*) FROM football_leagues l
      WHERE l.manual_status = 'whitelist'
        AND NOT EXISTS (
          SELECT 1 FROM football_assets fa
          WHERE fa.asset_type = 'league' AND fa.asset_id = l.league_id
        )
    ''');
    return (result.first[0] as int?) ?? 0;
  }

  Future<int> countPendingFootballDailyPipelineJobs() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT COUNT(*) FROM football_daily_pipeline_jobs
      WHERE status NOT IN ('completed', 'failed')
    ''');
    return (result.first[0] as int?) ?? 0;
  }

  /// Neueste Daily-Pipeline-Läufe, neueste zuerst - fürs Control-Center-
  /// Jobs-Panel. Mirrors `recentFootballMatchSettlementJobs` (das per-Typ
  /// bereits existierte); für diesen Job-Typ gab es bisher nur die
  /// Einzelabfrage per ID (`/api/admin/football/daily-scan/<jobId>`).
  Future<List<Map<String, Object?>>> recentFootballDailyPipelineJobs({
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          id, scan_date::text AS scan_date, status, current_step,
          phase_one_scan_run_id, phase_two_scan_run_id, requested_limit,
          minimum_data_quality, simulations, processed, published, error,
          created_at::text AS created_at,
          completed_at::text AS completed_at
        FROM football_daily_pipeline_jobs
        ORDER BY id DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit.clamp(1, 100)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  // -- Control Center /app-control -----------------------------------------

  Future<Map<String, Object?>> appControlStatus() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT status, message, updated_at::text AS updated_at, updated_by,
        maintenance_until::text AS maintenance_until
      FROM app_control_state
      WHERE id = 1
    ''');
    if (result.isEmpty) {
      return {
        'status': 'ACTIVE',
        'message': null,
        'updatedAt': null,
        'updatedBy': null,
        'maintenance_until': null,
      };
    }
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>> setAppControlStatus({
    required String status,
    String? message,
    required String updatedBy,
    Object? maintenanceUntil = unsetSentinel,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE app_control_state SET
          status = @status,
          message = @message,
          updated_at = NOW(),
          updated_by = @updated_by,
          maintenance_until = CASE WHEN @maintenance_until_set THEN @maintenance_until ELSE maintenance_until END
        WHERE id = 1
        RETURNING status, message, updated_at::text AS updated_at, updated_by,
          maintenance_until::text AS maintenance_until
      '''),
      parameters: {
        'status': status,
        'message': message,
        'updated_by': updatedBy,
        'maintenance_until_set': !identical(maintenanceUntil, unsetSentinel),
        'maintenance_until': identical(maintenanceUntil, unsetSentinel)
            ? null
            : maintenanceUntil,
      },
    );
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<int> countPendingFootballMatchSettlementJobs() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT COUNT(*) FROM football_match_settlement_jobs
      WHERE status NOT IN ('completed', 'failed')
    ''');
    return (result.first[0] as int?) ?? 0;
  }

  /// Section 5 (Overview "Pending Jobs" muss zwischen aktiv, abgeschlossen
  /// und fehlgeschlagen unterscheiden - beide Job-Tabellen haben laut ihrem
  /// `CHECK (status IN ('running','completed','failed'))` keinen eigenen
  /// "wartend/queued"-Status, daher wird hier ehrlich nur unterschieden, was
  /// die Daten tatsächlich hergeben: läuft gerade / kürzlich fehlgeschlagen
  /// (24h) / kürzlich abgeschlossen (24h) - keine erfundene Warteschlange.
  Future<Map<String, Object?>> jobStatusBreakdown() async {
    final db = await connection();

    Future<Map<String, Object?>> countsFor(String table) async {
      final result = await db.execute('''
        SELECT
          COUNT(*) FILTER (WHERE status = 'running') AS running,
          COUNT(*) FILTER (WHERE status = 'failed' AND created_at >= NOW() - INTERVAL '24 hours') AS failed24h,
          COUNT(*) FILTER (WHERE status = 'completed' AND created_at >= NOW() - INTERVAL '24 hours') AS completed24h
        FROM $table
      ''');
      final row = result.first.toColumnMap();
      int n(String key) => int.tryParse(row[key]?.toString() ?? '') ?? 0;
      return {
        'running': n('running'),
        'failed24h': n('failed24h'),
        'completed24h': n('completed24h')
      };
    }

    return {
      'dailyPipeline': await countsFor('football_daily_pipeline_jobs'),
      'settlement': await countsFor('football_match_settlement_jobs'),
    };
  }

  /// Echte Tageszahlen für das Control-Center-Overview (Section 13). Nutzt
  /// dieselbe "letzte Analyse pro Fixture"-Logik wie [preparedFootballAnalyses]
  /// (DISTINCT ON ... ORDER BY analyzed_at DESC), damit die Zahlen hier nie
  /// von dem abweichen, was App und /api/football/analyses/today anzeigen.
  Future<Map<String, Object?>> footballDailyOverviewStats({
    required DateTime day,
  }) async {
    final db = await connection();
    final dayOnly = _dateOnly(day);

    final result = await db.execute(
      Sql.named('''
        WITH todays_matches AS (
          SELECT id FROM football_matches
          WHERE (kickoff_utc AT TIME ZONE 'Europe/Berlin')::date =
                CAST(@day AS DATE)
        ),
        latest_analysis AS (
          SELECT DISTINCT ON (a.match_id)
            a.match_id, a.analyzed_at, a.data_quality, a.payload
          FROM analyses a
          INNER JOIN todays_matches m ON m.id = a.match_id
          WHERE a.sport = 'football'
          ORDER BY a.match_id, a.analyzed_at DESC
        )
        SELECT
          (SELECT COUNT(*) FROM todays_matches) AS scheduled_matches,
          (
            SELECT COUNT(*) FROM analyses a
            INNER JOIN todays_matches m ON m.id = a.match_id
            WHERE a.sport = 'football'
              AND (a.analyzed_at AT TIME ZONE 'Europe/Berlin')::date =
                  CAST(@day AS DATE)
          ) AS new_analyses_today,
          (
            SELECT COUNT(*) FROM latest_analysis
            WHERE COALESCE(payload->>'recommendation', '') NOT IN ('', 'Keine Wette')
              AND COALESCE((payload->>'simulationCount')::int, 0) > 0
              AND COALESCE(data_quality, 0) > 0
          ) AS tips_today,
          (
            SELECT COUNT(*) FROM latest_analysis
            WHERE COALESCE(data_quality, 0) > 0 AND COALESCE(data_quality, 0) < 50
          ) AS low_data_quality,
          (
            SELECT COUNT(*) FROM latest_analysis
            WHERE COALESCE(
              (payload #>> '{selection,value,isValueTip}')::boolean, false
            ) = true
          ) AS value_signals_today,
          (
            SELECT COUNT(*) FROM football_daily_pipeline_jobs
            WHERE status NOT IN ('completed', 'failed')
              AND scan_date = CAST(@day AS DATE)
          ) AS running_jobs,
          (
            SELECT COUNT(*) FROM football_daily_pipeline_jobs
            WHERE status = 'failed'
              AND scan_date = CAST(@day AS DATE)
          ) AS failed_jobs
      '''),
      parameters: {'day': dayOnly},
    );

    final row = result.isEmpty
        ? const <String, Object?>{}
        : Map<String, Object?>.from(result.first.toColumnMap());

    final scheduled = (row['scheduled_matches'] as int?) ?? 0;
    final tipsToday = (row['tips_today'] as int?) ?? 0;

    return {
      'scheduledMatches': scheduled,
      'newAnalysesToday': (row['new_analyses_today'] as int?) ?? 0,
      'tipsToday': tipsToday,
      'matchesWithoutRecommendation': (scheduled - tipsToday).clamp(0, 1 << 30),
      'analysisRunning': (row['running_jobs'] as int?) ?? 0,
      'analysisFailed': (row['failed_jobs'] as int?) ?? 0,
      'lowDataQuality': (row['low_data_quality'] as int?) ?? 0,
      'newValueSignals': (row['value_signals_today'] as int?) ?? 0,
      'openSettlementJobs': await countPendingFootballMatchSettlementJobs(),
    };
  }

  // -- Control Center /search ---------------------------------------------

  Future<List<Map<String, Object?>>> searchFootballLeaguesByText(
    String query, {
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT league_id, league_name FROM football_leagues
        WHERE league_name ILIKE @pattern OR league_id ILIKE @pattern
        ORDER BY league_name ASC
        LIMIT @limit
      '''),
      parameters: {'pattern': '%$query%', 'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<List<Map<String, Object?>>> searchFootballTeamsByText(
    String query, {
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        WITH teams AS (
          SELECT home_team_id AS team_id, home_team_name AS team_name,
                 home_logo AS logo, kickoff_utc
          FROM football_matches
          UNION ALL
          SELECT away_team_id AS team_id, away_team_name AS team_name,
                 away_logo AS logo, kickoff_utc
          FROM football_matches
        ), latest AS (
          SELECT DISTINCT ON (team_id) team_id, team_name, logo
          FROM teams
          WHERE team_name ILIKE @pattern OR team_id ILIKE @pattern
          ORDER BY team_id, kickoff_utc DESC
        )
        SELECT team_id, team_name, logo
        FROM latest
        ORDER BY team_name ASC
        LIMIT @limit
      '''),
      parameters: {'pattern': '%$query%', 'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<List<Map<String, Object?>>> searchFootballMatchesByText(
    String query, {
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT id, home_team_name, away_team_name, league_name, kickoff_utc
        FROM football_matches
        WHERE id ILIKE @pattern
           OR home_team_name ILIKE @pattern
           OR away_team_name ILIKE @pattern
           OR league_name ILIKE @pattern
        ORDER BY kickoff_utc DESC
        LIMIT @limit
      '''),
      parameters: {'pattern': '%$query%', 'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<List<Map<String, Object?>>> searchModelVersionsByText(
    String query, {
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT id, readable_version, status FROM phoenix_model_versions
        WHERE readable_version ILIKE @pattern OR status ILIKE @pattern
        ORDER BY created_at DESC
        LIMIT @limit
      '''),
      parameters: {'pattern': '%$query%', 'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<List<Map<String, Object?>>> searchLearningRunsByText(
    String query, {
    int limit = 20,
  }) async {
    final numericId = int.tryParse(query.trim());
    if (numericId == null) return const <Map<String, Object?>>[];

    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT id, status, started_at FROM phoenix_learning_runs
        WHERE id = @id
        ORDER BY started_at DESC
        LIMIT @limit
      '''),
      parameters: {'id': numericId, 'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<List<Map<String, Object?>>> searchNewsArticlesByText(
    String query, {
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT id, title_de FROM news_articles
        WHERE title_de ILIKE @pattern
        ORDER BY published_at DESC
        LIMIT @limit
      '''),
      parameters: {'pattern': '%$query%', 'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<List<Map<String, Object?>>> searchAdminEmployeesByText(
    String query, {
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT id, name, login, email FROM admin_employees
        WHERE name ILIKE @pattern OR login ILIKE @pattern OR email ILIKE @pattern
        ORDER BY name ASC
        LIMIT @limit
      '''),
      parameters: {'pattern': '%$query%', 'limit': limit},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  // -- Control Center /devices (Phase 4, installation-based) --------------

  Future<List<Map<String, Object?>>> listPushDevices({
    int limit = 100,
    int offset = 0,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          d.installation_id, d.platform, d.locale, d.enabled, d.news_enabled,
          d.created_at::text AS created_at,
          d.updated_at::text AS updated_at,
          d.last_seen_at::text AS last_seen_at,
          (SELECT COUNT(*) FROM football_favorites f WHERE f.installation_id = d.installation_id) AS favorite_count,
          (SELECT COUNT(*) FROM support_tickets t WHERE t.installation_id = d.installation_id) AS ticket_count
        FROM push_devices d
        ORDER BY d.last_seen_at DESC
        LIMIT @limit OFFSET @offset
      '''),
      parameters: {
        'limit': limit.clamp(1, 500),
        'offset': offset.clamp(0, 1000000)
      },
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<Map<String, Object?>?> pushDeviceDetail(String installationId) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT
          installation_id, platform, locale, enabled, news_enabled,
          created_at::text AS created_at,
          updated_at::text AS updated_at,
          last_seen_at::text AS last_seen_at
        FROM push_devices
        WHERE installation_id = @id
      '''),
      parameters: {'id': installationId},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<int> countPushDevices() async {
    final db = await connection();
    final result = await db.execute('SELECT COUNT(*) FROM push_devices');
    return (result.first[0] as int?) ?? 0;
  }

  // -- Control Center /support (Phase 4, installation-based) ---------------

  Future<Map<String, Object?>> createSupportTicket({
    required String installationId,
    required String category,
    required String subject,
    required String message,
    String? appVersion,
    String? platform,
    String? osVersion,
    String? deviceModel,
    String? matchId,
    String? screen,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO support_tickets (
          installation_id, category, subject, message,
          app_version, platform, os_version, device_model, match_id, screen
        ) VALUES (
          @installation_id, @category, @subject, @message,
          @app_version, @platform, @os_version, @device_model, @match_id, @screen
        )
        RETURNING *
      '''),
      parameters: {
        'installation_id': installationId,
        'category': category,
        'subject': subject,
        'message': message,
        'app_version': appVersion,
        'platform': platform,
        'os_version': osVersion,
        'device_model': deviceModel,
        'match_id': matchId,
        'screen': screen,
      },
    );
    return _supportTicketRow(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> supportTicketsForInstallation(
    String installationId, {
    int limit = 50,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM support_tickets
        WHERE installation_id = @installation_id
        ORDER BY created_at DESC
        LIMIT @limit
      '''),
      parameters: {
        'installation_id': installationId,
        'limit': limit.clamp(1, 200)
      },
    );
    return result.map((row) => _supportTicketRow(row.toColumnMap())).toList();
  }

  Future<Map<String, Object?>?> supportTicket(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT * FROM support_tickets WHERE id = @id'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return _supportTicketRow(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> listSupportTickets({
    String? status,
    String? category,
    int? assignedEmployeeId,
    int limit = 100,
  }) async {
    final db = await connection();
    final conditions = <String>[];
    final parameters = <String, Object?>{'limit': limit.clamp(1, 500)};

    if (status != null && status.trim().isNotEmpty) {
      conditions.add('status = @status');
      parameters['status'] = status;
    }
    if (category != null && category.trim().isNotEmpty) {
      conditions.add('category = @category');
      parameters['category'] = category;
    }
    if (assignedEmployeeId != null) {
      conditions.add('assigned_employee_id = @assigned_employee_id');
      parameters['assigned_employee_id'] = assignedEmployeeId;
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final result = await db.execute(
      Sql.named('''
        SELECT * FROM support_tickets
        $where
        ORDER BY created_at DESC
        LIMIT @limit
      '''),
      parameters: parameters,
    );
    return result.map((row) => _supportTicketRow(row.toColumnMap())).toList();
  }

  Future<Map<String, Object?>?> updateSupportTicket({
    required int id,
    String? status,
    String? priority,
    String? category,
    int? assignedEmployeeId,
    bool clearAssignedEmployee = false,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE support_tickets SET
          status = COALESCE(@status, status),
          priority = COALESCE(@priority, priority),
          category = COALESCE(@category, category),
          assigned_employee_id = CASE
            WHEN @clear_assigned THEN NULL
            ELSE COALESCE(@assigned_employee_id, assigned_employee_id)
          END,
          updated_at = NOW()
        WHERE id = @id
        RETURNING *
      '''),
      parameters: {
        'id': id,
        'status': status,
        'priority': priority,
        'category': category,
        'assigned_employee_id': assignedEmployeeId,
        'clear_assigned': clearAssignedEmployee,
      },
    );
    if (result.isEmpty) return null;
    return _supportTicketRow(result.first.toColumnMap());
  }

  Future<Map<String, Object?>> addSupportTicketMessage({
    required int ticketId,
    required String authorType,
    int? employeeId,
    required String message,
    bool internalNote = false,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO support_ticket_messages (
          ticket_id, author_type, employee_id, message, internal_note
        ) VALUES (@ticket_id, @author_type, @employee_id, @message, @internal_note)
        RETURNING id, ticket_id, author_type, employee_id, message, internal_note,
          created_at::text AS created_at
      '''),
      parameters: {
        'ticket_id': ticketId,
        'author_type': authorType,
        'employee_id': employeeId,
        'message': message,
        'internal_note': internalNote,
      },
    );
    await db.execute(
      Sql.named('UPDATE support_tickets SET updated_at = NOW() WHERE id = @id'),
      parameters: {'id': ticketId},
    );
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> supportTicketMessages(
    int ticketId, {
    bool includeInternal = true,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT id, ticket_id, author_type, employee_id, message, internal_note,
          created_at::text AS created_at
        FROM support_ticket_messages
        WHERE ticket_id = @ticket_id ${includeInternal ? '' : 'AND internal_note = FALSE'}
        ORDER BY created_at ASC
      '''),
      parameters: {'ticket_id': ticketId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Map<String, Object?> _supportTicketRow(Map<String, dynamic> row) {
    final map = Map<String, Object?>.from(row);
    // created_at/updated_at come back as DateTime from `SELECT *`; normalize
    // to text like the rest of this file's read paths (RETURNING * above
    // can't cast inline the way a plain SELECT can).
    if (map['created_at'] is DateTime) {
      map['created_at'] =
          (map['created_at'] as DateTime).toUtc().toIso8601String();
    }
    if (map['updated_at'] is DateTime) {
      map['updated_at'] =
          (map['updated_at'] as DateTime).toUtc().toIso8601String();
    }
    return map;
  }

  // -- Control Center /news (Phase 5, manuell verfasst) -------------------

  Future<Map<String, Object?>> createEditorialArticle({
    required String title,
    String summary = '',
    String body = '',
    String category = 'allgemein',
    String? imageUrl,
    int? authorEmployeeId,
    bool homepageFeature = false,
    bool breaking = false,
    bool sendPush = false,
    DateTime? scheduledAt,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO phoenix_editorial_articles (
          title, summary, body, category, image_url, author_employee_id,
          homepage_feature, breaking, send_push, scheduled_at,
          status
        ) VALUES (
          @title, @summary, @body, @category, @image_url, @author_employee_id,
          @homepage_feature, @breaking, @send_push, @scheduled_at,
          CASE WHEN @scheduled_at IS NULL THEN 'DRAFT' ELSE 'SCHEDULED' END
        )
        RETURNING *
      '''),
      parameters: {
        'title': title,
        'summary': summary,
        'body': body,
        'category': category,
        'image_url': imageUrl,
        'author_employee_id': authorEmployeeId,
        'homepage_feature': homepageFeature,
        'breaking': breaking,
        'send_push': sendPush,
        'scheduled_at': scheduledAt,
      },
    );
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> listEditorialArticles({
    String? status,
    String? category,
    int limit = 100,
  }) async {
    final db = await connection();
    final conditions = <String>[];
    final parameters = <String, Object?>{'limit': limit.clamp(1, 500)};
    if (status != null && status.trim().isNotEmpty) {
      conditions.add('status = @status');
      parameters['status'] = status;
    }
    if (category != null && category.trim().isNotEmpty) {
      conditions.add('category = @category');
      parameters['category'] = category;
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_editorial_articles
        $where
        ORDER BY created_at DESC
        LIMIT @limit
      '''),
      parameters: parameters,
    );
    return result.map((row) => _dateSafeRow(row.toColumnMap())).toList();
  }

  Future<Map<String, Object?>?> editorialArticle(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT * FROM phoenix_editorial_articles WHERE id = @id'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> updateEditorialArticle({
    required int id,
    String? title,
    String? summary,
    String? body,
    String? category,
    Object? imageUrl = unsetSentinel,
    String? status,
    bool? homepageFeature,
    bool? breaking,
    bool? sendPush,
    Object? scheduledAt = unsetSentinel,
    DateTime? publishedAt,
    bool pushSent = false,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE phoenix_editorial_articles SET
          title = COALESCE(@title, title),
          summary = COALESCE(@summary, summary),
          body = COALESCE(@body, body),
          category = COALESCE(@category, category),
          image_url = CASE WHEN @image_url_set THEN @image_url ELSE image_url END,
          status = COALESCE(@status, status),
          homepage_feature = COALESCE(@homepage_feature, homepage_feature),
          breaking = COALESCE(@breaking, breaking),
          send_push = COALESCE(@send_push, send_push),
          scheduled_at = CASE WHEN @scheduled_at_set THEN @scheduled_at ELSE scheduled_at END,
          published_at = COALESCE(@published_at, published_at),
          push_sent_at = CASE WHEN @push_sent THEN NOW() ELSE push_sent_at END,
          updated_at = NOW()
        WHERE id = @id
        RETURNING *
      '''),
      parameters: {
        'id': id,
        'title': title,
        'summary': summary,
        'body': body,
        'category': category,
        'image_url_set': !identical(imageUrl, unsetSentinel),
        'image_url': identical(imageUrl, unsetSentinel) ? null : imageUrl,
        'status': status,
        'homepage_feature': homepageFeature,
        'breaking': breaking,
        'send_push': sendPush,
        'scheduled_at_set': !identical(scheduledAt, unsetSentinel),
        'scheduled_at':
            identical(scheduledAt, unsetSentinel) ? null : scheduledAt,
        'published_at': publishedAt,
        'push_sent': pushSent,
      },
    );
    if (result.isEmpty) return null;
    return _dateSafeRow(result.first.toColumnMap());
  }

  /// Für den öffentlichen Feed: veröffentlicht ODER geplant mit bereits
  /// erreichtem Zeitpunkt. Kein Cron nötig, der Status selbst bleibt bis zu
  /// einer manuellen/erneuten Prüfung "SCHEDULED", nur die Sichtbarkeit wird
  /// hier lazy berechnet.
  Future<List<Map<String, Object?>>> publicEditorialArticles(
      {int limit = 50}) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM phoenix_editorial_articles
        WHERE status = 'PUBLISHED'
           OR (status = 'SCHEDULED' AND scheduled_at <= NOW())
        ORDER BY breaking DESC, homepage_feature DESC, COALESCE(published_at, scheduled_at, created_at) DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit.clamp(1, 200)},
    );
    return result.map((row) => _dateSafeRow(row.toColumnMap())).toList();
  }

  // -- Control Center /faq (Phase 5) ---------------------------------------

  Future<Map<String, Object?>> createFaqArticle({
    required String title,
    String body = '',
    String category = 'allgemein',
    int position = 0,
    int? authorEmployeeId,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO phoenix_faq_articles (title, body, category, position, author_employee_id)
        VALUES (@title, @body, @category, @position, @author_employee_id)
        RETURNING *
      '''),
      parameters: {
        'title': title,
        'body': body,
        'category': category,
        'position': position,
        'author_employee_id': authorEmployeeId,
      },
    );
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> listFaqArticles(
      {String? status, String? category}) async {
    final db = await connection();
    final conditions = <String>[];
    final parameters = <String, Object?>{};
    if (status != null && status.trim().isNotEmpty) {
      conditions.add('status = @status');
      parameters['status'] = status;
    }
    if (category != null && category.trim().isNotEmpty) {
      conditions.add('category = @category');
      parameters['category'] = category;
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final result = await db.execute(
      Sql.named(
          'SELECT * FROM phoenix_faq_articles $where ORDER BY category, position, id'),
      parameters: parameters,
    );
    return result.map((row) => _dateSafeRow(row.toColumnMap())).toList();
  }

  Future<Map<String, Object?>?> faqArticle(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT * FROM phoenix_faq_articles WHERE id = @id'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> updateFaqArticle({
    required int id,
    String? title,
    String? body,
    String? category,
    int? position,
    String? status,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE phoenix_faq_articles SET
          title = COALESCE(@title, title),
          body = COALESCE(@body, body),
          category = COALESCE(@category, category),
          position = COALESCE(@position, position),
          status = COALESCE(@status, status),
          updated_at = NOW()
        WHERE id = @id
        RETURNING *
      '''),
      parameters: {
        'id': id,
        'title': title,
        'body': body,
        'category': category,
        'position': position,
        'status': status,
      },
    );
    if (result.isEmpty) return null;
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> publicFaqArticles() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT * FROM phoenix_faq_articles
      WHERE status = 'PUBLISHED'
      ORDER BY category, position, id
    ''');
    return result.map((row) => _dateSafeRow(row.toColumnMap())).toList();
  }

  // -- Control Center /advertising (Phase 5) -------------------------------

  Future<Map<String, Object?>> createAdCampaign({
    required String name,
    required String slot,
    required String imageUrl,
    required String linkUrl,
    bool active = true,
    DateTime? startDate,
    DateTime? endDate,
    String? targetCountry,
    String targetAudience = 'ALL',
    int? createdByEmployeeId,
    double? budgetAmount,
    int? frequencyCapPerDay,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO ad_campaigns (
          name, slot, image_url, link_url, active, start_date, end_date,
          target_country, target_audience, created_by_employee_id,
          budget_amount, frequency_cap_per_day
        ) VALUES (
          @name, @slot, @image_url, @link_url, @active, @start_date, @end_date,
          @target_country, @target_audience, @created_by_employee_id,
          @budget_amount, @frequency_cap_per_day
        )
        RETURNING *
      '''),
      parameters: {
        'name': name,
        'slot': slot,
        'image_url': imageUrl,
        'link_url': linkUrl,
        'active': active,
        'start_date': startDate,
        'end_date': endDate,
        'target_country': targetCountry,
        'target_audience': targetAudience,
        'created_by_employee_id': createdByEmployeeId,
        'budget_amount': budgetAmount,
        'frequency_cap_per_day': frequencyCapPerDay,
      },
    );
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<List<Map<String, Object?>>> listAdCampaigns(
      {String? slot, bool? active}) async {
    final db = await connection();
    final conditions = <String>[];
    final parameters = <String, Object?>{};
    if (slot != null && slot.trim().isNotEmpty) {
      conditions.add('slot = @slot');
      parameters['slot'] = slot;
    }
    if (active != null) {
      conditions.add('active = @active');
      parameters['active'] = active;
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final result = await db.execute(
      Sql.named('SELECT * FROM ad_campaigns $where ORDER BY created_at DESC'),
      parameters: parameters,
    );
    return result.map((row) => _dateSafeRow(row.toColumnMap())).toList();
  }

  Future<Map<String, Object?>?> adCampaign(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT * FROM ad_campaigns WHERE id = @id'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> updateAdCampaign({
    required int id,
    String? name,
    String? imageUrl,
    String? linkUrl,
    bool? active,
    Object? startDate = unsetSentinel,
    Object? endDate = unsetSentinel,
    Object? targetCountry = unsetSentinel,
    String? targetAudience,
    Object? budgetAmount = unsetSentinel,
    Object? frequencyCapPerDay = unsetSentinel,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE ad_campaigns SET
          name = COALESCE(@name, name),
          image_url = COALESCE(@image_url, image_url),
          link_url = COALESCE(@link_url, link_url),
          active = COALESCE(@active, active),
          start_date = CASE WHEN @start_date_set THEN @start_date ELSE start_date END,
          end_date = CASE WHEN @end_date_set THEN @end_date ELSE end_date END,
          target_country = CASE WHEN @target_country_set THEN @target_country ELSE target_country END,
          target_audience = COALESCE(@target_audience, target_audience),
          budget_amount = CASE WHEN @budget_amount_set THEN @budget_amount ELSE budget_amount END,
          frequency_cap_per_day = CASE WHEN @frequency_cap_set THEN @frequency_cap ELSE frequency_cap_per_day END,
          updated_at = NOW()
        WHERE id = @id
        RETURNING *
      '''),
      parameters: {
        'id': id,
        'name': name,
        'image_url': imageUrl,
        'link_url': linkUrl,
        'active': active,
        'start_date_set': !identical(startDate, unsetSentinel),
        'start_date': identical(startDate, unsetSentinel) ? null : startDate,
        'end_date_set': !identical(endDate, unsetSentinel),
        'end_date': identical(endDate, unsetSentinel) ? null : endDate,
        'target_country_set': !identical(targetCountry, unsetSentinel),
        'target_country':
            identical(targetCountry, unsetSentinel) ? null : targetCountry,
        'target_audience': targetAudience,
        'budget_amount_set': !identical(budgetAmount, unsetSentinel),
        'budget_amount':
            identical(budgetAmount, unsetSentinel) ? null : budgetAmount,
        'frequency_cap_set': !identical(frequencyCapPerDay, unsetSentinel),
        'frequency_cap': identical(frequencyCapPerDay, unsetSentinel)
            ? null
            : frequencyCapPerDay,
      },
    );
    if (result.isEmpty) return null;
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<void> recordAdImpression(int id) async {
    final db = await connection();
    await db.execute(
      Sql.named(
          'UPDATE ad_campaigns SET impressions = impressions + 1 WHERE id = @id'),
      parameters: {'id': id},
    );
  }

  Future<void> recordAdClick(int id) async {
    final db = await connection();
    await db.execute(
      Sql.named('UPDATE ad_campaigns SET clicks = clicks + 1 WHERE id = @id'),
      parameters: {'id': id},
    );
  }

  Future<List<Map<String, Object?>>> activeAdCampaignsForSlot(
      String slot) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM ad_campaigns
        WHERE slot = @slot AND active = TRUE
          AND (start_date IS NULL OR start_date <= CURRENT_DATE)
          AND (end_date IS NULL OR end_date >= CURRENT_DATE)
        ORDER BY created_at DESC
      '''),
      parameters: {'slot': slot},
    );
    return result.map((row) => _dateSafeRow(row.toColumnMap())).toList();
  }

  /// Für den "Push senden"-Haken an einem manuell verfassten Artikel -
  /// respektiert (anders als der allgemeine Push-Broadcast) gezielt die
  /// News-Push-Präferenz, nicht nur den globalen Push-Schalter.
  Future<List<Map<String, String>>> newsEnabledPushTargets() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT installation_id, push_token FROM push_devices
      WHERE enabled = TRUE AND news_enabled = TRUE
    ''');
    return result
        .map((row) => {
              'installationId': row[0].toString(),
              'pushToken': row[1].toString()
            })
        .toList();
  }

  // -- Control Center /push (Phase 5, Broadcast) ---------------------------

  Future<List<Map<String, String>>> broadcastPushTargets({
    required String targetType,
    String? targetValue,
  }) async {
    final db = await connection();
    if (targetType == 'league') {
      final result = await db.execute(
        Sql.named('''
          SELECT DISTINCT d.installation_id, d.push_token
          FROM push_devices d
          JOIN football_favorite_entities f ON f.installation_id = d.installation_id
          WHERE d.enabled = TRUE AND f.entity_type = 'league' AND f.entity_id = @league_id
        '''),
        parameters: {'league_id': targetValue},
      );
      return result
          .map((row) => {
                'installationId': row[0].toString(),
                'pushToken': row[1].toString()
              })
          .toList();
    }
    final result = await db.execute('''
      SELECT installation_id, push_token FROM push_devices WHERE enabled = TRUE
    ''');
    return result
        .map((row) => {
              'installationId': row[0].toString(),
              'pushToken': row[1].toString()
            })
        .toList();
  }

  Future<int> createPushBroadcast({
    required String title,
    required String body,
    required String targetType,
    String? targetValue,
    int? sentByEmployeeId,
    String? deepLinkUrl,
    DateTime? scheduledAt,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO push_broadcasts (
          title, body, target_type, target_value, sent_by_employee_id,
          deep_link_url, scheduled_at
        )
        VALUES (
          @title, @body, @target_type, @target_value, @sent_by_employee_id,
          @deep_link_url, @scheduled_at
        )
        RETURNING id
      '''),
      parameters: {
        'title': title,
        'body': body,
        'target_type': targetType,
        'target_value': targetValue,
        'sent_by_employee_id': sentByEmployeeId,
        'deep_link_url': deepLinkUrl,
        'scheduled_at': scheduledAt,
      },
    );
    return result.first[0] as int;
  }

  /// Wird sowohl nach einem sofortigen als auch nach einem durch
  /// [PushScheduleService] ausgelösten Versand aufgerufen - setzt sent_at
  /// deshalb immer mit, nie separat.
  Future<void> updatePushBroadcastCounts({
    required int id,
    required int sentCount,
    required int failedCount,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE push_broadcasts
        SET sent_count = @sent_count, failed_count = @failed_count, sent_at = NOW()
        WHERE id = @id
      '''),
      parameters: {
        'id': id,
        'sent_count': sentCount,
        'failed_count': failedCount
      },
    );
  }

  Future<List<Map<String, Object?>>> listPushBroadcasts(
      {int limit = 50}) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT * FROM push_broadcasts ORDER BY created_at DESC LIMIT @limit
      '''),
      parameters: {'limit': limit.clamp(1, 200)},
    );
    return result.map((row) => _dateSafeRow(row.toColumnMap())).toList();
  }

  /// Section 19 (AN2): geplante Broadcasts, deren Zeitpunkt erreicht ist und
  /// die noch nicht tatsächlich versendet wurden - abgefragt von
  /// PushScheduleService.
  Future<List<Map<String, Object?>>> duePushBroadcasts() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT * FROM push_broadcasts
      WHERE scheduled_at IS NOT NULL AND scheduled_at <= NOW() AND sent_at IS NULL
      ORDER BY scheduled_at ASC
    ''');
    return result.map((row) => _dateSafeRow(row.toColumnMap())).toList();
  }

  /// Section 19 (AN2): Push-Token für einen Test-Push an ein einzelnes,
  /// bekanntes Gerät (per Installation-ID, z.B. von der Geräte-Seite kopiert).
  Future<String?> pushDeviceToken(String installationId) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT push_token FROM push_devices
        WHERE installation_id = @installation_id AND enabled = TRUE
      '''),
      parameters: {'installation_id': installationId},
    );
    if (result.isEmpty) return null;
    return result.first[0]?.toString();
  }

  // -- Control Center /premium-features (Phase 5) --------------------------

  Future<List<Map<String, Object?>>> listPremiumFeatures() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT feature_key, feature_label, tier, updated_at::text AS updated_at, updated_by
      FROM premium_feature_matrix
      ORDER BY feature_label
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<Map<String, Object?>?> updatePremiumFeatureTier({
    required String featureKey,
    required String tier,
    required String updatedBy,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE premium_feature_matrix SET
          tier = @tier, updated_at = NOW(), updated_by = @updated_by
        WHERE feature_key = @feature_key
        RETURNING feature_key, feature_label, tier, updated_at::text AS updated_at, updated_by
      '''),
      parameters: {
        'feature_key': featureKey,
        'tier': tier,
        'updated_by': updatedBy
      },
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Sentinel für optionale Parameter, bei denen `null` ein gültiger,
  /// explizit zu setzender Wert ist (z.B. ein Bild oder Enddatum löschen) -
  /// unterscheidet "nicht übergeben" von "bewusst auf NULL setzen".
  static const Object unsetSentinel = Object();

  /// Normalisiert alle DateTime-Werte einer `SELECT *`/`RETURNING *`-Zeile zu
  /// ISO8601-Strings, konsistent mit den expliziten `::text`-Casts, die der
  /// Rest dieser Datei für einzeln aufgezählte SELECTs verwendet.
  Map<String, Object?> _dateSafeRow(Map<String, dynamic> row) {
    final map = Map<String, Object?>.from(row);
    for (final key in map.keys.toList()) {
      final value = map[key];
      if (value is DateTime) {
        map[key] = value.toUtc().toIso8601String();
      }
    }
    return map;
  }

  // -- Control Center /feature-flags (Phase 6) -----------------------------

  Future<List<Map<String, Object?>>> listFeatureFlags() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT flag_key, label, description, enabled, rollout_percentage, audience, stage,
        created_at::text AS created_at, updated_at::text AS updated_at, updated_by
      FROM feature_flags
      ORDER BY label
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<Map<String, Object?>> createFeatureFlag({
    required String flagKey,
    required String label,
    String description = '',
    bool enabled = false,
    int rolloutPercentage = 0,
    String audience = 'ALL',
    String stage = 'STAGING',
    required String updatedBy,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO feature_flags (flag_key, label, description, enabled, rollout_percentage, audience, stage, updated_by)
        VALUES (@flag_key, @label, @description, @enabled, @rollout_percentage, @audience, @stage, @updated_by)
        RETURNING flag_key, label, description, enabled, rollout_percentage, audience, stage,
          created_at::text AS created_at, updated_at::text AS updated_at, updated_by
      '''),
      parameters: {
        'flag_key': flagKey,
        'label': label,
        'description': description,
        'enabled': enabled,
        'rollout_percentage': rolloutPercentage,
        'audience': audience,
        'stage': stage,
        'updated_by': updatedBy,
      },
    );
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> updateFeatureFlag({
    required String flagKey,
    bool? enabled,
    int? rolloutPercentage,
    String? audience,
    String? stage,
    required String updatedBy,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE feature_flags SET
          enabled = COALESCE(@enabled, enabled),
          rollout_percentage = COALESCE(@rollout_percentage, rollout_percentage),
          audience = COALESCE(@audience, audience),
          stage = COALESCE(@stage, stage),
          updated_at = NOW(),
          updated_by = @updated_by
        WHERE flag_key = @flag_key
        RETURNING flag_key, label, description, enabled, rollout_percentage, audience, stage,
          created_at::text AS created_at, updated_at::text AS updated_at, updated_by
      '''),
      parameters: {
        'flag_key': flagKey,
        'enabled': enabled,
        'rollout_percentage': rolloutPercentage,
        'audience': audience,
        'stage': stage,
        'updated_by': updatedBy,
      },
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  // -- Control Center /release (Phase 6) ------------------------------------

  Future<Map<String, Object?>> appReleaseConfig() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT current_version, minimum_supported_version, forced_update, changelog,
        minimum_os_android, minimum_os_ios,
        updated_at::text AS updated_at, updated_by
      FROM app_release_config WHERE id = 1
    ''');
    if (result.isEmpty) {
      return {
        'current_version': null,
        'minimum_supported_version': null,
        'forced_update': false,
        'changelog': '',
        'minimum_os_android': null,
        'minimum_os_ios': null,
        'updated_at': null,
        'updated_by': null,
      };
    }
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>> updateAppReleaseConfig({
    String? currentVersion,
    String? minimumSupportedVersion,
    bool? forcedUpdate,
    String? changelog,
    String? minimumOsAndroid,
    String? minimumOsIos,
    required String updatedBy,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE app_release_config SET
          current_version = COALESCE(@current_version, current_version),
          minimum_supported_version = COALESCE(@minimum_supported_version, minimum_supported_version),
          forced_update = COALESCE(@forced_update, forced_update),
          changelog = COALESCE(@changelog, changelog),
          minimum_os_android = COALESCE(@minimum_os_android, minimum_os_android),
          minimum_os_ios = COALESCE(@minimum_os_ios, minimum_os_ios),
          updated_at = NOW(),
          updated_by = @updated_by
        WHERE id = 1
        RETURNING current_version, minimum_supported_version, forced_update, changelog,
          minimum_os_android, minimum_os_ios,
          updated_at::text AS updated_at, updated_by
      '''),
      parameters: {
        'current_version': currentVersion,
        'minimum_supported_version': minimumSupportedVersion,
        'forced_update': forcedUpdate,
        'changelog': changelog,
        'minimum_os_android': minimumOsAndroid,
        'minimum_os_ios': minimumOsIos,
        'updated_by': updatedBy,
      },
    );
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  // -- Control Center /incidents (Phase 6) ----------------------------------

  Future<List<Map<String, Object?>>> listIncidents({String? status}) async {
    final db = await connection();
    final where = status != null && status.trim().isNotEmpty
        ? 'WHERE status = @status'
        : '';
    final result = await db.execute(
      Sql.named('SELECT * FROM incidents $where ORDER BY started_at DESC'),
      parameters: {'status': status},
    );
    return result.map((row) => _dateSafeRow(row.toColumnMap())).toList();
  }

  Future<Map<String, Object?>?> incident(int id) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('SELECT * FROM incidents WHERE id = @id'),
      parameters: {'id': id},
    );
    if (result.isEmpty) return null;
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<Map<String, Object?>> createIncident({
    required String title,
    String severity = 'minor',
    String affectedSystems = '',
    int? responsibleEmployeeId,
    String impactDescription = '',
    String relatedJobsNote = '',
    String communicationNote = '',
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO incidents (
          title, severity, affected_systems, responsible_employee_id,
          impact_description, related_jobs_note, communication_note
        )
        VALUES (
          @title, @severity, @affected_systems, @responsible_employee_id,
          @impact_description, @related_jobs_note, @communication_note
        )
        RETURNING *
      '''),
      parameters: {
        'title': title,
        'severity': severity,
        'affected_systems': affectedSystems,
        'responsible_employee_id': responsibleEmployeeId,
        'impact_description': impactDescription,
        'related_jobs_note': relatedJobsNote,
        'communication_note': communicationNote,
      },
    );
    return _dateSafeRow(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> updateIncident({
    required int id,
    String? status,
    String? severity,
    String? actionsTaken,
    String? postmortem,
    int? responsibleEmployeeId,
    String? impactDescription,
    String? relatedJobsNote,
    String? communicationNote,
    bool closeNow = false,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE incidents SET
          status = COALESCE(@status, status),
          severity = COALESCE(@severity, severity),
          actions_taken = COALESCE(@actions_taken, actions_taken),
          postmortem = COALESCE(@postmortem, postmortem),
          responsible_employee_id = COALESCE(@responsible_employee_id, responsible_employee_id),
          impact_description = COALESCE(@impact_description, impact_description),
          related_jobs_note = COALESCE(@related_jobs_note, related_jobs_note),
          communication_note = COALESCE(@communication_note, communication_note),
          ended_at = CASE WHEN @close_now THEN NOW() ELSE ended_at END,
          updated_at = NOW()
        WHERE id = @id
        RETURNING *
      '''),
      parameters: {
        'id': id,
        'status': status,
        'severity': severity,
        'actions_taken': actionsTaken,
        'postmortem': postmortem,
        'responsible_employee_id': responsibleEmployeeId,
        'impact_description': impactDescription,
        'related_jobs_note': relatedJobsNote,
        'communication_note': communicationNote,
        'close_now': closeNow,
      },
    );
    if (result.isEmpty) return null;
    return _dateSafeRow(result.first.toColumnMap());
  }

  // Section 27 (AN2): "Timeline" - chronologische Einzeleinträge.
  Future<List<Map<String, Object?>>> listIncidentTimelineEvents(
      int incidentId) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT t.id, t.incident_id, t.occurred_at::text AS occurred_at, t.note,
          t.created_by_employee_id, e.name AS created_by_employee_name,
          t.created_at::text AS created_at
        FROM incident_timeline_events t
        LEFT JOIN admin_employees e ON e.id = t.created_by_employee_id
        WHERE t.incident_id = @incident_id
        ORDER BY t.occurred_at ASC
      '''),
      parameters: {'incident_id': incidentId},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<Map<String, Object?>> addIncidentTimelineEvent({
    required int incidentId,
    required String note,
    DateTime? occurredAt,
    int? createdByEmployeeId,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO incident_timeline_events (incident_id, note, occurred_at, created_by_employee_id)
        VALUES (@incident_id, @note, COALESCE(@occurred_at, NOW()), @created_by_employee_id)
        RETURNING id, incident_id, occurred_at::text AS occurred_at, note,
          created_by_employee_id, created_at::text AS created_at
      '''),
      parameters: {
        'incident_id': incidentId,
        'note': note,
        'occurred_at': occurredAt,
        'created_by_employee_id': createdByEmployeeId,
      },
    );
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  // -- Control Center Security (Phase 6) -------------------------------------

  Future<void> recordFailedLogin({required String login, String? ip}) async {
    final db = await connection();
    await db.execute(
      Sql.named(
          'INSERT INTO admin_failed_logins (login, ip) VALUES (@login, @ip)'),
      parameters: {'login': login, 'ip': ip},
    );
  }

  Future<List<Map<String, Object?>>> recentFailedLogins(
      {int limit = 50}) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT login, ip, attempted_at::text AS attempted_at
        FROM admin_failed_logins
        ORDER BY attempted_at DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit.clamp(1, 500)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Aktive Sessions je Mitarbeiter - dient sowohl der Security-Ansicht
  /// (einzelne Session beenden) als auch als Online-Status-Näherung (Section
  /// 12): kein echtes Heartbeat/Presence-System, "online" = mind. eine nicht
  /// abgelaufene, nicht widerrufene Session.
  Future<List<Map<String, Object?>>> listActiveAdminSessions() async {
    final db = await connection();
    final result = await db.execute('''
      SELECT s.token, s.employee_id, e.name AS employee_name, e.login AS employee_login,
        s.created_at::text AS created_at, s.expires_at::text AS expires_at,
        s.ip, s.user_agent
      FROM admin_sessions s
      JOIN admin_employees e ON e.id = s.employee_id
      WHERE s.revoked_at IS NULL AND s.expires_at > NOW()
      ORDER BY s.created_at DESC
    ''');
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<bool> revokeAdminSessionByToken(String token) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE admin_sessions SET revoked_at = NOW()
        WHERE token = @token AND revoked_at IS NULL
        RETURNING token
      '''),
      parameters: {'token': token},
    );
    return result.isNotEmpty;
  }

  /// Section 32 (AN2): "Login-Verlauf" - anders als [listActiveAdminSessions]
  /// auch abgelaufene/beendete Sessions, damit man sieht, wann sich wer
  /// eingeloggt hat, nicht nur wer gerade online ist.
  Future<List<Map<String, Object?>>> listAdminSessionsHistory(
      {int limit = 100}) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT s.token, s.employee_id, e.name AS employee_name, e.login AS employee_login,
          s.created_at::text AS created_at, s.expires_at::text AS expires_at,
          s.revoked_at::text AS revoked_at,
          (s.revoked_at IS NULL AND s.expires_at > NOW()) AS active,
          s.ip, s.user_agent
        FROM admin_sessions s
        JOIN admin_employees e ON e.id = s.employee_id
        ORDER BY s.created_at DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit.clamp(1, 500)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Section 32 (AN2): "Rate Limits" - echte Zählung bereits gespeicherter
  /// fehlgeschlagener Versuche, kein separater Zähler-Mechanismus nötig.
  Future<int> countRecentFailedLogins(
      {required String login, required Duration within}) async {
    final db = await connection();
    final cutoff = DateTime.now().toUtc().subtract(within);
    final result = await db.execute(
      Sql.named('''
        SELECT COUNT(*) FROM admin_failed_logins
        WHERE login = @login AND attempted_at > @cutoff
      '''),
      parameters: {'login': login, 'cutoff': cutoff},
    );
    return int.tryParse(result.first[0]?.toString() ?? '') ?? 0;
  }

  // -- Section 32 (AN2): TOTP-2FA -------------------------------------------

  Future<Map<String, Object?>?> employeeTwoFactorStatus(int employeeId) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT two_factor_enabled, two_factor_secret, two_factor_method
        FROM admin_employees WHERE id = @id
      '''),
      parameters: {'id': employeeId},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  /// Speichert ein neues Secret, OHNE 2FA bereits scharf zu schalten - das
  /// passiert erst in [enableEmployeeTwoFactor], nach bestätigtem Code.
  Future<void> setEmployeeTwoFactorSecret(int employeeId, String secret) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE admin_employees
        SET two_factor_secret = @secret, two_factor_method = 'totp'
        WHERE id = @id
      '''),
      parameters: {'id': employeeId, 'secret': secret},
    );
  }

  Future<void> enableEmployeeTwoFactor(int employeeId) async {
    final db = await connection();
    await db.execute(
      Sql.named(
          'UPDATE admin_employees SET two_factor_enabled = TRUE WHERE id = @id'),
      parameters: {'id': employeeId},
    );
  }

  Future<void> disableEmployeeTwoFactor(int employeeId) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        UPDATE admin_employees
        SET two_factor_enabled = FALSE, two_factor_secret = NULL, two_factor_method = NULL
        WHERE id = @id
      '''),
      parameters: {'id': employeeId},
    );
  }

  Future<void> createPendingTwoFactorLogin({
    required String token,
    required int employeeId,
    required DateTime expiresAt,
    String? ip,
    String? userAgent,
  }) async {
    final db = await connection();
    await db.execute(
      Sql.named('''
        INSERT INTO admin_pending_two_factor_logins (token, employee_id, expires_at, ip, user_agent)
        VALUES (@token, @employee_id, @expires_at, @ip, @user_agent)
      '''),
      parameters: {
        'token': token,
        'employee_id': employeeId,
        'expires_at': expiresAt,
        'ip': ip,
        'user_agent': userAgent,
      },
    );
  }

  /// Single-Use: liefert die employee_id nur, wenn das Token existiert und
  /// noch nicht abgelaufen ist, und löscht es in derselben Abfrage.
  Future<int?> consumePendingTwoFactorLogin(String token) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        DELETE FROM admin_pending_two_factor_logins
        WHERE token = @token AND expires_at > NOW()
        RETURNING employee_id
      '''),
      parameters: {'token': token},
    );
    if (result.isEmpty) return null;
    return result.first[0] as int?;
  }

  // -- Control Center /system-health (Phase 6) ------------------------------

  /// Rein lesende DB-Kennzahlen (Section 50 "Database"/"Storage") - direkte
  /// Postgres-Introspektion, keine externe Anbindung nötig.
  Future<Map<String, Object?>> databaseStats() async {
    final db = await connection();
    final sizeResult = await db.execute('''
      SELECT pg_database_size(current_database()) AS size_bytes
    ''');
    final tableResult = await db.execute('''
      SELECT relname, n_live_tup
      FROM pg_stat_user_tables
      ORDER BY n_live_tup DESC
      LIMIT 15
    ''');
    // Section 28 (AN2): "Indizes" - Größe und Nutzung (wie oft genutzt) je
    // Index, damit ungenutzte/übergroße Indizes auffallen.
    final indexResult = await db.execute('''
      SELECT
        s.relname AS table_name,
        s.indexrelname AS index_name,
        pg_relation_size(s.indexrelid) AS size_bytes,
        s.idx_scan AS scans
      FROM pg_stat_user_indexes s
      ORDER BY pg_relation_size(s.indexrelid) DESC
      LIMIT 20
    ''');
    // "Langsame Queries" braucht die pg_stat_statements-Extension, die auf
    // dieser Railway-Instanz evtl. nicht aktiviert ist - defensiv statt die
    // ganze Seite zum Absturz zu bringen, wenn sie fehlt.
    List<Map<String, Object?>>? slowQueries;
    try {
      final slowResult = await db.execute('''
        SELECT query, calls, mean_exec_time, max_exec_time
        FROM pg_stat_statements
        WHERE query NOT ILIKE '%pg_stat_statements%'
        ORDER BY mean_exec_time DESC
        LIMIT 10
      ''');
      slowQueries = slowResult
          .map((row) => {
                'query': row[0].toString(),
                'calls': row[1],
                'meanExecMs': row[2],
                'maxExecMs': row[3],
              })
          .toList();
    } catch (_) {
      slowQueries = null;
    }

    return {
      'sizeBytes': sizeResult.first[0],
      'largestTables': tableResult
          .map((row) => {'table': row[0].toString(), 'rows': row[1]})
          .toList(),
      'indexes': indexResult
          .map((row) => {
                'table': row[0].toString(),
                'index': row[1].toString(),
                'sizeBytes': row[2],
                'scans': row[3],
              })
          .toList(),
      'slowQueries': slowQueries,
      'slowQueriesAvailable': slowQueries != null,
    };
  }

  // Section 28 (AN2): "Größenverlauf, Tabellenwachstum" - es gibt keinen
  // eigenen Cron dafür; stattdessen wird bei jedem Aufruf der
  // Database-/System-Health-Seite ein echter Snapshot gespeichert
  // ("Aufruf-getriebene" Historie statt erfundener Zwischenwerte).
  Future<void> recordDatabaseSizeSnapshot() async {
    final db = await connection();
    final sizeResult = await db.execute('''
      SELECT pg_database_size(current_database()) AS size_bytes
    ''');
    final sizeBytes = sizeResult.first[0] as int;
    await db.execute(
      Sql.named('''
        INSERT INTO database_size_snapshots (size_bytes)
        VALUES (@size_bytes)
      '''),
      parameters: {'size_bytes': sizeBytes},
    );
  }

  Future<List<Map<String, Object?>>> databaseSizeHistory(
      {int limit = 30}) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT size_bytes, recorded_at::text AS recorded_at
        FROM database_size_snapshots
        ORDER BY recorded_at DESC
        LIMIT @limit
      '''),
      parameters: {'limit': limit.clamp(1, 200)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  /// Section OVERVIEW: die drei Kennzahlen, die nicht bereits durch
  /// footballDailyOverviewStats()/ModelLabRoutes.overview abgedeckt sind.
  Future<Map<String, Object?>> controlCenterTodayStats() async {
    final db = await connection();

    final supportRows = await db.execute('''
      SELECT COUNT(*) FROM support_tickets
      WHERE status NOT IN ('GELOEST', 'GESCHLOSSEN')
    ''');
    final activeSupportCases =
        int.tryParse(supportRows.first[0]?.toString() ?? '') ?? 0;

    // "Aktiv" = innerhalb der letzten 24 Stunden etwas in der App getan
    // (Session-Aktivität), nicht nur "jemals registriert".
    final usersRows = await db.execute('''
      SELECT COUNT(*) FROM users
      WHERE last_active_at IS NOT NULL
        AND last_active_at > NOW() - INTERVAL '24 hours'
    ''');
    final activeUsers = int.tryParse(usersRows.first[0]?.toString() ?? '') ?? 0;

    final liveRows = await db.execute('''
      SELECT COUNT(*) FROM football_matches
      WHERE status = ANY(ARRAY['1H','HT','2H','ET','BT','P','INT','LIVE'])
    ''');
    final activeLiveMatches =
        int.tryParse(liveRows.first[0]?.toString() ?? '') ?? 0;

    return {
      'activeSupportCases': activeSupportCases,
      'activeUsers': activeUsers,
      'activeLiveMatches': activeLiveMatches,
    };
  }

  // -- Control Center /users (PHÖNIX Account System) -----------------------

  static const Set<String> _userManagedFields = {
    'id',
    'phoenix_user_id',
    'account_type',
    'email',
    'email_verified',
    'username',
    'display_name',
    'date_of_birth',
    'age_gate_passed',
    'account_status',
    'language',
    'country',
    'trial_available',
    'trial_started_at',
    'trial_ends_at',
    'trial_used',
    'created_at',
    'updated_at',
    'last_login_at',
    'last_active_at',
    'deletion_status',
    'deletion_requested_at',
    'deletion_scheduled_at',
  };

  Future<Map<String, Object?>> listUsersAdmin({
    String? search,
    String? accountStatus,
    bool? hasPremium,
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await connection();
    final conditions = <String>[];
    final parameters = <String, Object?>{};

    if (search != null && search.trim().isNotEmpty) {
      conditions.add(
        "(u.email_lower LIKE @search OR u.username_lower LIKE @search OR "
        "u.phoenix_user_id ILIKE @search)",
      );
      parameters['search'] = '%${search.trim().toLowerCase()}%';
    }
    if (accountStatus != null && accountStatus.trim().isNotEmpty) {
      conditions.add('u.account_status = @account_status');
      parameters['account_status'] = accountStatus.trim();
    }
    if (hasPremium != null) {
      conditions.add(
        hasPremium
            ? '''EXISTS (
                SELECT 1 FROM user_premium_entitlements e
                WHERE e.user_id = u.id AND e.active = TRUE
                  AND e.source <> 'STAFF'
                  AND (e.expires_at IS NULL OR e.expires_at > NOW())
              )'''
            : '''NOT EXISTS (
                SELECT 1 FROM user_premium_entitlements e
                WHERE e.user_id = u.id AND e.active = TRUE
                  AND e.source <> 'STAFF'
                  AND (e.expires_at IS NULL OR e.expires_at > NOW())
              )''',
      );
    }

    final whereClause =
        conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';

    final rows = await db.execute(
      Sql.named('''
        SELECT
          u.id, u.phoenix_user_id, u.account_type, u.email, u.email_verified,
          u.username, u.display_name, u.account_status, u.created_at,
          u.last_active_at,
          EXISTS (
            SELECT 1 FROM user_premium_entitlements e
            WHERE e.user_id = u.id AND e.active = TRUE
              AND e.source <> 'STAFF'
              AND (e.expires_at IS NULL OR e.expires_at > NOW())
          ) AS has_premium,
          EXISTS (
            SELECT 1 FROM user_bans b
            WHERE b.user_id = u.id AND b.status = 'ACTIVE'
          ) AS has_active_ban
        FROM users u
        $whereClause
        ORDER BY u.created_at DESC
        LIMIT @limit OFFSET @offset
      '''),
      parameters: {
        ...parameters,
        'limit': limit.clamp(1, 200),
        'offset': offset.clamp(0, 1 << 30)
      },
    );

    final countRows = await db.execute(
      Sql.named('SELECT COUNT(*) AS total FROM users u $whereClause'),
      parameters: parameters,
    );
    final total = int.tryParse(
          countRows.first.toColumnMap()['total']?.toString() ?? '',
        ) ??
        0;

    return {
      'users':
          rows.map((r) => Map<String, Object?>.from(r.toColumnMap())).toList(),
      'total': total,
      'limit': limit,
      'offset': offset,
    };
  }

  Future<Map<String, Object?>?> userAdminDetail(int userId) async {
    final db = await connection();
    final userRows = await db.execute(
      Sql.named('SELECT * FROM users WHERE id = @id'),
      parameters: {'id': userId},
    );
    if (userRows.isEmpty) return null;
    final user = Map<String, Object?>.from(userRows.first.toColumnMap())
      ..removeWhere((key, _) => !_userManagedFields.contains(key));

    final sessions = await db.execute(
      Sql.named('''
        SELECT token, created_at, expires_at, revoked_at, ip, user_agent,
               device_model, platform, app_version
        FROM user_sessions
        WHERE user_id = @id
        ORDER BY created_at DESC
        LIMIT 50
      '''),
      parameters: {'id': userId},
    );

    final entitlements = await db.execute(
      Sql.named('''
        SELECT e.id, e.source, e.active, e.tier, e.starts_at, e.expires_at,
               e.auto_renew, e.cancelled_at, e.provider_product_id, e.reason,
               e.created_at, e.granted_by_employee_id,
               emp.name AS granted_by_name
        FROM user_premium_entitlements e
        LEFT JOIN admin_employees emp ON emp.id = e.granted_by_employee_id
        WHERE e.user_id = @id
        ORDER BY e.created_at DESC
      '''),
      parameters: {'id': userId},
    );

    final bans = await db.execute(
      Sql.named('''
        SELECT b.id, b.case_number, b.status, b.reason, b.internal_report,
               b.duration_type, b.expires_at, b.refund_decision,
               b.refund_reason, b.support_ticket_id, b.created_at,
               b.lifted_at, b.lift_reason,
               creator.name AS created_by_name,
               lifter.name AS lifted_by_name
        FROM user_bans b
        LEFT JOIN admin_employees creator ON creator.id = b.created_by_employee_id
        LEFT JOIN admin_employees lifter ON lifter.id = b.lifted_by_employee_id
        WHERE b.user_id = @id
        ORDER BY b.created_at DESC
      '''),
      parameters: {'id': userId},
    );

    final tickets = await db.execute(
      Sql.named('''
        SELECT id, category, priority, status, subject, created_at, updated_at
        FROM support_tickets
        WHERE user_id = @id
        ORDER BY created_at DESC
        LIMIT 50
      '''),
      parameters: {'id': userId},
    );

    Map<String, Object?> row(dynamic r) =>
        Map<String, Object?>.from(r.toColumnMap());

    return {
      'user': user,
      'sessions': sessions.map(row).toList(),
      'premiumEntitlements': entitlements.map(row).toList(),
      'bans': bans.map(row).toList(),
      'supportTickets': tickets.map(row).toList(),
    };
  }

  Future<Map<String, Object?>> grantUserPremium({
    required int userId,
    required String source,
    String? tier,
    DateTime? expiresAt,
    String? reason,
    required int grantedByEmployeeId,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO user_premium_entitlements (
          user_id, source, active, tier, expires_at, reason,
          granted_by_employee_id
        ) VALUES (
          @user_id, @source, TRUE, @tier, @expires_at, @reason,
          @granted_by_employee_id
        )
        RETURNING id, source, active, tier, starts_at, expires_at, reason,
          created_at
      '''),
      parameters: {
        'user_id': userId,
        'source': source,
        'tier': tier,
        'expires_at': expiresAt?.toUtc(),
        'reason': reason,
        'granted_by_employee_id': grantedByEmployeeId,
      },
    );
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> revokeUserPremium({
    required int entitlementId,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE user_premium_entitlements
        SET active = FALSE, cancelled_at = NOW(), updated_at = NOW()
        WHERE id = @id
        RETURNING id, user_id, source, active
      '''),
      parameters: {'id': entitlementId},
    );
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>> banUser({
    required int userId,
    required String reason,
    required String internalReport,
    required String durationType,
    DateTime? expiresAt,
    int? supportTicketId,
    required int createdByEmployeeId,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO user_bans (
          user_id, reason, internal_report, duration_type, expires_at,
          support_ticket_id, created_by_employee_id
        ) VALUES (
          @user_id, @reason, @internal_report, @duration_type, @expires_at,
          @support_ticket_id, @created_by_employee_id
        )
        RETURNING id, case_number, status, reason, duration_type, expires_at,
          created_at
      '''),
      parameters: {
        'user_id': userId,
        'reason': reason,
        'internal_report': internalReport,
        'duration_type': durationType,
        'expires_at': expiresAt?.toUtc(),
        'support_ticket_id': supportTicketId,
        'created_by_employee_id': createdByEmployeeId,
      },
    );
    await db.execute(
      Sql.named('''
        UPDATE users SET account_status = CASE
            WHEN @duration_type = 'PERMANENT' THEN 'PERMANENTLY_SUSPENDED'
            ELSE 'SUSPENDED'
          END,
          updated_at = NOW()
        WHERE id = @user_id
      '''),
      parameters: {'user_id': userId, 'duration_type': durationType},
    );
    return Map<String, Object?>.from(result.first.toColumnMap());
  }

  Future<Map<String, Object?>?> liftUserBan({
    required int banId,
    required int liftedByEmployeeId,
    String? liftReason,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE user_bans
        SET status = 'LIFTED', lifted_by_employee_id = @lifted_by,
            lifted_at = NOW(), lift_reason = @lift_reason
        WHERE id = @id AND status = 'ACTIVE'
        RETURNING id, user_id, status
      '''),
      parameters: {
        'id': banId,
        'lifted_by': liftedByEmployeeId,
        'lift_reason': liftReason,
      },
    );
    if (result.isEmpty) return null;
    final banRow = Map<String, Object?>.from(result.first.toColumnMap());

    // Nur wieder aktivieren, wenn keine ANDERE aktive Sperre für denselben
    // Nutzer übrig bleibt.
    final userId = banRow['user_id'];
    final stillBanned = await db.execute(
      Sql.named('''
        SELECT COUNT(*) FROM user_bans
        WHERE user_id = @user_id AND status = 'ACTIVE'
      '''),
      parameters: {'user_id': userId},
    );
    final remaining = int.tryParse(stillBanned.first[0]?.toString() ?? '') ?? 0;
    if (remaining == 0) {
      await db.execute(
        Sql.named('''
          UPDATE users SET account_status = 'ACTIVE', updated_at = NOW()
          WHERE id = @user_id AND account_status IN
            ('SUSPENDED', 'PERMANENTLY_SUSPENDED')
        '''),
        parameters: {'user_id': userId},
      );
    }
    return banRow;
  }

  Future<bool> revokeUserSessionByToken(String token) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE user_sessions SET revoked_at = NOW()
        WHERE token = @token AND revoked_at IS NULL
        RETURNING token
      '''),
      parameters: {'token': token},
    );
    return result.isNotEmpty;
  }

  Future<void> close() async {
    await _connection?.close();
    _connection = null;
  }

  String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
