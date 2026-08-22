import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:postgres/postgres.dart';

import '../config/app_config.dart';
import '../config/model_lab_config.dart';
import '../control_center/audit.dart';
import '../database/database.dart';
import '../model_lab/football_league_tier.dart';
import '../football_admin/football_admin_logic.dart';
import '../http/json_response.dart';
import 'app_account_routes.dart';
import 'control_center_routes.dart';
import 'model_lab_routes.dart';
import '../services/football_phase_one_scan_service.dart';
import '../services/football_phase_two_scan_service.dart';
import '../services/football_engine_input_service.dart';
import '../services/football_simulation_service.dart';
import '../services/football_market_selection_service.dart';
import '../services/football_value_service.dart';
import '../services/football_finalization_service.dart';
import '../services/football_result_settlement_service.dart';
import '../services/football_match_backfill_service.dart';
import '../services/historical_twin_service.dart';
import '../services/football_daily_pipeline_service.dart';
import '../services/football_league_catalog_service.dart';
import '../services/football_service.dart';
import '../services/football_asset_service.dart';
import '../services/football_news_service.dart';
import '../services/football_season_projection_service.dart';
import '../services/tennis_service.dart';

class ApiRoutes {
  ApiRoutes({
    required this.config,
    required this.database,
    required this.football,
    required this.tennis,
    required this.news,
    ModelLabConfig? modelLabConfig,
  }) : modelLabConfig = modelLabConfig ?? ModelLabConfig.fromEnvironment();

  final AppConfig config;
  final PhoenixDatabase database;
  final FootballService football;
  final TennisService tennis;
  final FootballNewsService news;
  final ModelLabConfig modelLabConfig;
  bool _leagueCatalogSyncInProgress = false;

  Router get router {
    final router = Router();

    // PHÖNIX MODEL LAB (Self-Learning Engine V0, Section 80): eigene
    // Admin-Routen-Gruppe, nutzt dieselbe Admin-Auth wie der Rest dieser
    // Datei. Vor allen anderen Routen eingehängt, damit `/api/admin/
    // model-lab/...` nicht von einer generischen `/api/admin/...`-Route
    // verschluckt wird.
    router.mount(
      '/api/admin/model-lab/',
      ModelLabRoutes(
        config: config,
        modelLabConfig: modelLabConfig,
        database: database,
      ).router.call,
    );

    // PHÖNIX CONTROL CENTER (internes Admin-Webapp-Backend, additiv): eigene
    // session-basierte Auth (admin_employees/admin_sessions), komplett
    // getrennt vom statischen PHOENIX_ADMIN_TOKEN oben. Ebenfalls vor allen
    // anderen Routen eingehängt, aus demselben Grund wie ModelLabRoutes.
    router.mount(
      '/api/admin/control-center/',
      ControlCenterRoutes(
        config: config,
        modelLabConfig: modelLabConfig,
        database: database,
        push: news.push,
      ).router.call,
    );

    // PHÖNIX ACCOUNT SYSTEM (Abschnitt 91, additiv): öffentlich erreichbare
    // App-Nutzer-Auth/-Profil-API, komplett getrennt von der
    // Control-Center-Mitarbeiter-Auth und vom statischen Admin-Token oben.
    router.mount(
      '/api/app/',
      AppAccountRoutes(config: config, database: database).router.call,
    );

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
          'tennis': tennis.isConfigured,
        },
      });
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

    // This feed is intentionally limited to reports generated from PHÖNIX
    // match data; imported publisher articles stay on the legacy endpoint.
    router.get('/api/phoenix/reports', (Request request) async {
      await news.refreshIfStale();
      final query = request.url.queryParameters;
      final articles = await database.newsArticles(
        teamId: query['teamId'],
        leagueId: query['leagueId'],
        category: query['category'],
        importantOnly: query['important'] == 'true',
        sourceName: 'PHOENIX',
        hours: int.tryParse(query['hours'] ?? '') ?? 336,
        limit: int.tryParse(query['limit'] ?? '') ?? 100,
      );
      return jsonResponse({'count': articles.length, 'articles': articles});
    });

    router.get('/api/football/season-projections', (Request request) async {
      final query = request.url.queryParameters;
      final season = int.tryParse(query['season'] ?? '');
      final projections = await database.seasonProjections(
        season: season,
        leagueId: query['leagueId'],
      );
      return jsonResponse(
          {'count': projections.length, 'projections': projections});
    });

    router.get('/api/football/daily-combo', (Request request) async {
      final requested = request.url.queryParameters['date'];
      final date =
          requested == null ? DateTime.now() : DateTime.tryParse(requested);
      if (date == null) {
        return jsonResponse(
          {'error': 'Datum muss YYYY-MM-DD sein.'},
          statusCode: 400,
        );
      }
      final combo = await database.footballDailyCombo(date);
      return jsonResponse({'combo': combo});
    });

    router.get('/api/admin/football/data-coverage', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final requested = request.url.queryParameters['date'];
      final date =
          requested == null ? DateTime.now() : DateTime.tryParse(requested);
      if (date == null) {
        return jsonResponse(
          {'error': 'Datum muss YYYY-MM-DD sein.'},
          statusCode: 400,
        );
      }
      final leagues = await database.footballWhitelistCoverage(date: date);
      final fixtures = leagues.fold<int>(
        0,
        (sum, league) =>
            sum + ((league['fixture_count'] as num?)?.toInt() ?? 0),
      );
      final analyses = leagues.fold<int>(
        0,
        (sum, league) =>
            sum + ((league['analysis_count'] as num?)?.toInt() ?? 0),
      );
      return jsonResponse({
        'date': date.toIso8601String().substring(0, 10),
        'fixtures': fixtures,
        'analyses': analyses,
        'coveragePercent': fixtures == 0
            ? 0
            : double.parse((analyses / fixtures * 100).toStringAsFixed(1)),
        'leagues': leagues,
      });
    });

    router.post('/api/admin/football/season-projections',
        (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final season = int.tryParse(request.url.queryParameters['season'] ?? '');
      final simulations =
          int.tryParse(request.url.queryParameters['simulations'] ?? '') ??
              10000;
      try {
        return jsonResponse(await FootballSeasonProjectionService(
          database: database,
          football: football,
        ).refresh(season: season, simulations: simulations));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
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

    // Historical Twins V1 (nur lesend, keine Wirkung auf die PHÖNIX-Engine -
    // siehe HistoricalTwinService-Dokumentation).
    router.get('/api/football/historical-twins/<fixtureId|[0-9]+>', (
      Request request,
      String fixtureId,
    ) async {
      if (!await database.moduleEnabled('historical_twins')) {
        return jsonResponse({'error': 'Historical Twins ist deaktiviert.'},
            statusCode: 503);
      }
      try {
        final result = await HistoricalTwinService(
          database: database,
        ).findTwins(fixtureId);
        return jsonResponse(result);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
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

    // Section 30/31: manuell verfasste PHÖNIX-News/FAQ (Control-Center-CMS).
    // Bewusst getrennt von /api/news (importierter + automatisch generierter
    // Feed, siehe FootballNewsService/PhoenixEditorialComposer).
    router.get('/api/news/phoenix', (Request request) async {
      if (!await database.moduleEnabled('news')) {
        return jsonResponse({'count': 0, 'articles': <Object?>[]});
      }
      final articles = await database.publicEditorialArticles();
      return jsonResponse({'count': articles.length, 'articles': articles});
    });

    router.get('/api/faq', (Request request) async {
      final articles = await database.publicFaqArticles();
      return jsonResponse({'count': articles.length, 'articles': articles});
    });

    // Section 32: Werbeflächen sind serverseitig fest vordefinierte Slots -
    // die App fragt gezielt einen Slot ab, keine freie Slot-Erstellung.
    router.get('/api/ads/<slot>', (Request request, String slot) async {
      if (!await database.moduleEnabled('advertising')) {
        return jsonResponse({'slot': slot, 'campaigns': <Object?>[]});
      }
      final campaigns = await database.activeAdCampaignsForSlot(slot);
      return jsonResponse({'slot': slot, 'campaigns': campaigns});
    });

    router.post('/api/ads/<id|[0-9]+>/impression', (
      Request request,
      String id,
    ) async {
      await database.recordAdImpression(int.parse(id));
      return jsonResponse({'status': 'recorded'});
    });

    router.post('/api/ads/<id|[0-9]+>/click', (
      Request request,
      String id,
    ) async {
      await database.recordAdClick(int.parse(id));
      return jsonResponse({'status': 'recorded'});
    });

    // Section 46: nur Lesezugriff für die App - Änderungen ausschließlich
    // über die Control-Center-Session-Auth (siehe control_center_routes.dart).
    router.get('/api/premium/features', (Request request) async {
      final features = await database.listPremiumFeatures();
      return jsonResponse({'features': features});
    });

    // Section 39/40: öffentlich lesbar, damit die App bei Start/Resume/
    // periodisch selbst prüfen kann, statt dass nur das Backend intern davon
    // weiß. Kein Admin-Token/Session nötig - dieselbe Auth-Konvention wie
    // /health (rein informativ, keine sensiblen Daten).
    router.get('/api/app-status', (Request request) async {
      try {
        final status = await database.appControlStatus();
        return jsonResponse({
          'status': status['status'],
          'message': status['message'],
          'maintenanceUntil': status['maintenance_until'],
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/modules', (Request request) async {
      try {
        final modules = await database.listModuleControls();
        return jsonResponse({
          'modules': {
            for (final module in modules)
              module['module_key'].toString(): module['enabled'],
          },
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Section 22: Support-Tickets. PHÖNIX hat kein Nutzerkonto-System, daher
    // an installation_id geknüpft statt an einen Account - gleiche
    // Auth-Konvention wie /api/push/*: x-phoenix-installation-id-Header bzw.
    // installationId im Body, kein Admin-Token.
    const validCategories = {'frage', 'bug', 'premium', 'match', 'sonstiges'};

    router.post('/api/support/tickets', (Request request) async {
      try {
        final body = jsonDecode(await request.readAsString());
        if (body is! Map<String, dynamic>) {
          return jsonResponse({'error': 'Ungültiger JSON-Body.'},
              statusCode: 400);
        }
        final installationId = body['installationId']?.toString().trim() ?? '';
        final subject = body['subject']?.toString().trim() ?? '';
        final message = body['message']?.toString().trim() ?? '';
        final category =
            body['category']?.toString().trim().toLowerCase() ?? 'sonstiges';
        if (installationId.length < 16 || subject.isEmpty || message.isEmpty) {
          return jsonResponse({
            'error': 'installationId, subject und message sind erforderlich.',
          }, statusCode: 400);
        }
        if (!validCategories.contains(category)) {
          return jsonResponse({
            'error':
                'category muss eines von ${validCategories.join(', ')} sein.',
          }, statusCode: 400);
        }
        final ticket = await database.createSupportTicket(
          installationId: installationId,
          category: category,
          subject: subject,
          message: message,
          appVersion: body['appVersion']?.toString(),
          platform: body['platform']?.toString(),
          osVersion: body['osVersion']?.toString(),
          deviceModel: body['deviceModel']?.toString(),
          matchId: body['matchId']?.toString(),
          screen: body['screen']?.toString(),
        );
        return jsonResponse({'ticket': ticket}, statusCode: 201);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 400);
      }
    });

    router.get('/api/support/tickets', (Request request) async {
      final installationId =
          request.headers['x-phoenix-installation-id']?.trim() ?? '';
      if (installationId.length < 16) {
        return jsonResponse({'error': 'Installation-ID fehlt.'},
            statusCode: 401);
      }
      final tickets =
          await database.supportTicketsForInstallation(installationId);
      return jsonResponse({'tickets': tickets});
    });

    router.get('/api/support/tickets/<id|[0-9]+>', (
      Request request,
      String id,
    ) async {
      final installationId =
          request.headers['x-phoenix-installation-id']?.trim() ?? '';
      if (installationId.length < 16) {
        return jsonResponse({'error': 'Installation-ID fehlt.'},
            statusCode: 401);
      }
      final ticket = await database.supportTicket(int.parse(id));
      if (ticket == null || ticket['installation_id'] != installationId) {
        return jsonResponse({'error': 'Ticket nicht gefunden.'},
            statusCode: 404);
      }
      final messages = await database.supportTicketMessages(
        int.parse(id),
        includeInternal: false,
      );
      return jsonResponse({'ticket': ticket, 'messages': messages});
    });

    router.post('/api/support/tickets/<id|[0-9]+>/reply', (
      Request request,
      String id,
    ) async {
      final installationId =
          request.headers['x-phoenix-installation-id']?.trim() ?? '';
      if (installationId.length < 16) {
        return jsonResponse({'error': 'Installation-ID fehlt.'},
            statusCode: 401);
      }
      final ticket = await database.supportTicket(int.parse(id));
      if (ticket == null || ticket['installation_id'] != installationId) {
        return jsonResponse({'error': 'Ticket nicht gefunden.'},
            statusCode: 404);
      }
      try {
        final body = jsonDecode(await request.readAsString());
        final message =
            body is Map ? body['message']?.toString().trim() ?? '' : '';
        if (message.isEmpty) {
          return jsonResponse({'error': 'message ist erforderlich.'},
              statusCode: 400);
        }
        // Nutzerantwort setzt ein wartendes Ticket wieder auf "neu für uns".
        await database.updateSupportTicket(
            id: int.parse(id), status: 'IN_BEARBEITUNG');
        final saved = await database.addSupportTicketMessage(
          ticketId: int.parse(id),
          authorType: 'user',
          message: message,
        );
        return jsonResponse({'message': saved}, statusCode: 201);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 400);
      }
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
          68.0;

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
        return jsonResponse(
          _jsonSafe({'count': leagues.length, 'leagues': leagues}),
        );
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/teams', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final query = request.url.queryParameters;
      final limit = clampListLimit(int.tryParse(query['limit'] ?? ''));
      final offset = clampOffset(int.tryParse(query['offset'] ?? ''));
      try {
        final result = await database.listFootballTeamsAdmin(
          search: query['search'],
          leagueId: query['leagueId'],
          country: query['country'],
          activeStatus: query['activeStatus'],
          dataStatus: query['dataStatus'],
          logoStatus: query['logoStatus'],
          analysesStatus: query['analysesStatus'],
          tipsStatus: query['tipsStatus'],
          sortBy: query['sortBy'] ?? 'name',
          sortDir: query['sortDir'] ?? 'asc',
          limit: limit,
          offset: offset,
        );
        return jsonResponse(_jsonSafe(result));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/teams/<id>', (
      Request request,
      String id,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      try {
        final team = await database.footballTeamDetail(id);
        if (team == null) {
          return jsonResponse({'error': 'Team nicht gefunden.'},
              statusCode: 404);
        }
        return jsonResponse(_jsonSafe(team));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/leagues/<leagueId>/teams', (
      Request request,
      String leagueId,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      try {
        final teams = await database.footballLeagueTeams(leagueId);
        return jsonResponse(_jsonSafe({'teams': teams}));
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
      // Section 8: "Statuswechsel nur mit Begründung, Bestätigung und
      // Audit-Eintrag" - vorher gab es weder eine Pflicht-Begründung noch
      // überhaupt einen Audit-Log-Eintrag für diese Aktion, obwohl sie
      // direkt steuert, was für App-Nutzer sichtbar ist.
      final reason = request.url.queryParameters['reason']?.trim() ?? '';
      if (reason.isEmpty) {
        return jsonResponse({
          'error': 'reason ist erforderlich.',
        }, statusCode: 400);
      }

      try {
        final previousStatus = await database.setFootballLeagueManualStatus(
          leagueId: leagueId,
          manualStatus: value,
        );
        if (previousStatus == null) {
          return jsonResponse({
            'error': 'Liga nicht gefunden.',
          }, statusCode: 404);
        }
        await database.insertAdminAuditLog(
          employeeId: null,
          employeeLogin: 'legacy_admin_token',
          area: 'football',
          objectType: 'league',
          objectId: leagueId,
          action: 'league.status_change',
          previousValue: {'manualStatus': previousStatus},
          newValue: {'manualStatus': value},
          reason: reason,
          ip: _clientIp(request),
        );
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
      if (!await database.moduleEnabled('settlement')) {
        return jsonResponse({
          'error': 'Modul "Settlement" ist deaktiviert (App Control → Module).',
        }, statusCode: 503);
      }
      final value = request.url.queryParameters['date'];
      final date = value == null ? DateTime.now() : DateTime.tryParse(value);
      final reconcile =
          request.url.queryParameters['reconcile']?.toLowerCase() == 'true';
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
          ).settle(date: date, reconcile: reconcile),
        );
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Backfill und wiederkehrender Check für football_matches.home_goals /
    // away_goals / status. Getrennt von /settle oben, das nur Tipps und
    // Tages-Kombis für die ROI-Historie abrechnet, nicht die Match-Zeile
    // selbst. Läuft asynchron, weil ein Backfill hunderte Fixtures in
    // gedrosselten Batches abfragen kann.
    router.post('/api/admin/football/matches/settle', (
      Request request,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      if (!await database.moduleEnabled('settlement')) {
        return jsonResponse({
          'error': 'Modul "Settlement" ist deaktiviert (App Control → Module).',
        }, statusCode: 503);
      }
      // Section 11: "Backfill gegen parallele Starts sperren" - zwei
      // gleichzeitige Läufe würden sich um dieselben Kandidaten und dasselbe
      // Provider-Tageslimit streiten, ohne dass eine der beiden Seiten davon
      // wüsste.
      if (await database.countPendingFootballMatchSettlementJobs() > 0) {
        return jsonResponse({
          'error':
              'Es läuft bereits ein Settlement-Lauf. Bitte warten, bis dieser abgeschlossen ist.',
        }, statusCode: 409);
      }
      final query = request.url.queryParameters;
      // Default 3h für den täglichen Check, Backfill-Aufrufe übergeben
      // bewusst minHours=4 gemäß Vorgabe.
      final minHours = (int.tryParse(query['minHoursSinceKickoff'] ?? '') ?? 3)
          .clamp(0, 24 * 30);
      final batchSize =
          (int.tryParse(query['batchSize'] ?? '') ?? 25).clamp(1, 100);

      final jobId = await database.createFootballMatchSettlementJob(
        minHoursSinceKickoff: minHours,
        batchSize: batchSize,
      );

      unawaited(
        FootballMatchBackfillService(
          database: database,
          football: football,
        ).run(
          jobId: jobId,
          minHoursSinceKickoff: minHours,
          batchSize: batchSize,
        ),
      );

      return jsonResponse({
        'status': 'started',
        'jobId': jobId,
        'minHoursSinceKickoff': minHours,
        'batchSize': batchSize,
        'statusUrl': '/api/admin/football/matches/settle/$jobId',
      }, statusCode: 202);
    });

    // Rein lesende Kontrollzahlen (dieselben Kennzahlen wie die manuelle
    // SQL-Kontrolle nach einem Backfill-Lauf), damit sie ohne direkten
    // Datenbankzugriff abgerufen werden können.
    router.get('/api/admin/football/matches/settle/coverage', (
      Request request,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      try {
        return jsonResponse(await database.footballMatchResultCoverage());
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Section 11: Kandidatenzahl vor Start eines Backfills, damit die UI
    // "X Spiele würden geprüft" zeigen kann statt den Lauf blind zu starten.
    router.get('/api/admin/football/matches/settle/candidates', (
      Request request,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final minHours = (int.tryParse(
                request.url.queryParameters['minHoursSinceKickoff'] ?? '',
              ) ??
              3)
          .clamp(0, 24 * 30);
      try {
        final count = await database.footballMatchResultCandidateCount(
          minHoursSinceKickoff: minHours,
        );
        return jsonResponse({
          'candidateCount': count,
          'minHoursSinceKickoff': minHours,
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Neueste Backfill-Läufe für das Control-Center-Settlement-Panel.
    router.get('/api/admin/football/matches/settle/recent', (
      Request request,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final limit =
          int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 1000;
      try {
        final jobs = await database.recentFootballMatchSettlementJobs(
          limit: limit,
        );
        return jsonResponse({'jobs': jobs});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/matches/settle/<jobId|[0-9]+>', (
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
      final job = await database.footballMatchSettlementJob(id);
      if (job == null) {
        return jsonResponse({'error': 'Job nicht gefunden.'}, statusCode: 404);
      }
      return jsonResponse(job);
    });

    // -----------------------------------------------------------------
    // CONTROL CENTER PHASE 2: Football-Domain-Admin-APIs (Matches,
    // Teams/Wappen & Assets, Datenqualität). Bewusst innerhalb der
    // bestehenden /api/admin/football/...-Gruppe und mit demselben
    // statischen PHOENIX_ADMIN_TOKEN geschützt wie alle anderen Routen
    // dieser Datei (_isAdmin() unten) - keine Verbindung zur getrennten
    // Control-Center-Session-Auth (lib/src/control_center/), die
    // Mitarbeiter-Identität für /api/admin/control-center/... abdeckt.
    // -----------------------------------------------------------------

    router.get('/api/admin/football/matches', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final query = request.url.queryParameters;
      final limit = clampListLimit(int.tryParse(query['limit'] ?? ''));
      final offset = clampOffset(int.tryParse(query['offset'] ?? ''));
      try {
        final result = await database.listFootballMatchesAdmin(
          date: query['date'],
          leagueId: query['leagueId'],
          teamId: query['teamId'],
          status: query['status'],
          visible: parseBoolParam(query['visible']),
          hasAnalysis: parseBoolParam(query['hasAnalysis']),
          hasTip: parseBoolParam(query['hasTip']),
          settled: parseBoolParam(query['settled']),
          limit: limit,
          offset: offset,
        );
        final matches = (result['matches'] as List<Map<String, Object?>>)
            .map(mapMatchRowToJson)
            .toList();
        return jsonResponse(_jsonSafe({
          'matches': matches,
          'count': result['total'],
          'limit': result['limit'],
          'offset': result['offset'],
        }));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/matches/<id>', (
      Request request,
      String id,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      try {
        final match = await database.footballMatchAdminDetail(id);
        if (match == null) {
          return jsonResponse({'error': 'Spiel nicht gefunden.'},
              statusCode: 404);
        }
        return jsonResponse(_jsonSafe(mapMatchRowToJson(match)));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.patch('/api/admin/football/matches/<id>', (
      Request request,
      String id,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(await request.readAsString());
        if (decoded is! Map<String, dynamic>) {
          return jsonResponse({'error': 'Ungültiger JSON-Body.'},
              statusCode: 400);
        }
        body = decoded;
      } catch (error) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'},
            statusCode: 400);
      }

      final patch = parseMatchFlagsPatch(body);
      if (!patch.isValid) {
        return jsonResponse({'error': patch.error}, statusCode: 400);
      }

      try {
        final previous = await database.updateFootballMatchFlags(
          id: id,
          flags: patch.flags,
        );
        if (previous == null) {
          return jsonResponse({'error': 'Spiel nicht gefunden.'},
              statusCode: 404);
        }

        final diff = diffEmployeeFields(
          before: previous,
          after: patch.flags,
        );

        await database.insertAdminAuditLog(
          employeeId: null,
          employeeLogin: 'legacy_admin_token',
          area: 'football',
          objectType: 'match',
          objectId: id,
          action: 'match.flags_update',
          previousValue: diff.previousValue,
          newValue: diff.newValue,
          reason: patch.reason,
          comment: patch.comment,
          ip: _clientIp(request),
        );

        return jsonResponse({
          'status': 'updated',
          'matchId': id,
          'flags': mapFlagsToJsonKeys(patch.flags),
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Manuelle Statusübersteuerung (z.B. ein abgesagtes Spiel): sperrt den
    // Status gegen den nächsten automatischen Provider-Sync und wirkt sofort
    // auf alles, was die App liest (siehe setFootballMatchStatusOverride).
    router.post('/api/admin/football/matches/<id>/status', (
      Request request,
      String id,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(await request.readAsString());
        if (decoded is! Map<String, dynamic>) {
          return jsonResponse({'error': 'Ungültiger JSON-Body.'},
              statusCode: 400);
        }
        body = decoded;
      } catch (_) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'},
            statusCode: 400);
      }

      final status = body['status']?.toString().trim() ?? '';
      final reason = body['reason']?.toString().trim() ?? '';
      if (status.isEmpty) {
        return jsonResponse({'error': 'status ist erforderlich.'},
            statusCode: 400);
      }
      if (reason.isEmpty) {
        return jsonResponse({'error': 'reason ist erforderlich.'},
            statusCode: 400);
      }

      try {
        final updated = await database.setFootballMatchStatusOverride(
          id: id,
          status: status,
          reason: reason,
        );
        if (updated == null) {
          return jsonResponse({'error': 'Spiel nicht gefunden.'},
              statusCode: 404);
        }

        await database.insertAdminAuditLog(
          employeeId: null,
          employeeLogin: 'legacy_admin_token',
          area: 'football',
          objectType: 'match',
          objectId: id,
          action: 'match.status_override',
          newValue: {'status': status},
          reason: reason,
          ip: _clientIp(request),
        );

        return jsonResponse(_jsonSafe({'match': updated}));
      } on ArgumentError catch (error) {
        return jsonResponse({'error': error.message.toString()},
            statusCode: 400);
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/api/admin/football/matches/<id>/status/clear', (
      Request request,
      String id,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      try {
        final updated = await database.clearFootballMatchStatusOverride(id);
        if (updated == null) {
          return jsonResponse({'error': 'Spiel nicht gefunden.'},
              statusCode: 404);
        }

        await database.insertAdminAuditLog(
          employeeId: null,
          employeeLogin: 'legacy_admin_token',
          area: 'football',
          objectType: 'match',
          objectId: id,
          action: 'match.status_override_clear',
          ip: _clientIp(request),
        );

        return jsonResponse(_jsonSafe({'match': updated}));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Section 14: eine Tippübersicht, die garantiert dieselbe Quelle wie die
    // App verwendet (letzte Analyse pro Fixture), mit Filtern für Mitarbeiter.
    router.get('/api/admin/football/tips', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final query = request.url.queryParameters;
      final limit = clampListLimit(int.tryParse(query['limit'] ?? ''));
      final offset = clampOffset(int.tryParse(query['offset'] ?? ''));
      try {
        final result = await database.listFootballTipsAdmin(
          dateFrom: query['dateFrom'],
          dateTo: query['dateTo'],
          leagueId: query['leagueId'],
          teamId: query['teamId'],
          marketKey: query['marketKey'],
          resultStatus: query['resultStatus'],
          minDataQuality: int.tryParse(query['minDataQuality'] ?? ''),
          minConfidence: int.tryParse(query['minConfidence'] ?? ''),
          modelVersion: query['modelVersion'],
          isValueTip: parseBoolParam(query['isValueTip']),
          hasTip: parseBoolParam(query['hasTip']),
          whitelistStatus: query['whitelistStatus'],
          limit: limit,
          offset: offset,
        );
        return jsonResponse(_jsonSafe(result));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/tips/<fixtureId>/history', (
      Request request,
      String fixtureId,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      try {
        final history = await database.footballAnalysisHistoryForFixture(
          fixtureId,
        );
        return jsonResponse(_jsonSafe({
          'fixtureId': fixtureId,
          'count': history.length,
          'history': history,
        }));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // Serverseitige Performance-Aggregation (Ligen-/Team-Analytics-Profile,
    // Punkt 23): rechnet immer über den vollständigen gefilterten
    // Datensatz, nie nur über eine Seite Tabellenzeilen.
    router.get('/api/admin/football/performance/aggregate', (
      Request request,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final query = request.url.queryParameters;
      DateTime? parseDate(String? raw) =>
          raw == null || raw.isEmpty ? null : DateTime.tryParse(raw);
      try {
        final result = await database.footballEntityPerformance(
          leagueId: query['leagueId'],
          teamId: query['teamId'],
          marketKey: query['marketKey'],
          dateFrom: parseDate(query['dateFrom']),
          dateTo: parseDate(query['dateTo']),
          homeAway: query['homeAway'],
          minDataQuality: int.tryParse(query['minDataQuality'] ?? ''),
          minConfidence: int.tryParse(query['minConfidence'] ?? ''),
          minValue: double.tryParse(query['minValue'] ?? ''),
          groupByTime: query['groupByTime'],
          includeMarketBreakdown: query['includeMarketBreakdown'] == 'true',
          includeTeamBreakdown: query['includeTeamBreakdown'] == 'true',
          includePreviousPeriod: query['includePreviousPeriod'] == 'true',
        );
        return jsonResponse(_jsonSafe(result));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    // "DATEN"-Tab im Ligen-/Team-Analytics-Profil: was hat PHÖNIX
    // tatsächlich gespeichert, pro Datenkategorie, ohne irgendetwas
    // hartzukodieren (Spec Punkt 17). Nicht zu verwechseln mit
    // /api/admin/football/data-coverage (Whitelist-Tagesreport).
    router.get('/api/admin/football/data-coverage-detail', (
      Request request,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final query = request.url.queryParameters;
      try {
        final result = await database.footballDataCoverage(
          leagueId: query['leagueId'],
          teamId: query['teamId'],
        );
        return jsonResponse(_jsonSafe(result));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/assets', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      try {
        final now = DateTime.now().toUtc();
        final inventory = await database.footballAssetInventory();
        final statusFilter =
            request.url.queryParameters['status']?.trim().toUpperCase();

        final assets = inventory
            .map((row) {
              final updatedAt = row['updated_at'] is DateTime
                  ? row['updated_at'] as DateTime
                  : null;
              final status = computeAssetStatus(
                cached: row['mime_type'] != null,
                hasBytes: row['has_bytes'] == true,
                updatedAt: updatedAt,
                now: now,
              );
              return <String, Object?>{
                'type': row['entity_type'],
                'id': row['entity_id'],
                'entityName': row['entity_name'],
                'mimeType': row['mime_type'],
                'updatedAt': updatedAt?.toIso8601String(),
                'status': status,
              };
            })
            .where(
              (row) => statusFilter == null || row['status'] == statusFilter,
            )
            .toList();

        return jsonResponse({'count': assets.length, 'assets': assets});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/api/admin/football/assets/<type>/<id>/replace', (
      Request request,
      String type,
      String id,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }

      final normalizedType = type.trim().toLowerCase();
      final normalizedId = id.trim();
      if (!FootballAssetService.allowedTypes.contains(normalizedType) ||
          normalizedId.isEmpty) {
        return jsonResponse({'error': 'Ungültiger Asset-Typ oder -ID.'},
            statusCode: 400);
      }

      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(await request.readAsString());
        if (decoded is! Map<String, dynamic>) {
          return jsonResponse({'error': 'Ungültiger JSON-Body.'},
              statusCode: 400);
        }
        body = decoded;
      } catch (error) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'},
            statusCode: 400);
      }

      final contentType = body['contentType']?.toString();
      List<int> bytes;
      try {
        bytes = base64Decode(body['imageBase64']?.toString() ?? '');
      } catch (error) {
        return jsonResponse({'error': 'imageBase64 ist ungültig.'},
            statusCode: 400);
      }

      final validationError = validateAssetReplacePayload(
        contentType: contentType,
        byteLength: bytes.length,
      );
      if (validationError != null) {
        return jsonResponse({'error': validationError}, statusCode: 400);
      }
      final normalizedContentType = contentType!.trim().toLowerCase();

      try {
        await database.archiveCurrentFootballAsset(
          type: normalizedType,
          id: normalizedId,
        );
        await database.saveFootballAsset(
          type: normalizedType,
          id: normalizedId,
          sourceUrl: 'admin:replace',
          mimeType: normalizedContentType,
          bytes: bytes,
        );

        await database.insertAdminAuditLog(
          employeeId: null,
          employeeLogin: 'legacy_admin_token',
          area: 'football',
          objectType: 'asset',
          objectId: '$normalizedType:$normalizedId',
          action: 'asset.replace',
          newValue: {
            'type': normalizedType,
            'id': normalizedId,
            'contentType': normalizedContentType,
            'byteLength': bytes.length,
          },
          ip: _clientIp(request),
        );

        return jsonResponse({
          'status': 'replaced',
          'type': normalizedType,
          'id': normalizedId,
          'contentType': normalizedContentType,
          'byteLength': bytes.length,
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/admin/football/assets/<type>/<id>/history', (
      Request request,
      String type,
      String id,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final normalizedType = type.trim().toLowerCase();
      final normalizedId = id.trim();
      try {
        final history = await database.footballAssetHistory(
          type: normalizedType,
          id: normalizedId,
        );
        return jsonResponse(_jsonSafe({'history': history}));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get(
      '/api/admin/football/assets/<type>/<id>/history/<historyId>/image',
      (Request request, String type, String id, String historyId) async {
        if (!_isAdmin(request)) {
          return Response.forbidden('Nicht autorisiert.');
        }
        final parsedHistoryId = int.tryParse(historyId);
        if (parsedHistoryId == null) {
          return Response.badRequest(body: 'Ungültige Archiv-ID.');
        }
        try {
          final image = await database.footballAssetHistoryImage(
            type: type.trim().toLowerCase(),
            id: id.trim(),
            historyId: parsedHistoryId,
          );
          if (image == null) {
            return Response.notFound('Archivierte Version nicht gefunden.');
          }
          final mimeType = image['mime_type']?.toString() ?? 'image/png';
          final bytes = base64Decode(
            image['content_base64']?.toString() ?? '',
          );
          return Response.ok(
            bytes,
            headers: {'content-type': mimeType, 'cache-control': 'no-store'},
          );
        } catch (error) {
          return Response.internalServerError(body: error.toString());
        }
      },
    );

    // `data-coverage` (oben) bleibt die aggregierte Whitelist-Sicht je Liga
    // und Tag. Diese Route ergänzt das um eine Sicht je einzelnem Match,
    // sortiert nach schlechtester Datenqualität zuerst - nutzt ausschließlich
    // real gespeicherte `analyses`-Spalten, keine neu erfundenen Scores.
    router.get('/api/admin/football/data-quality', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final requested = request.url.queryParameters['date'];
      final date =
          requested == null ? DateTime.now() : DateTime.tryParse(requested);
      if (date == null) {
        return jsonResponse({
          'error': 'Datum muss YYYY-MM-DD sein.',
        }, statusCode: 400);
      }
      final limit = clampListLimit(
        int.tryParse(request.url.queryParameters['limit'] ?? ''),
        defaultValue: 200,
        maxValue: 500,
      );
      try {
        final rows =
            await database.footballDataQualityRows(date: date, limit: limit);
        return jsonResponse(_jsonSafe({
          'date': _day(date),
          'count': rows.length,
          'matches': rows,
        }));
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.get('/api/football/performance', (Request request) async {
      final performance = await database.footballPerformanceSummary();
      return jsonResponse({
        ...performance,
        'dailyCombo': await database.footballDailyComboPerformance(),
      });
    });

    router.get('/api/football/history', (Request request) async {
      final query = request.url.queryParameters;
      final since = DateTime.tryParse(query['since'] ?? '') ??
          DateTime.now().toUtc().subtract(const Duration(days: 8));
      final history = await database.footballHistory(
        since: since,
        limit: int.tryParse(query['limit'] ?? '') ?? 500,
      );
      return jsonResponse({
        'since': since.toUtc().toIso8601String().substring(0, 10),
        'count': history.length,
        'history': history,
      });
    });

    router.get('/api/performance', (Request request) async {
      return jsonResponse({
        'football': {
          ...await database.footballPerformanceSummary(),
          'dailyCombo': await database.footballDailyComboPerformance(),
        },
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
      if (limit < 1 || limit > 1000) {
        return jsonResponse({
          'error': 'limit muss zwischen 1 und 1000 liegen.',
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

    router.post('/api/admin/football/leagues/<leagueId>/tier', (
      Request request,
      String leagueId,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      final value = request.url.queryParameters['value']?.trim() ?? '';
      final tier = FootballLeagueTier.values.where(
        (candidate) => candidate.storageKey == value,
      );
      if (tier.isEmpty) {
        return jsonResponse({
          'error': 'value muss focus, watchlist, data_pool oder blocked sein.',
        }, statusCode: 400);
      }
      final reason = request.url.queryParameters['reason']?.trim() ?? '';
      if (reason.isEmpty) {
        return jsonResponse({'error': 'reason ist erforderlich.'},
            statusCode: 400);
      }
      try {
        final selected = tier.first;
        final previous = await database.setFootballLeagueTier(
          leagueId: leagueId,
          tier: selected,
        );
        if (previous == null) {
          return jsonResponse({'error': 'Liga nicht gefunden.'}, statusCode: 404);
        }
        await database.insertAdminAuditLog(
          employeeId: null,
          employeeLogin: 'legacy_admin_token',
          area: 'football',
          objectType: 'league',
          objectId: leagueId,
          action: 'league.tier_change',
          previousValue: {'tier': previous},
          newValue: {'tier': selected.storageKey},
          reason: reason,
          ip: _clientIp(request),
        );
        return jsonResponse({
          'status': 'updated',
          'leagueId': leagueId,
          'tier': selected.storageKey,
        });
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 500);
      }
    });

    router.post('/api/admin/football/catalog/sync', (Request request) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      if (_leagueCatalogSyncInProgress) {
        return jsonResponse({
          'status': 'already_running',
          'message': 'Der Liga-Katalog wird bereits synchronisiert.',
        }, statusCode: 409);
      }

      _leagueCatalogSyncInProgress = true;
      unawaited(
        FootballLeagueCatalogService(database: database, football: football)
            .run()
            .then((result) {
          stdout.writeln('[PHOENIX CATALOG] Synchronisiert: $result');
        }).catchError((Object error, StackTrace stackTrace) {
          stderr.writeln('[PHOENIX CATALOG] Fehler: $error');
          stderr.writeln(stackTrace);
        }).whenComplete(() {
          _leagueCatalogSyncInProgress = false;
        }),
      );
      return jsonResponse({
        'status': 'started',
        'message': 'Liga-Katalog wird im Hintergrund in den Datenpool geladen.',
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

    // Break-glass-Passwort-Reset für Control-Center-Mitarbeiter (Section
    // 13-Vorbereitung: es gibt bislang keinen Self-Service-Reset über die
    // Session-Auth selbst - das wäre bei einem ausgesperrten letzten OWNER
    // ein Henne-Ei-Problem). Nur mit PHOENIX_ADMIN_TOKEN erreichbar, nicht
    // Teil der Control-Center-Session-Auth-Gruppe.
    router.post('/api/admin/control-center/employees/<login>/reset-password', (
      Request request,
      String login,
    ) async {
      if (!_isAdmin(request)) {
        return jsonResponse({'error': 'Nicht autorisiert.'}, statusCode: 401);
      }
      try {
        final body = jsonDecode(await request.readAsString());
        final newPassword =
            body is Map ? body['newPassword']?.toString() ?? '' : '';
        if (newPassword.length < 8) {
          return jsonResponse({
            'error': 'newPassword muss mindestens 8 Zeichen lang sein.',
          }, statusCode: 400);
        }
        final hash = BCrypt.hashpw(newPassword, BCrypt.gensalt());
        final updated = await database.resetAdminEmployeePasswordByLogin(
          login: login,
          passwordHash: hash,
        );
        if (!updated) {
          return jsonResponse({'error': 'Mitarbeiter nicht gefunden.'},
              statusCode: 404);
        }
        return jsonResponse({'status': 'password_reset', 'login': login});
      } catch (error) {
        return jsonResponse({'error': error.toString()}, statusCode: 400);
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
        SELECT DISTINCT ON (a.match_id)
          COALESCE(m.id, a.match_id) AS id,
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
        FROM analyses a
        LEFT JOIN football_matches m
          ON m.id = a.match_id
        LEFT JOIN LATERAL (
          -- Eine neue Scan-Ausführung darf bereits gespeicherte Analysen
          -- nicht verdrängen. Die Phase-2-Zeile ist nur der Rückfall, wenn
          -- ein historischer Match-Datensatz nicht mehr vorhanden ist.
          SELECT p.fixture_id, p.availability
          FROM football_daily_pipeline_jobs j
          INNER JOIN football_phase_two_results p
            ON p.scan_run_id = j.phase_two_scan_run_id
          WHERE j.scan_date = CAST(@day AS DATE)
            AND j.status = 'completed'
            AND p.fixture_id = a.match_id
          ORDER BY j.id DESC
          LIMIT 1
        ) p ON TRUE
        WHERE a.data_quality >= @minimum_quality
          AND a.sport = 'football'
          AND a.model_version = @model_version
          AND a.payload IS NOT NULL
          AND (
            (m.kickoff_utc AT TIME ZONE 'Europe/Berlin')::date =
                CAST(@day AS DATE)
            OR p.fixture_id IS NOT NULL
          )
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
          final selection = mapValue(analysis['selection']);
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

          String textValue(Object? primary, Object? fallback) {
            final primaryText = primary?.toString() ?? '';
            if (primaryText.trim().isNotEmpty) return primaryText;
            return fallback?.toString() ?? '';
          }

          return <String, Object?>{
            ...rawMatch,
            'id': textValue(
              values['id'],
              analysis['fixtureId'] ?? selection['fixtureId'],
            ),
            'kickoff': textValue(
              values['kickoff_utc'],
              analysis['kickoff'] ?? selection['kickoff'],
            ),
            'status': values['status']?.toString() ?? '',
            'leagueId': textValue(values['league_id'], analysis['leagueId']),
            'league': textValue(values['league_name'], analysis['league']),
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

  /// Bester verfügbarer Client-IP-Wert für den Audit-Log-Eintrag (gleiche
  /// Logik wie `ControlCenterRoutes._clientIp`, hier separat gehalten, weil
  /// diese Datei bewusst nicht von `control_center_routes.dart` importiert
  /// - beide Auth-Wege bleiben unabhängig voneinander).
  String? _clientIp(Request request) {
    final forwardedFor = request.headers['x-forwarded-for'];
    if (forwardedFor != null && forwardedFor.trim().isNotEmpty) {
      return forwardedFor.split(',').first.trim();
    }
    final connectionInfo = request.context['shelf.io.connection_info'];
    if (connectionInfo is HttpConnectionInfo) {
      return connectionInfo.remoteAddress.address;
    }
    return null;
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
