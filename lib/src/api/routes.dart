import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:postgres/postgres.dart';

import '../config/app_config.dart';
import '../database/database.dart';
import '../http/json_response.dart';
import '../services/football_phase_one_scan_service.dart';
import '../services/football_phase_two_scan_service.dart';
import '../services/football_engine_input_service.dart';
import '../services/football_simulation_service.dart';
import '../services/football_market_selection_service.dart';
import '../services/football_value_service.dart';
import '../services/football_finalization_service.dart';
import '../services/football_result_settlement_service.dart';
import '../services/football_daily_pipeline_service.dart';
import '../services/football_service.dart';
import '../services/baseball_service.dart';
import '../services/api_sports_team_engine.dart';
import '../services/football_asset_service.dart';
import '../services/football_news_service.dart';
import '../services/tennis_service.dart';

class ApiRoutes {
  ApiRoutes({
    required this.config,
    required this.database,
    required this.football,
    required this.baseball,
    required this.teamSports,
    required this.tennis,
    required this.news,
  });

  final AppConfig config;
  final PhoenixDatabase database;
  final FootballService football;
  final BaseballService baseball;
  final Map<String, ApiSportsTeamEngine> teamSports;
  final TennisService tennis;
  final FootballNewsService news;

  Router get router {
    final router = Router();

    router.get('/health', (Request request) async {
      var databaseOk = false;
      String? databaseError;
      if (database.isConfigured) {
        try {
          databaseOk = await database.ping();
        } catch (error) {
          databaseError = error.toString();
        }
      }

      return jsonResponse({
        'status': 'ok',
        'service': 'phoenix-backend',
        'time': DateTime.now().toUtc().toIso8601String(),
        'environment': config.environment,
        'database': {
          'configured': database.isConfigured,
          'connected': databaseOk,
          if (databaseError != null) 'error': databaseError,
        },
        'providers': {
          'football': football.isConfigured,
          'baseball': baseball.isConfigured,
          'apiSports': {
            for (final entry in teamSports.entries)
              entry.key: {
                'configured': entry.value.isConfigured,
                'requestsUsedToday': entry.value.requestsToday,
                'dailySafetyLimit': ApiSportsTeamEngine.dailySafetyLimit,
              },
          },
          'tennis': tennis.isConfigured,
        },
      });
    });

    router.get('/api/sports/catalog', (Request request) {
      return jsonResponse({
        'dailySafetyLimit': ApiSportsTeamEngine.dailySafetyLimit,
        'sports': teamSports.entries
            .map(
              (entry) => {
                'id': entry.key,
                'configured': entry.value.isConfigured,
                'requestsUsedToday': entry.value.requestsToday,
              },
            )
            .toList(growable: false),
      });
    });

    router.get('/api/sports/<sport>/overview', (
      Request request,
      String sport,
    ) async {
      final engine = teamSports[sport.trim().toLowerCase()];
      if (engine == null) {
        return jsonResponse({'error': 'Unbekannte Team-Sportart.'},
            statusCode: 404);
      }
      final date = request.url.queryParameters['date']?.trim() ?? '';
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
        return jsonResponse({'error': 'Datum muss YYYY-MM-DD sein.'},
            statusCode: 400);
      }
      try {
        return jsonResponse(await engine.overview(date));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 503);
      }
    });

    router.get('/api/baseball/mlb/games', (Request request) async {
      final date = request.url.queryParameters['date']?.trim() ?? '';
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
        return jsonResponse({'error': 'Datum muss YYYY-MM-DD sein.'},
            statusCode: 400);
      }
      try {
        return jsonResponse(await baseball.mlbGames(date));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 503);
      }
    });

    router.get('/api/baseball/mlb/overview', (Request request) async {
      final date = request.url.queryParameters['date'] ?? '';
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
        return jsonResponse({'error': 'Ungültiges Datum.'}, statusCode: 400);
      }
      try {
        return jsonResponse(await baseball.mlbOverview(date));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });

    router.get('/api/assets/<type>/<id>', (
      Request request,
      String type,
      String id,
    ) async {
      try {
        return FootballAssetService(database: database).serve(
          type: type,
          id: id,
          sourceUrl: request.url.queryParameters['source'],
        );
      } catch (error) {
        return Response.internalServerError(body: error.toString());
      }
    });

    router.get('/api/football/provider', (Request request) async {
      final path = request.url.queryParameters['path'];
      if (path == null || path.trim().isEmpty) {
        return jsonResponse({
          'error': 'Query-Parameter path fehlt.',
        }, statusCode: 400);
      }

      final query = Map<String, String>.from(request.url.queryParameters)
        ..remove('path');

      try {
        final payload = await football.providerRequest(
          path: path,
          query: query,
        );
        return jsonResponse(payload);
      } on ArgumentError catch (error) {
        return jsonResponse({
          'error': error.message?.toString() ?? error.toString(),
        }, statusCode: 400);
      } catch (error) {
        if (_isOptionalFootballProviderPath(path)) {
          return jsonResponse({
            'get': path.replaceFirst('/', ''),
            'parameters': query,
            'errors': {'degraded': error.toString()},
            'results': 0,
            'paging': {'current': 1, 'total': 1},
            'response': const <Object?>[],
            'degraded': true,
          });
        }
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });

    router.get('/api/news', (Request request) async {
      await news.refreshIfStale();
      final query = request.url.queryParameters;
      final articles = await database.newsArticles(
        teamId: query['teamId'],
        leagueId: query['leagueId'],
        category: query['category'],
        importantOnly: query['important'] == 'true',
        hours: int.tryParse(query['hours'] ?? '') ?? 168,
        limit: int.tryParse(query['limit'] ?? '') ?? 80,
      );
      return jsonResponse({
        'count': articles.length,
        'articles': articles,
        'filters': {
          'teamId': query['teamId'],
          'leagueId': query['leagueId'],
          'category': query['category'],
          'important': query['important'] == 'true',
        },
      });
    });

    router.get('/api/football/analyses/today', (Request request) async {
      final quality =
          int.tryParse(request.url.queryParameters['minimumQuality'] ?? '') ??
              0;
      final date = _berlinNow();

      try {
        final matches = await _preparedFootballAnalyses(
          date: date,
          minimumDataQuality: quality,
        );
        return jsonResponse(
          _jsonSafe({
            'sport': 'football',
            'date': _day(date),
            'source': 'server_prepared',
            'minimumDataQuality': quality.clamp(0, 100),
            'count': matches.length,
            'matches': matches,
          }),
        );
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/football/analyses/<date|[0-9]{4}-[0-9]{2}-[0-9]{2}>', (
      Request request,
      String date,
    ) async {
      final parsed = DateTime.tryParse(date);
      if (parsed == null) {
        return jsonResponse({
          'error': 'Datum muss YYYY-MM-DD sein.',
        }, statusCode: 400);
      }

      final quality =
          int.tryParse(request.url.queryParameters['minimumQuality'] ?? '') ??
              0;

      try {
        final matches = await _preparedFootballAnalyses(
          date: parsed,
          minimumDataQuality: quality,
        );
        return jsonResponse(
          _jsonSafe({
            'sport': 'football',
            'date': _day(parsed),
            'source': 'server_prepared',
            'minimumDataQuality': quality.clamp(0, 100),
            'count': matches.length,
            'matches': matches,
          }),
        );
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Hinweis: /api/football/matches/today und /api/football/matches/<date>
    // werden nicht hier, sondern von PhoenixApiGuard.middleware bedient - sie
    // sitzt in app.dart vor diesem Router und fängt beide Pfade immer zuerst
    // ab (Whitelist-Filterung). Unfilterte Duplikate wurden entfernt, weil sie
    // nie erreicht wurden.

    router.get('/api/football/live/<fixtureId|[0-9]+>', (
      Request request,
      String fixtureId,
    ) async {
      try {
        final snapshot = await football.liveSnapshot(fixtureId);
        return jsonResponse(snapshot);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });

    router.post('/api/push/devices', (Request request) async {
      try {
        final body = jsonDecode(await request.readAsString());
        if (body is! Map<String, dynamic>) {
          return jsonResponse({'error': 'Ungültiger JSON-Body.'},
              statusCode: 400);
        }
        final installationId = body['installationId']?.toString().trim() ?? '';
        final pushToken = body['pushToken']?.toString().trim() ?? '';
        final platform =
            body['platform']?.toString().trim().toLowerCase() ?? '';
        if (installationId.length < 16 ||
            pushToken.length < 20 ||
            !const {'android', 'ios'}.contains(platform)) {
          return jsonResponse({'error': 'Gerätedaten sind unvollständig.'},
              statusCode: 400);
        }
        await database.registerPushDevice(
          installationId: installationId,
          pushToken: pushToken,
          platform: platform,
          locale: body['locale']?.toString().trim() ?? 'de',
        );
        return jsonResponse({'status': 'registered'});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 400);
      }
    });

    router.get('/api/push/favorites', (Request request) async {
      final installationId =
          request.headers['x-phoenix-installation-id']?.trim() ?? '';
      if (installationId.length < 16) {
        return jsonResponse({'error': 'Installation-ID fehlt.'},
            statusCode: 401);
      }
      final fixtureIds = await database.footballFavorites(installationId);
      return jsonResponse({'fixtureIds': fixtureIds});
    });

    router.put('/api/push/favorites/<fixtureId|[0-9]+>', (
      Request request,
      String fixtureId,
    ) async {
      final installationId =
          request.headers['x-phoenix-installation-id']?.trim() ?? '';
      if (installationId.length < 16) {
        return jsonResponse({'error': 'Installation-ID fehlt.'},
            statusCode: 401);
      }
      await database.setFootballFavorite(
        installationId: installationId,
        fixtureId: fixtureId,
        favorite: true,
      );
      return jsonResponse({'status': 'favorite', 'fixtureId': fixtureId});
    });

    router.delete('/api/push/favorites/<fixtureId|[0-9]+>', (
      Request request,
      String fixtureId,
    ) async {
      final installationId =
          request.headers['x-phoenix-installation-id']?.trim() ?? '';
      if (installationId.length < 16) {
        return jsonResponse({'error': 'Installation-ID fehlt.'},
            statusCode: 401);
      }
      await database.setFootballFavorite(
        installationId: installationId,
        fixtureId: fixtureId,
        favorite: false,
      );
      return jsonResponse({'status': 'removed', 'fixtureId': fixtureId});
    });

    router.put('/api/push/favorite-<type|teams|leagues>/<entityId>', (
      Request request,
      String type,
      String entityId,
    ) async {
      final installationId =
          request.headers['x-phoenix-installation-id']?.trim() ?? '';
      if (installationId.length < 16 || entityId.trim().isEmpty) {
        return jsonResponse({'error': 'Gerätedaten fehlen.'}, statusCode: 401);
      }
      await database.setFavoriteEntity(
        installationId: installationId,
        entityType: type == 'teams' ? 'team' : 'league',
        entityId: entityId.trim(),
        favorite: true,
      );
      return jsonResponse({'status': 'favorite'});
    });

    router.delete('/api/push/favorite-<type|teams|leagues>/<entityId>', (
      Request request,
      String type,
      String entityId,
    ) async {
      final installationId =
          request.headers['x-phoenix-installation-id']?.trim() ?? '';
      if (installationId.length < 16 || entityId.trim().isEmpty) {
        return jsonResponse({'error': 'Gerätedaten fehlen.'}, statusCode: 401);
      }
      await database.setFavoriteEntity(
        installationId: installationId,
        entityType: type == 'teams' ? 'team' : 'league',
        entityId: entityId.trim(),
        favorite: false,
      );
      return jsonResponse({'status': 'removed'});
    });

    router.put('/api/push/settings/news', (Request request) async {
      final installationId =
          request.headers['x-phoenix-installation-id']?.trim() ?? '';
      if (installationId.length < 16) {
        return jsonResponse({'error': 'Installation-ID fehlt.'},
            statusCode: 401);
      }
      final body = jsonDecode(await request.readAsString());
      final enabled = body is Map && body['enabled'] == true;
      await database.setNewsNotifications(
        installationId: installationId,
        enabled: enabled,
      );
      return jsonResponse({'newsEnabled': enabled});
    });

    router.post('/api/admin/football/scan/phase1', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final dateValue = request.url.queryParameters['date'];
      final date =
          dateValue == null ? DateTime.now() : DateTime.tryParse(dateValue);

      if (date == null) {
        return jsonResponse({
          'error': 'Datum muss YYYY-MM-DD sein.',
        }, statusCode: 400);
      }

      try {
        final scanner = FootballPhaseOneScanService(
          database: database,
          football: football,
        );
        final includeDetails = request.url.queryParameters['details'] == 'true';
        final result = await scanner.run(date, includeDetails: includeDetails);
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });

    router.post('/api/admin/football/scan/phase2', (Request request) async {
      if (!_isAdmin(request))
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      final phaseOneScanRunId = int.tryParse(
        request.url.queryParameters['scanRunId'] ?? '',
      );
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 1;
      final minimumDataQuality = int.tryParse(
            request.url.queryParameters['minimumDataQuality'] ?? '',
          ) ??
          60;
      if (limit < 1 || limit > 20)
        return jsonResponse({
          'error': 'limit muss zwischen 1 und 20 liegen.',
        }, statusCode: 400);
      try {
        final scanner = FootballPhaseTwoScanService(
          database: database,
          football: football,
        );
        final prepared = await scanner.prepare(
          phaseOneScanRunId: phaseOneScanRunId,
          limit: limit,
          minimumDataQuality: minimumDataQuality,
        );
        if (prepared['started'] != true) return jsonResponse(prepared);
        unawaited(scanner.processPrepared(prepared));
        return jsonResponse({
          'status': 'started',
          'phase': 2,
          'scanRunId': prepared['scanRunId'],
          'limit': prepared['limit'],
          'minimumDataQuality': prepared['minimumDataQuality'],
          'statusUrl':
              '/api/admin/football/scan/phase2/${prepared['scanRunId']}',
        }, statusCode: 202);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });

    router.post('/api/admin/football/engine/prepare', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final phaseTwoScanRunId = int.tryParse(
        request.url.queryParameters['phase2ScanRunId'] ?? '',
      );
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 1;

      if (phaseTwoScanRunId == null) {
        return jsonResponse({
          'error': 'phase2ScanRunId fehlt.',
        }, statusCode: 400);
      }

      if (limit < 1 || limit > 20) {
        return jsonResponse({
          'error': 'limit muss zwischen 1 und 20 liegen.',
        }, statusCode: 400);
      }

      try {
        final service = FootballEngineInputService(database: database);
        final result = await service.prepare(
          phaseTwoScanRunId: phaseTwoScanRunId,
          limit: limit,
        );
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/api/admin/football/engine/simulate', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final phaseTwoScanRunId = int.tryParse(
        request.url.queryParameters['phase2ScanRunId'] ?? '',
      );
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 1;
      final simulations =
          int.tryParse(request.url.queryParameters['simulations'] ?? '') ??
              100000;

      if (phaseTwoScanRunId == null) {
        return jsonResponse({
          'error': 'phase2ScanRunId fehlt.',
        }, statusCode: 400);
      }

      if (limit < 1 || limit > 20) {
        return jsonResponse({
          'error': 'limit muss zwischen 1 und 20 liegen.',
        }, statusCode: 400);
      }

      if (simulations < 1000 || simulations > 100000) {
        return jsonResponse({
          'error': 'simulations muss zwischen 1000 und 100000 liegen.',
        }, statusCode: 400);
      }

      try {
        final service = FootballSimulationService(database: database);
        final result = await service.run(
          phaseTwoScanRunId: phaseTwoScanRunId,
          limit: limit,
          simulations: simulations,
        );
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/api/admin/football/engine/select-market', (
      Request request,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final phaseTwoScanRunId = int.tryParse(
        request.url.queryParameters['phase2ScanRunId'] ?? '',
      );
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 1;
      final minimumProbability = double.tryParse(
            request.url.queryParameters['minimumProbability'] ?? '',
          ) ??
          55.0;

      if (phaseTwoScanRunId == null) {
        return jsonResponse({
          'error': 'phase2ScanRunId fehlt.',
        }, statusCode: 400);
      }

      if (limit < 1 || limit > 20) {
        return jsonResponse({
          'error': 'limit muss zwischen 1 und 20 liegen.',
        }, statusCode: 400);
      }

      if (minimumProbability < 0 || minimumProbability > 100) {
        return jsonResponse({
          'error': 'minimumProbability muss zwischen 0 und 100 liegen.',
        }, statusCode: 400);
      }

      try {
        final service = FootballMarketSelectionService(database: database);
        final result = await service.select(
          phaseTwoScanRunId: phaseTwoScanRunId,
          limit: limit,
          minimumProbability: minimumProbability,
        );
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/api/admin/football/engine/check-value', (
      Request request,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final phaseTwoScanRunId = int.tryParse(
        request.url.queryParameters['phase2ScanRunId'] ?? '',
      );
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 1;
      final minimumMarketOdds = double.tryParse(
            request.url.queryParameters['minimumMarketOdds'] ?? '',
          ) ??
          1.40;
      final minimumValuePercent = double.tryParse(
            request.url.queryParameters['minimumValuePercent'] ?? '',
          ) ??
          5.0;

      if (phaseTwoScanRunId == null) {
        return jsonResponse({
          'error': 'phase2ScanRunId fehlt.',
        }, statusCode: 400);
      }

      if (limit < 1 || limit > 20) {
        return jsonResponse({
          'error': 'limit muss zwischen 1 und 20 liegen.',
        }, statusCode: 400);
      }

      try {
        final service = FootballValueService(
          database: database,
          football: football,
        );
        final result = await service.check(
          phaseTwoScanRunId: phaseTwoScanRunId,
          limit: limit,
          minimumMarketOdds: minimumMarketOdds,
          minimumValuePercent: minimumValuePercent,
        );
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/leagues', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 200;

      try {
        final leagues = await database.listFootballLeagueProfiles(limit: limit);
        return jsonResponse({'count': leagues.length, 'leagues': leagues});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/api/admin/football/leagues/<leagueId>/status', (
      Request request,
      String leagueId,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final value = request.url.queryParameters['value']?.trim() ?? '';
      if (!const {'auto', 'whitelist', 'blacklist'}.contains(value)) {
        return jsonResponse({
          'error': 'value muss auto, whitelist oder blacklist sein.',
        }, statusCode: 400);
      }

      try {
        final updated = await database.setFootballLeagueManualStatus(
          leagueId: leagueId,
          manualStatus: value,
        );
        if (!updated) {
          return jsonResponse({
            'error': 'Liga nicht gefunden.',
          }, statusCode: 404);
        }
        return jsonResponse({
          'status': 'updated',
          'leagueId': leagueId,
          'manualStatus': value,
        });
      } on ArgumentError catch (error) {
        return jsonResponse({
          'error': error.message?.toString() ?? error.toString(),
        }, statusCode: 400);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Zentraler, streng begrenzter Sportradar-Proxy. Der API-Key bleibt
    // ausschließlich auf Railway; die App übermittelt nur einen freigegebenen
    // Tennis-Pfad. Dadurch gibt es keinen Sportradar-Key mehr in der APK.
    router.get('/api/tennis/provider', (Request request) async {
      final path = request.url.queryParameters['path'];
      if (path == null || path.trim().isEmpty) {
        return jsonResponse({
          'error': 'Query-Parameter path fehlt.',
        }, statusCode: 400);
      }

      try {
        final payload = await tennis.providerRequest(path: path);
        return jsonResponse(payload);
      } on ArgumentError catch (error) {
        return jsonResponse({
          'error': error.message?.toString() ?? error.toString(),
        }, statusCode: 400);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 502);
      }
    });

    // Hinweis: /api/tennis/matches/today und /api/tennis/matches/<date>
    // werden ebenfalls ausschließlich von PhoenixApiGuard.middleware bedient
    // (Jugend-/Exhibition-Filterung), siehe Hinweis bei den Football-Routen
    // oben.

    router.post('/api/admin/football/finalize', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final scanId = int.tryParse(
        request.url.queryParameters['phase2ScanRunId'] ?? '',
      );
      if (scanId == null) {
        return jsonResponse({
          'error': 'phase2ScanRunId fehlt.',
        }, statusCode: 400);
      }
      try {
        final result = await FootballFinalizationService(
          database: database,
        ).finalize(phaseTwoScanRunId: scanId);
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/api/admin/football/settle', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final value = request.url.queryParameters['date'];
      final date = value == null ? DateTime.now() : DateTime.tryParse(value);
      if (date == null) {
        return jsonResponse({
          'error': 'Datum muss YYYY-MM-DD sein.',
        }, statusCode: 400);
      }
      try {
        return jsonResponse(
          await FootballResultSettlementService(
            database: database,
            football: football,
          ).settle(date: date),
        );
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/football/performance', (Request request) async {
      return jsonResponse(await database.footballPerformanceSummary());
    });

    router.get('/api/performance', (Request request) async {
      return jsonResponse({
        'football': await database.footballPerformanceSummary(),
        'baseball': await database.baseballPerformanceSummary(),
        'note':
            'ROI wird nur aus verifizierten Marktquoten und echten Einsätzen berechnet.',
      });
    });

    router.post('/api/admin/football/daily-scan', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final dateText = request.url.queryParameters['date'];
      final date =
          dateText == null ? DateTime.now() : DateTime.tryParse(dateText);
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 20;
      // 0 statt vorher 60: ein manuell ausgelöster Tagesscan soll standardmäßig
      // ebenfalls jede Analyse speichern, nicht nur die mit hoher Datenqualität.
      final minimumDataQuality = int.tryParse(
            request.url.queryParameters['minimumDataQuality'] ?? '',
          ) ??
          0;
      final simulations =
          int.tryParse(request.url.queryParameters['simulations'] ?? '') ??
              100000;

      if (date == null) {
        return jsonResponse({
          'error': 'Datum muss YYYY-MM-DD sein.',
        }, statusCode: 400);
      }
      if (limit < 1 || limit > 20) {
        return jsonResponse({
          'error': 'limit muss zwischen 1 und 20 liegen.',
        }, statusCode: 400);
      }

      final jobId = await database.createFootballDailyPipelineJob(
        date: date,
        limit: limit,
        minimumDataQuality: minimumDataQuality,
        simulations: simulations,
      );

      unawaited(
        FootballDailyPipelineService(
          database: database,
          football: football,
        ).run(
          jobId: jobId,
          date: date,
          limit: limit,
          minimumDataQuality: minimumDataQuality,
          simulations: simulations,
        ),
      );

      return jsonResponse({
        'status': 'started',
        'jobId': jobId,
        'date': _day(date),
        'limit': limit,
        'minimumDataQuality': minimumDataQuality,
        'simulations': simulations,
        'statusUrl': '/api/admin/football/daily-scan/$jobId',
      }, statusCode: 202);
    });

    router.get('/api/admin/football/daily-scan/<jobId|[0-9]+>', (
      Request request,
      String jobId,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final id = int.tryParse(jobId);
      if (id == null) {
        return jsonResponse({'error': 'Ungültige Job-ID.'}, statusCode: 400);
      }
      final job = await database.footballDailyPipelineJob(id);
      if (job == null) {
        return jsonResponse({'error': 'Job nicht gefunden.'}, statusCode: 404);
      }
      return jsonResponse(_jsonSafe(job));
    });

    router.post('/api/admin/migrate', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      try {
        await database.migrate();
        return jsonResponse({'status': 'migration_complete'});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.all(
      '/<ignored|.*>',
      (Request request) =>
          jsonResponse({'error': 'Route nicht gefunden.'}, statusCode: 404),
    );

    return router;
  }

  bool _isOptionalFootballProviderPath(String path) {
    const optionalPaths = <String>{
      '/fixtures/events',
      '/fixtures/statistics',
      '/fixtures/lineups',
      '/fixtures/headtohead',
      '/injuries',
      '/players',
      '/players/squads',
      '/teams/statistics',
      '/teams',
      '/leagues',
      '/coachs',
      '/transfers',
      '/trophies',
      '/sidelined',
      '/odds',
    };
    final normalized = path.startsWith('/') ? path : '/$path';
    return optionalPaths.contains(normalized);
  }

  Future<List<Map<String, Object?>>> _preparedFootballAnalyses({
    required DateTime date,
    // Die Pipeline speichert bewusst alle Whitelist-Spiele. Auch Spiele mit
    // dünner Datenlage müssen an die App gelangen; dort wird die Qualität
    // sichtbar bewertet, statt die Analyse vollständig verschwinden zu lassen.
    int minimumDataQuality = 0,
  }) async {
    final db = await database.connection();
    final safeQuality = minimumDataQuality.clamp(0, 100);
    final day = _day(date);

    // Vor der Ausgabe werden Status, Endstand und Logos einmal beim
    // Datenanbieter aktualisiert. Dadurch bleiben beendete Spiele nicht
    // fälschlich als LIVE 0:0 in der App stehen.
    try {
      final freshMatches = await football.matchesForDate(date);
      for (final match in freshMatches) {
        final fixtureId = match['id']?.toString() ?? '';
        if (fixtureId.isEmpty) continue;
        await database.upsertFootballMatchFromPayload(
          fixtureId: fixtureId,
          payload: match,
        );
      }
    } catch (_) {
      // Bei einem temporären Providerfehler bleiben die zuletzt gespeicherten
      // Daten verfügbar; die Analyse-API fällt nicht komplett aus.
    }

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
          p.availability AS phase_two_availability,
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

    return result
        .map((row) {
          final values = Map<String, Object?>.from(row.toColumnMap());

          Map<String, Object?> mapValue(Object? value) {
            if (value is Map) {
              return Map<String, Object?>.from(value);
            }
            if (value is String && value.trim().isNotEmpty) {
              try {
                final decoded = jsonDecode(value);
                if (decoded is Map) return Map<String, Object?>.from(decoded);
              } catch (_) {
                // Beschädigte historische JSON-Werte dürfen die Spielansicht
                // nicht blockieren; in diesem Fall lädt die App wie bisher nach.
              }
            }
            return <String, Object?>{};
          }

          final rawMatch = mapValue(values.remove('raw_json'));
          final analysis = mapValue(values.remove('analysis_payload'));
          final phaseTwoAvailability =
              mapValue(values.remove('phase_two_availability'));
          final existingPhaseTwo = mapValue(analysis['phaseTwo']);
          final enrichedAnalysis = <String, Object?>{
            ...analysis,
            'phaseTwo': <String, Object?>{
              ...existingPhaseTwo,
              // Der Scan hat diese Rohdaten bereits kontrolliert und in der
              // Datenbank gespeichert. Sie müssen an die App ausgeliefert
              // werden, damit Tabelle, Form und H2H sofort sichtbar sind,
              // ohne parallele Nachlade-Requests an den Free-Tarif.
              'availability': phaseTwoAvailability,
            },
          };

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
              ...enrichedAnalysis,
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

  Object? _jsonSafe(Object? value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }

    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }

    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _jsonSafe(item)),
      );
    }

    if (value is Iterable) {
      return value.map(_jsonSafe).toList();
    }

    return value.toString();
  }

  bool _isAdmin(Request request) {
    if (config.adminToken.isEmpty) return false;
    final header = request.headers['authorization'] ?? '';
    final expected = 'Bearer ${config.adminToken}';

    // Konstante Laufzeit statt String-Gleichheit, damit die Antwortzeit
    // keinen Rückschluss auf übereinstimmende Präfixe des Admin-Tokens erlaubt.
    if (header.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < header.length; i++) {
      diff |= header.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }

  String _day(DateTime value) => '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  DateTime _berlinNow() {
    final utc = DateTime.now().toUtc();
    final marchSwitch = _lastSundayUtc(utc.year, DateTime.march);
    final octoberSwitch = _lastSundayUtc(utc.year, DateTime.october);
    final summerTime =
        !utc.isBefore(marchSwitch) && utc.isBefore(octoberSwitch);
    return utc.add(Duration(hours: summerTime ? 2 : 1));
  }

  DateTime _lastSundayUtc(int year, int month) {
    final lastDay = DateTime.utc(year, month + 1, 0);
    final sunday = lastDay.subtract(Duration(days: lastDay.weekday % 7));
    return DateTime.utc(year, month, sunday.day, 1);
  }
}
