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
      CREATE TABLE IF NOT EXISTS football_phase_two_results (
        scan_run_id BIGINT NOT NULL REFERENCES football_scan_runs(id)
          ON DELETE CASCADE,
        fixture_id TEXT NOT NULL,
        league_id TEXT NOT NULL,
        season INTEGER NOT NULL,
        data_quality INTEGER NOT NULL,
        analysis_allowed BOOLEAN NOT NULL,
        availability JSONB NOT NULL,
        payload JSONB NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        PRIMARY KEY (scan_run_id, fixture_id)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_football_phase_two_quality
      ON football_phase_two_results (scan_run_id, data_quality)
    ''');

    await db.execute('''
      INSERT INTO app_meta (key, value)
      VALUES ('schema_version', '3')
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

    return result.map((row) {
      final map = Map<String, Object?>.from(row.toColumnMap());

      final lastSeenAt = map['last_seen_at'];
      if (lastSeenAt is DateTime) {
        map['last_seen_at'] = lastSeenAt.toUtc().toIso8601String();
      }

      return map;
    }).toList();
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


  Future<void> seedFootballStartLeagues({int season = 2026}) async {
    final leagues = <Map<String, Object?>>[
      {'league_id': '39', 'league_name': 'Premier League', 'country': 'England', 'level': 1},
      {'league_id': '61', 'league_name': 'Ligue 1', 'country': 'France', 'level': 1},
      {'league_id': '78', 'league_name': 'Bundesliga', 'country': 'Germany', 'level': 1},
      {'league_id': '79', 'league_name': '2. Bundesliga', 'country': 'Germany', 'level': 2},
      {'league_id': '80', 'league_name': '3. Liga', 'country': 'Germany', 'level': 3},
      {'league_id': '88', 'league_name': 'Eredivisie', 'country': 'Netherlands', 'level': 1},
      {'league_id': '94', 'league_name': 'Primeira Liga', 'country': 'Portugal', 'level': 1},
      {'league_id': '135', 'league_name': 'Serie A', 'country': 'Italy', 'level': 1},
      {'league_id': '140', 'league_name': 'La Liga', 'country': 'Spain', 'level': 1},
      {'league_id': '144', 'league_name': 'Jupiler Pro League', 'country': 'Belgium', 'level': 1},
    ];

    final db = await connection();

    for (final league in leagues) {
      await db.execute(
        Sql.named('''
          INSERT INTO football_leagues (
            league_id,
            league_name,
            country,
            gender,
            competition_level,
            manual_status,
            historical_status,
            last_seen_at,
            updated_at
          )
          VALUES (
            @league_id,
            @league_name,
            @country,
            'men',
            @competition_level,
            'whitelist',
            'provisional',
            NOW(),
            NOW()
          )
          ON CONFLICT (league_id) DO UPDATE SET
            league_name = EXCLUDED.league_name,
            country = EXCLUDED.country,
            gender = 'men',
            competition_level = EXCLUDED.competition_level,
            manual_status = 'whitelist',
            historical_status = CASE
              WHEN football_leagues.historical_status = 'approved'
                THEN 'approved'
              ELSE 'provisional'
            END,
            updated_at = NOW()
        '''),
        parameters: {
          'league_id': league['league_id'],
          'league_name': league['league_name'],
          'country': league['country'],
          'competition_level': league['level'],
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
            'provisional',
            NOW()
          )
          ON CONFLICT (league_id, season) DO UPDATE SET
            status = CASE
              WHEN football_league_seasons.status = 'approved'
                THEN 'approved'
              ELSE 'provisional'
            END,
            updated_at = NOW()
        '''),
        parameters: {
          'league_id': league['league_id'],
          'season': season,
        },
      );
    }
  }


  Future<int> createFootballPhaseTwoScanRun(DateTime scanDate) async {
    final db = await connection();
    final result = await db.execute(
      Sql.named('''
        INSERT INTO football_scan_runs (scan_date, phase, status)
        VALUES (@scan_date, 2, 'running')
        RETURNING id
      '''),
      parameters: {'scan_date': _dateOnly(scanDate)},
    );
    return result.first[0] as int;
  }

  Future<List<Map<String, Object?>>> eligiblePhaseOneMatches({
    int? scanRunId,
    int limit = 1,
  }) async {
    final db = await connection();
    final safeLimit = limit.clamp(1, 20);

    final result = await db.execute(
      Sql.named('''
        SELECT
          sm.fixture_id,
          sm.league_id,
          sm.season,
          sm.payload::text AS payload_text,
          sr.scan_date
        FROM football_scan_matches sm
        INNER JOIN football_scan_runs sr ON sr.id = sm.scan_run_id
        WHERE sm.eligible = TRUE
          AND sr.phase = 1
          AND sr.status = 'completed'
          AND sm.scan_run_id = COALESCE(
            @scan_run_id::BIGINT,
            (
              SELECT id
              FROM football_scan_runs
              WHERE phase = 1 AND status = 'completed'
              ORDER BY id DESC
              LIMIT 1
            )
          )
        ORDER BY sm.fixture_id
        LIMIT @limit
      '''),
      parameters: {
        'scan_run_id': scanRunId,
        'limit': safeLimit,
      },
    );

    return result.map((row) {
      final map = Map<String, Object?>.from(row.toColumnMap());
      final payloadText = map.remove('payload_text')?.toString() ?? '{}';
      final decoded = jsonDecode(payloadText);
      map['payload'] = decoded is Map
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
      final scanDate = map['scan_date'];
      if (scanDate is DateTime) {
        map['scan_date'] = scanDate.toUtc().toIso8601String();
      }
      return map;
    }).toList();
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
          scan_run_id,
          fixture_id,
          league_id,
          season,
          data_quality,
          analysis_allowed,
          availability,
          payload,
          updated_at
        )
        VALUES (
          @scan_run_id,
          @fixture_id,
          @league_id,
          @season,
          @data_quality,
          @analysis_allowed,
          CAST(@availability AS JSONB),
          CAST(@payload AS JSONB),
          NOW()
        )
        ON CONFLICT (scan_run_id, fixture_id) DO UPDATE SET
          data_quality = EXCLUDED.data_quality,
          analysis_allowed = EXCLUDED.analysis_allowed,
          availability = EXCLUDED.availability,
          payload = EXCLUDED.payload,
          updated_at = NOW()
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

  Future<void> close() async {
    await _connection?.close();
    _connection = null;
  }

  String _dateOnly(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
