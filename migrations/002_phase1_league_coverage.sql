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
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

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
  PRIMARY KEY (league_id, season)
);

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
);

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
  completed_at TIMESTAMPTZ
);

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
);

INSERT INTO app_meta (key, value)
VALUES ('schema_version', '2')
ON CONFLICT (key) DO UPDATE
SET value = EXCLUDED.value, updated_at = NOW();
