import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';

import 'api/routes.dart';
import 'config/app_config.dart';
import 'control_center/bootstrap.dart';
import 'database/database.dart';
import 'http/football_analysis_api.dart';
import 'http/json_response.dart';
import 'http/phoenix_api_guard.dart';
import 'http/tennis_analysis_api.dart';
import 'config/model_lab_config.dart';
import 'model_lab/learning_market.dart';
import 'model_lab/model_registry_service.dart';
import 'services/football_service.dart';
import 'services/firebase_push_service.dart';
import 'services/football_favorite_live_monitor.dart';
import 'services/football_news_service.dart';
import 'services/football_odds_recheck_service.dart';
import 'services/push_schedule_service.dart';
import 'services/tennis_service.dart';

class PhoenixBackend {
  PhoenixBackend._({
    required this.config,
    required this.database,
    required this.handler,
    required this.football,
    required this.tennis,
    required this.favoriteLiveMonitor,
    required this.news,
    required this.pushSchedule,
    required this.oddsRecheck,
  });

  final AppConfig config;
  final PhoenixDatabase database;
  final Handler handler;
  final FootballService football;
  final TennisService tennis;
  final FootballFavoriteLiveMonitor favoriteLiveMonitor;
  final FootballNewsService news;
  final PushScheduleService pushSchedule;
  final FootballOddsRecheckService oddsRecheck;
  bool _databaseInitializing = false;

  /// Der HTTP-Server darf für den Railway-Healthcheck schon erreichbar sein,
  /// während idempotente Migrationen/Bootstraps laufen. Hintergrundjobs dürfen
  /// in diesem schmalen Zeitfenster aber noch nicht angelegt werden: Die
  /// Recovery-Routine markiert alte Jobs sonst kurz darauf als abgebrochen.
  bool get isDatabaseInitializing => _databaseInitializing;

  static Future<PhoenixBackend> create() async {
    final config = AppConfig.fromEnvironment();
    final database = PhoenixDatabase(config.databaseUrl);
    final football = FootballService(
      apiKey: config.apiFootballKey,
      database: database,
    );
    final tennis = TennisService(
      apiKey: config.sportradarTennisApiKey,
      accessLevel: config.sportradarAccessLevel,
      language: config.sportradarLanguage,
    );
    final push = FirebasePushService(
      projectId: config.firebaseProjectId,
      serviceAccountJson: config.firebaseServiceAccountJson,
    );
    final favoriteLiveMonitor = FootballFavoriteLiveMonitor(
      database: database,
      football: football,
      push: push,
    );
    final news = FootballNewsService(
      database: database,
      push: push,
      football: football,
    );
    final pushSchedule = PushScheduleService(database: database, push: push);
    final oddsRecheck = FootballOddsRecheckService(
      database: database,
      football: football,
    );

    late final PhoenixBackend backend;
    final routes = ApiRoutes(
      config: config,
      database: database,
      football: football,
      tennis: tennis,
      news: news,
      isDatabaseInitializing: () => backend.isDatabaseInitializing,
    );

    final apiGuard = PhoenixApiGuard(
      database: database,
      football: football,
      tennis: tennis,
    );

    final tennisAnalysisApi = TennisAnalysisApi(tennis: tennis);
    final footballAnalysisApi = FootballAnalysisApi(database: database);

    final pipeline = Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(corsHeaders())
        .addMiddleware(_errorMiddleware())
        // Muss vor ApiRoutes liegen, weil ApiRoutes sonst mit seiner
        // Catch-all-Route zuerst 404 zurückgibt.
        .addMiddleware(tennisAnalysisApi.middleware)
        .addMiddleware(apiGuard.middleware)
        // Liefert vorbereitete Football-Analysen aus PostgreSQL. Vor der
        // Auslieferung aktualisiert _preparedFootballAnalyses() in routes.dart
        // kurz Status/Endstand/Logos beim Datenanbieter (ein Aufruf für alle
        // Spiele des Tages), damit beendete Partien nicht als LIVE 0:0
        // stehen bleiben. Die eigentliche Analyse (Simulation, Value,
        // Empfehlung) kommt weiterhin ausschließlich aus der Datenbank.
        .addMiddleware(footballAnalysisApi.middleware)
        .addHandler(routes.router.call);

    if (config.hasFirebasePush && database.isConfigured) {
      favoriteLiveMonitor.start();
      pushSchedule.start();
    }
    if (database.isConfigured) news.start();
    if (database.isConfigured && football.isConfigured) oddsRecheck.start();

    backend = PhoenixBackend._(
      config: config,
      database: database,
      handler: pipeline,
      football: football,
      tennis: tennis,
      favoriteLiveMonitor: favoriteLiveMonitor,
      news: news,
      pushSchedule: pushSchedule,
      oddsRecheck: oddsRecheck,
    );
    return backend;
  }

  Future<HttpServer> serve() async {
    // Vor dem Öffnen des Servers setzen, damit ein sofort eintreffender
    // Admin-Request keinen Pipeline-Job zwischen Serverstart und Recovery
    // erzeugen kann. Die Initialisierung selbst bleibt asynchron und blockiert
    // somit weder das Binden des Ports noch Railways Healthcheck.
    if (database.isConfigured) {
      _databaseInitializing = true;
      unawaited(
        _initializeDatabase().whenComplete(() {
          _databaseInitializing = false;
        }),
      );
    }
    final server = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      config.port,
      shared: true,
    );

    return server;
  }

  Future<void> _bootstrapModelLabBaselines() async {
    try {
      final registry = ModelRegistryService(
        database: database,
        config: ModelLabConfig.fromEnvironment(),
      );
      for (final market in LearningMarket.values) {
        await registry.ensureGlobalBaseline(market.key);
      }
    } catch (error, stackTrace) {
      stderr.writeln('Model Lab baseline bootstrap failed: $error');
      stderr.writeln(stackTrace);
    }
  }

  Future<void> _initializeDatabase() async {
    try {
      await database.migrate();
      final interrupted = await database.failPipelineJobsFromEarlierServer();
      if (interrupted > 0) {
        stdout.writeln(
          'PHOENIX: $interrupted Job(s) (Tagesscan/Settlement) vom vorherigen Serverlauf beendet.',
        );
      }
    } catch (error, stackTrace) {
      stderr.writeln('Database migration failed: $error');
      stderr.writeln(stackTrace);
    }

    // Einmaliger Bootstrap des ersten OWNER-Mitarbeiters. Die Operation ist
    // bewusst idempotent und verändert eine bestehende Tabelle nicht.
    try {
      await ControlCenterBootstrap(database: database, config: config).run();
    } catch (error, stackTrace) {
      stderr.writeln('Control Center bootstrap failed: $error');
      stderr.writeln(stackTrace);
    }

    await _bootstrapModelLabBaselines();
  }

  Future<void> close() async {
    favoriteLiveMonitor.close();
    pushSchedule.close();
    oddsRecheck.close();
    news.close();
    football.close();
    tennis.close();
    await database.close();
  }
}

Middleware _errorMiddleware() => (Handler inner) => (Request request) async {
      try {
        return await inner(request);
      } catch (error, stackTrace) {
        stderr.writeln('Unhandled request error: $error');
        stderr.writeln(stackTrace);
        return jsonResponse(
          {'error': 'Interner Serverfehler.'},
          statusCode: 500,
        );
      }
    };
