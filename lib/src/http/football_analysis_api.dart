import 'dart:async';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../database/database.dart';
import '../services/football_daily_pipeline_service.dart';
import 'json_response.dart';

class FootballAnalysisApi {
  FootballAnalysisApi({required this.database});

  final PhoenixDatabase database;

  static const _databaseTimeout = Duration(seconds: 8);

  Middleware get middleware => (Handler inner) => (Request request) async {
        if (request.method != 'GET') return inner(request);

        final match = RegExp(
          r'^api/football/analyses/(today|[0-9]{4}-[0-9]{2}-[0-9]{2})$',
        ).firstMatch(request.url.path);
        if (match == null) return inner(request);

        final value = match.group(1)!;
        final isToday = value == 'today';
        final date = isToday ? DateTime.now() : DateTime.tryParse(value);

        if (date == null) {
          return jsonResponse(
            {'error': 'Datum muss YYYY-MM-DD sein.'},
            statusCode: 400,
          );
        }

        final minimumDataQuality = int.tryParse(
              request.url.queryParameters['minimumQuality'] ?? '',
            ) ??
            (isToday ? 60 : 50);

        try {
          final matches = await _storedAnalyses(
            date: date,
            minimumDataQuality: minimumDataQuality,
          ).timeout(_databaseTimeout);

          return _analysisResponse(
            date: date,
            minimumDataQuality: minimumDataQuality,
            matches: matches,
          );
        } on TimeoutException {
          return _analysisResponse(
            date: date,
            minimumDataQuality: minimumDataQuality,
            matches: const [],
            databaseAvailable: false,
            status: 'Datenbank antwortet momentan nicht rechtzeitig.',
          );
        } catch (_) {
          return _analysisResponse(
            date: date,
            minimumDataQuality: minimumDataQuality,
            matches: const [],
            databaseAvailable: false,
            status: 'Gespeicherte Analysen sind momentan nicht verfügbar.',
          );
        }
      };

  Response _analysisResponse({
    required DateTime date,
    required int minimumDataQuality,
    required List<Map<String, Object?>> matches,
    bool databaseAvailable = true,
    String? status,
  }) {
    return jsonResponse(_jsonSafe({
      'sport': 'football',
      'date': _day(date),
      'source': 'database',
      'databaseAvailable': databaseAvailable,
      if (status != null) 'status': status,
      'minimumDataQuality': minimumDataQuality.clamp(0, 100),
      'count': matches.length,
      'matches': matches,
    }));
  }

  Future<List<Map<String, Object?>>> _storedAnalyses({
    required DateTime date,
    required int minimumDataQuality,
  }) async {
    if (!database.isConfigured) {
      return const <Map<String, Object?>>[];
    }

    final db = await database.connection();
    final safeQuality = minimumDataQuality.clamp(0, 100);
    final day = _day(date);

    final result = await db.execute(
      Sql.named(r'''
        WITH latest_job AS (
          SELECT phase_two_scan_run_id
          FROM football_daily_pipeline_jobs
          WHERE scan_date = CAST(@day AS DATE)
            AND status = 'completed'
            AND phase_two_scan_run_id IS NOT NULL
          ORDER BY id DESC
          LIMIT 1
        )
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
        FROM latest_job j
        INNER JOIN football_phase_two_results p
          ON p.scan_run_id = j.phase_two_scan_run_id
         AND p.analysis_allowed = TRUE
        INNER JOIN analyses a
          ON a.match_id = p.fixture_id
         AND a.sport = 'football'
        INNER JOIN football_matches m
          ON m.id = a.match_id
        WHERE a.data_quality >= @minimum_quality
          AND a.model_version = @model_version
          AND a.payload IS NOT NULL
        ORDER BY a.match_id, a.analyzed_at DESC
      '''),
      parameters: {
        'day': day,
        'minimum_quality': safeQuality,
        'model_version': FootballDailyPipelineService.publishedModelVersion,
      },
    );

    return result.map((row) {
      final values = Map<String, Object?>.from(row.toColumnMap());

      Map<String, Object?> mapValue(Object? value) {
        if (value is Map) return Map<String, Object?>.from(value);
        return <String, Object?>{};
      }

      final rawMatch = mapValue(values.remove('raw_json'));
      final analysis = mapValue(values.remove('analysis_payload'));

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

  Object? _jsonSafe(Object? value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }

    if (value is DateTime) return value.toUtc().toIso8601String();

    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _jsonSafe(item)),
      );
    }

    if (value is Iterable) return value.map(_jsonSafe).toList();

    return value.toString();
  }

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
