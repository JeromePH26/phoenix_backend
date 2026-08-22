import '../database/database.dart';
import 'football_service.dart';

/// Synchronisiert den Provider-Wettbewerbskatalog mit dem PHÖNIX-Datenpool.
/// Neue Ligen starten immer als `data_pool`: Sie speichern langfristig
/// Tabellen-, Team- und Ergebnisdaten, erzeugen aber keine öffentlichen Tipps.
class FootballLeagueCatalogService {
  FootballLeagueCatalogService({required this.database, required this.football});

  final PhoenixDatabase database;
  final FootballService football;

  Future<Map<String, Object?>> run() async {
    final catalog = await football.activeLeagueCatalog();
    var imported = 0;
    var skipped = 0;

    for (final league in catalog) {
      final leagueId = _text(league['leagueId']);
      final name = _text(league['league']);
      final season = _integer(league['season']);
      if (leagueId.isEmpty || name.isEmpty || season <= 0) {
        skipped += 1;
        continue;
      }
      await database.upsertLeagueSeen(
        leagueId: leagueId,
        leagueName: name,
        country: _text(league['country']),
        season: season,
        gender: 'unknown',
        competitionLevel: _competitionLevel(league['type']),
        initialHistoricalStatus: 'observation',
        initialSeasonStatus: 'observation',
      );
      imported += 1;
    }

    return {
      'catalogEntries': catalog.length,
      'imported': imported,
      'skipped': skipped,
      'defaultTier': 'data_pool',
    };
  }

  int? _competitionLevel(Object? type) {
    // API-Football kennzeichnet Wettbewerbarten, aber keine verlässliche
    // nationale Stufennummer. Diese wird bei Bedarf im Control Center
    // gepflegt; eine erfundene 1 wäre fachlich schlechter als null.
    return null;
  }

  String _text(Object? value) => value?.toString().trim() ?? '';
  int _integer(Object? value) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? 0;
}
