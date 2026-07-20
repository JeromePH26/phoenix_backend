import 'dart:convert';
import 'dart:typed_data';

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
      CREATE TABLE IF NOT EXISTS football_assets (
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        source_url TEXT NOT NULL DEFAULT '',
        mime_type TEXT NOT NULL,
        image_bytes BYTEA NOT NULL,
        size_bytes INTEGER NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (entity_type, entity_id)
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
      INSERT INTO app_meta (key, value)
      VALUES ('schema_version', '2')
      ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value, updated_at = NOW()
    ''');
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
      parameters: {
        'league_id': leagueId,
        'season': season,
      },
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
        LIMIT @limit
      '''),
      parameters: {'limit': safeLimit},
    );

    return result
        .map((row) => Map<String, Object?>.from(row.toColumnMap()))
        .toList();
  }

  Future<bool> setFootballLeagueManualStatus({
    required String leagueId,
    required String manualStatus,
  }) async {
    if (!const {'auto', 'whitelist', 'blacklist'}.contains(manualStatus)) {
      throw ArgumentError(
        'Status muss auto, whitelist oder blacklist sein.',
      );
    }

    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        UPDATE football_leagues
        SET manual_status = @manual_status, updated_at = NOW()
        WHERE league_id = @league_id
        RETURNING league_id
      '''),
      parameters: {
        'league_id': leagueId,
        'manual_status': manualStatus,
      },
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
      parameters: {
        'day': day,
        'minimum_quality': safeQuality,
      },
    );

    return result.map((row) {
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
    }).where((row) => (row['id']?.toString() ?? '').isNotEmpty).toList();
  }

  Map<String, Object?> _normalizePreparedAnalysis(
    Map<String, Object?> analysis,
  ) {
    if (analysis.isEmpty) return analysis;

    final normalized = Map<String, Object?>.from(analysis);
    final probabilities = _jsonMap(normalized['probabilities']);

    if (probabilities.isNotEmpty) {
      final result = <String, Object?>{
        ...probabilities,
      };

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
    int limit = 20,
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
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT fixture_id, league_id, season, data_quality, availability, payload
        FROM football_phase_two_results
        WHERE scan_run_id = @scan_run_id
          AND analysis_allowed = TRUE
        ORDER BY data_quality DESC, fixture_id
        LIMIT @limit
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'limit': limit.clamp(1, 20),
      },
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

  /// Liefert Engine-Kandidaten ausschließlich aus den strukturierten
  /// Phase-2-Daten. Alte Gemini/OpenAI-Kontexte bleiben zwar zu historischen
  /// Zwecken in der Datenbank, werden aber nicht mehr gelesen oder angewendet.
  Future<List<Map<String, Object?>>> phaseFourCandidates({
    required int phaseTwoScanRunId,
    int limit = 20,
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
          '{}'::jsonb AS context_result,
          'disabled'::text AS context_source,
          NULL::bigint AS context_source_scan_run_id
        FROM football_phase_two_results p
        WHERE p.scan_run_id = @scan_run_id
          AND p.analysis_allowed = TRUE
        ORDER BY p.data_quality DESC, p.fixture_id
        LIMIT @limit
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'limit': limit.clamp(1, 100),
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
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT fixture_id, normalized_input
        FROM football_engine_inputs
        WHERE phase_two_scan_run_id = @scan_run_id
        ORDER BY data_quality DESC, fixture_id
        LIMIT @limit
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'limit': limit.clamp(1, 100),
      },
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
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT fixture_id, result
        FROM football_simulation_results
        WHERE phase_two_scan_run_id = @scan_run_id
        ORDER BY fixture_id
        LIMIT @limit
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'limit': limit.clamp(1, 100),
      },
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
    int limit = 20,
  }) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        SELECT fixture_id, selection
        FROM football_market_selections
        WHERE phase_two_scan_run_id = @scan_run_id
        ORDER BY fixture_id
        LIMIT @limit
      '''),
      parameters: {
        'scan_run_id': phaseTwoScanRunId,
        'limit': limit.clamp(1, 100),
      },
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

  Future<Map<String, Object?>?> footballAsset({required String entityType, required String entityId}) async {
    final db = await connection();
    final result = await db.execute(Sql.named('''
      SELECT entity_type, entity_id, source_url, mime_type, image_bytes, size_bytes, updated_at
      FROM football_assets WHERE entity_type=@entity_type AND entity_id=@entity_id LIMIT 1
    '''), parameters: {'entity_type':entityType,'entity_id':entityId});
    if(result.isEmpty) return null;
    return Map<String,Object?>.from(result.first.toColumnMap());
  }

  Future<void> saveFootballAsset({required String entityType, required String entityId, required String sourceUrl, required String mimeType, required Uint8List imageBytes}) async {
    final db = await connection();
    await db.execute(Sql.named('''
      INSERT INTO football_assets(entity_type,entity_id,source_url,mime_type,image_bytes,size_bytes,updated_at)
      VALUES(@entity_type,@entity_id,@source_url,@mime_type,@image_bytes,@size_bytes,NOW())
      ON CONFLICT(entity_type,entity_id) DO UPDATE SET source_url=EXCLUDED.source_url,mime_type=EXCLUDED.mime_type,image_bytes=EXCLUDED.image_bytes,size_bytes=EXCLUDED.size_bytes,updated_at=NOW()
    '''), parameters:{'entity_type':entityType,'entity_id':entityId,'source_url':sourceUrl,'mime_type':mimeType,'image_bytes':imageBytes,'size_bytes':imageBytes.length});
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
