import 'dart:convert';

import 'package:postgres/postgres.dart';

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
        ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_daily_pipeline_jobs_date
      ON football_daily_pipeline_jobs (scan_date, id DESC)
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

    // PHÖNIX feste Wettbewerbs-Whitelist:
    // 16 nationale Ligen, 11 nationale Pokale und 3 UEFA-Wettbewerbe.
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
        updated_at
      )
      VALUES
        ('39',  'Premier League',              'England',     'men', 1, 'whitelist', 'approved', NOW()),
        ('61',  'Ligue 1',                     'France',      'men', 1, 'whitelist', 'approved', NOW()),
        ('78',  'Bundesliga',                  'Germany',     'men', 1, 'whitelist', 'approved', NOW()),
        ('79',  '2. Bundesliga',               'Germany',     'men', 2, 'whitelist', 'approved', NOW()),
        ('80',  '3. Liga',                     'Germany',     'men', 3, 'whitelist', 'approved', NOW()),
        ('88',  'Eredivisie',                  'Netherlands', 'men', 1, 'whitelist', 'approved', NOW()),
        ('94',  'Primeira Liga',               'Portugal',    'men', 1, 'whitelist', 'approved', NOW()),
        ('103', 'Eliteserien',                 'Norway',      'men', 1, 'whitelist', 'approved', NOW()),
        ('113', 'Allsvenskan',                 'Sweden',      'men', 1, 'whitelist', 'approved', NOW()),
        ('119', 'Superliga',                   'Denmark',     'men', 1, 'whitelist', 'approved', NOW()),
        ('135', 'Serie A',                     'Italy',       'men', 1, 'whitelist', 'approved', NOW()),
        ('140', 'La Liga',                     'Spain',       'men', 1, 'whitelist', 'approved', NOW()),
        ('144', 'Jupiler Pro League',          'Belgium',     'men', 1, 'whitelist', 'approved', NOW()),
        ('244', 'Veikkausliiga',               'Finland',     'men', 1, 'whitelist', 'approved', NOW()),
        ('207', 'Super League',                 'Switzerland', 'men', 1, 'whitelist', 'approved', NOW()),
        ('253', 'Major League Soccer',          'USA',         'men', 1, 'whitelist', 'approved', NOW()),

        ('45',  'FA Cup',                      'England',     'men', NULL, 'whitelist', 'approved', NOW()),
        ('48',  'EFL Cup',                     'England',     'men', NULL, 'whitelist', 'approved', NOW()),
        ('66',  'Coupe de France',             'France',      'men', NULL, 'whitelist', 'approved', NOW()),
        ('81',  'DFB Pokal',                   'Germany',     'men', NULL, 'whitelist', 'approved', NOW()),
        ('90',  'KNVB Beker',                  'Netherlands', 'men', NULL, 'whitelist', 'approved', NOW()),
        ('96',  'Taça de Portugal',            'Portugal',    'men', NULL, 'whitelist', 'approved', NOW()),
        ('104', 'NM Cupen',                    'Norway',      'men', NULL, 'whitelist', 'approved', NOW()),
        ('137', 'Coppa Italia',                'Italy',       'men', NULL, 'whitelist', 'approved', NOW()),
        ('143', 'Copa del Rey',                'Spain',       'men', NULL, 'whitelist', 'approved', NOW()),
        ('147', 'Belgian Cup',                 'Belgium',     'men', NULL, 'whitelist', 'approved', NOW()),
        ('245', 'Suomen Cup',                  'Finland',     'men', NULL, 'whitelist', 'approved', NOW()),

        ('2',   'UEFA Champions League',       'World',       'men', NULL, 'whitelist', 'approved', NOW()),
        ('3',   'UEFA Europa League',          'World',       'men', NULL, 'whitelist', 'approved', NOW()),
        ('848', 'UEFA Conference League',      'World',       'men', NULL, 'whitelist', 'approved', NOW())
      ON CONFLICT (league_id) DO UPDATE SET
        league_name = EXCLUDED.league_name,
        country = EXCLUDED.country,
        gender = EXCLUDED.gender,
        competition_level = EXCLUDED.competition_level,
        manual_status = 'whitelist',
        historical_status = 'approved',
        updated_at = NOW()
    ''');

    // API-Football 116 ist die belarussische Premier League. Eine ältere
    // Zuordnung als Svenska Cupen hatte sie versehentlich freigeschaltet.
    await db.execute(r'''
      INSERT INTO football_leagues (
        league_id, league_name, country, gender, competition_level,
        manual_status, historical_status, updated_at
      ) VALUES (
        '116', 'Premier League', 'Belarus', 'men', 1,
        'blacklist', 'blacklist', NOW()
      )
      ON CONFLICT (league_id) DO UPDATE SET
        league_name = EXCLUDED.league_name,
        country = EXCLUDED.country,
        gender = EXCLUDED.gender,
        competition_level = EXCLUDED.competition_level,
        manual_status = 'blacklist',
        historical_status = 'blacklist',
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

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_news_articles_published
      ON news_articles (published_at DESC)
    ''');

    await db.execute('''
      INSERT INTO app_meta (key, value)
      VALUES ('schema_version', '5')
      ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value, updated_at = NOW()
    ''');
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

  Future<bool> upsertNewsArticle(Map<String, Object?> article) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      INSERT INTO news_articles (
        id, source_name, source_url, article_url, title_de, summary_de,
        image_url, category, importance, team_ids, team_names,
        league_ids, league_names, published_at
      ) VALUES (
        @id, @sourceName, @sourceUrl, @articleUrl, @title, @summary,
        @imageUrl, @category, @importance, @teamIds::jsonb, @teamNames::jsonb,
        @leagueIds::jsonb, @leagueNames::jsonb, @publishedAt
      ) ON CONFLICT (article_url) DO UPDATE SET
        title_de = EXCLUDED.title_de,
        summary_de = EXCLUDED.summary_de,
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
    bool importantOnly = false,
    int hours = 168,
    int limit = 80,
  }) async {
    final db = await connection();
    final rows = await db.execute(Sql.named('''
      SELECT id, source_name, source_url, article_url, title_de, summary_de,
             image_url, category, importance, team_ids, team_names,
             league_ids, league_names, published_at
      FROM news_articles
      WHERE published_at >= NOW() - (@hours * INTERVAL '1 hour')
        AND (title || ' ' || summary) !~* '(^|[^[:alnum:]])wm([^[:alnum:]]|\$)'
        AND LOWER(title || ' ' || summary) NOT LIKE ALL (ARRAY[
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
        AND (@importantOnly = FALSE OR importance >= 70)
      ORDER BY importance DESC, published_at DESC
      LIMIT @limit
    '''), parameters: {
      'hours': hours.clamp(1, 336),
      'teamId': teamId ?? '',
      'leagueId': leagueId ?? '',
      'category': category ?? '',
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
              'imageUrl': row[6],
              'category': row[7],
              'importance': row[8],
              'teamIds': row[9],
              'teamNames': row[10],
              'leagueIds': row[11],
              'leagueNames': row[12],
              'publishedAt': (row[13] as DateTime).toUtc().toIso8601String(),
            })
        .toList(growable: false);
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
          l.historical_status,
          l.total_samples,
          l.successful_full_analyses,
          l.last_seen_at,
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

  Future<bool> setFootballLeagueManualStatus({
    required String leagueId,
    required String manualStatus,
  }) async {
    if (!const {'auto', 'whitelist', 'blacklist'}.contains(manualStatus)) {
      throw ArgumentError('Status muss auto, whitelist oder blacklist sein.');
    }

    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE football_leagues
        SET manual_status = @manual_status, updated_at = NOW()
        WHERE league_id = @league_id
        RETURNING league_id
      '''),
      parameters: {'league_id': leagueId, 'manual_status': manualStatus},
    );

    return result.isNotEmpty;
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
          AND p.analysis_allowed = TRUE
        ORDER BY p.data_quality DESC, p.fixture_id
      '''),
      parameters: {'scan_run_id': phaseTwoScanRunId},
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
          status = EXCLUDED.status,
          league_id = EXCLUDED.league_id,
          league_name = EXCLUDED.league_name,
          country = EXCLUDED.country,
          home_team_id = EXCLUDED.home_team_id,
          home_team_name = EXCLUDED.home_team_name,
          home_logo = EXCLUDED.home_logo,
          away_team_id = EXCLUDED.away_team_id,
          away_team_name = EXCLUDED.away_team_name,
          away_logo = EXCLUDED.away_logo,
          home_goals = EXCLUDED.home_goals,
          away_goals = EXCLUDED.away_goals,
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

  Future<void> saveFinalFootballAnalysis({
    required String fixtureId,
    required String modelVersion,
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
          'football', @match_id, @model_version, @data_quality,
          @confidence, @recommendation, CAST(@payload AS JSONB)
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
        'model_version': modelVersion,
        'data_quality': dataQuality,
        'confidence': confidence,
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
    final rawMarketOdds = value['marketOdds'];
    final marketOdds = rawMarketOdds is num
        ? rawMarketOdds.toDouble()
        : double.tryParse(rawMarketOdds?.toString() ?? '');
    // A flat one-unit stake keeps ROI comparable. Only value tips that passed
    // all guards count as bets; every other prediction remains in history.
    final assignedUnits =
        value['isValueTip'] == true && marketOdds != null && marketOdds > 1
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
        'market_key': tip['marketKey']?.toString() ?? '',
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

  Future<List<Map<String, Object?>>> pendingFootballTips({
    DateTime? date,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT phase_two_scan_run_id, fixture_id, market_key, market_label,
               market_odds, assigned_units, payload
        FROM football_analysis_history
        WHERE result_status = 'pending'
          AND (@prediction_date IS NULL OR prediction_date = CAST(@prediction_date AS DATE))
        ORDER BY kickoff
      '''),
      parameters: {'prediction_date': date?.toIso8601String().substring(0, 10)},
    );
    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
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
        FROM football_analysis_history
        WHERE $condition
      ''');
      return metrics(Map<String, Object?>.from(result.first.toColumnMap()));
    }

    Future<List<Map<String, Object?>>> grouped(String expression) async {
      final result = await db.execute('''
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
        FROM football_analysis_history
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

  Future<int> createFootballDailyPipelineJob({
    required DateTime date,
    required int limit,
    required int minimumDataQuality,
    required int simulations,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO football_daily_pipeline_jobs (
          scan_date, requested_limit, minimum_data_quality, simulations
        ) VALUES (@date, @limit, @quality, @simulations)
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
    return result.first[0] as int;
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
          completed_at = CASE WHEN @completed THEN NOW() ELSE completed_at END
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

  Future<void> close() async {
    await _connection?.close();
    _connection = null;
  }

  String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
