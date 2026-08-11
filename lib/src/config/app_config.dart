import 'dart:io';

class AppConfig {
  const AppConfig({
    required this.port,
    required this.environment,
    required this.databaseUrl,
    required this.apiFootballKey,
    required this.apiBaseballKey,
    required this.apiSportsKey,
    required this.sportradarTennisApiKey,
    required this.sportradarAccessLevel,
    required this.sportradarLanguage,
    required this.adminToken,
    required this.firebaseProjectId,
    required this.firebaseServiceAccountJson,
  });

  final int port;
  final String environment;
  final String databaseUrl;
  final String apiFootballKey;
  final String apiBaseballKey;
  final String apiSportsKey;
  final String sportradarTennisApiKey;
  final String sportradarAccessLevel;
  final String sportradarLanguage;
  final String adminToken;
  final String firebaseProjectId;
  final String firebaseServiceAccountJson;

  bool get hasDatabase => databaseUrl.trim().isNotEmpty;
  bool get hasFootballApi => apiFootballKey.trim().isNotEmpty;
  bool get hasBaseballApi => apiBaseballKey.trim().isNotEmpty;
  bool get hasApiSports => apiSportsKey.trim().isNotEmpty;

  /// Ein API-Sports-Dashboard-Schluessel kann fuer die aktivierten Produkte
  /// verwendet werden. Einzelne Produkt-Keys bleiben optional moeglich.
  String apiSportsKeyFor(String product) {
    final normalized = product.trim().toUpperCase().replaceAll('-', '_');
    final specific = Platform.environment['API_${normalized}_KEY']?.trim();
    return specific?.isNotEmpty == true ? specific! : apiSportsKey;
  }

  bool get hasTennisApi => sportradarTennisApiKey.trim().isNotEmpty;
  bool get hasFirebasePush =>
      firebaseProjectId.isNotEmpty && firebaseServiceAccountJson.isNotEmpty;

  factory AppConfig.fromEnvironment() {
    String read(String key, [String fallback = '']) =>
        Platform.environment[key]?.trim() ?? fallback;

    return AppConfig(
      port: int.tryParse(read('PORT', '8080')) ?? 8080,
      environment: read('APP_ENV', 'production'),
      databaseUrl: read('DATABASE_URL'),
      apiFootballKey: read('API_FOOTBALL_KEY'),
      apiBaseballKey: read('API_BASEBALL_KEY', read('API_FOOTBALL_KEY')),
      apiSportsKey: read('API_SPORTS_KEY', read('API_FOOTBALL_KEY')),
      sportradarTennisApiKey: read('SPORTRADAR_TENNIS_API_KEY'),
      sportradarAccessLevel: read('SPORTRADAR_TENNIS_ACCESS_LEVEL', 'trial'),

      // Sportradar Tennis Trial unterstützt den englischen v3-Pfad
      // zuverlässig. "de" führte je nach Paket zu leeren Antworten/404.
      sportradarLanguage: read('SPORTRADAR_TENNIS_LANGUAGE', 'en'),

      adminToken: read('PHOENIX_ADMIN_TOKEN'),
      firebaseProjectId: read('FIREBASE_PROJECT_ID'),
      firebaseServiceAccountJson: read('FIREBASE_SERVICE_ACCOUNT_JSON'),
    );
  }
}
