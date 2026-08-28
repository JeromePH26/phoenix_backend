import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'feature_renormalization.dart';
import 'fixture_form_filter.dart';

/// Section "GLOBAL GOALS V1": ein neues, gewichtetes Torerwartungs-Modell -
/// als Kernsignal der globalen Produktions-Engine. Die resultierende
/// Torerwartung wird im [PhoenixGlobalEngine] konservativ geglättet und –
/// wenn Pre-Match-Quoten vorhanden sind – gegen den entviggten Markt-Konsens
/// plausibilisiert.
///
/// Nutzt NUR Signale, die tatsächlich real gespeichert sind (siehe
/// `football_phase_two_results.availability`, dort insbesondere die
/// Roh-Arrays `standingsData`/`homeRecentData`/`awayRecentData`, die
/// `FootballService.coverageForFixture()` bereits vollständig persistiert).
/// xG/xGA, Schüsse/Chancenqualität und Match-Kontext/Motivation sind
/// strukturell nicht verfügbar und werden bewusst NICHT auf 0 gesetzt,
/// sondern ganz aus der Gewichtung entfernt (siehe [combineWeightedFeatures]).
class GlobalGoalsV1Engine {
  const GlobalGoalsV1Engine._();

  static const version = 'GLOBAL_GOALS_V1';

  /// GLOBAL_GOALS_V1 hat keinen freien Parameter (anders als `attackWeight`)
  /// - der Hash ist deshalb für jede Model-Lab-Instanz konstant. Die
  /// Eindeutigkeit pro Liga x Markt kommt aus dem Unique-Index auf
  /// `(market, league_id, config_hash)`, nicht aus diesem Hash selbst.
  static String configHash() => sha256.convert(utf8.encode(version)).toString();

  /// Bootstrap-Gewichte aus der Aufgabenstellung. `shots`/`motivation` bleiben
  /// dauerhaft 0 (nicht implementiert), analog zu `lineups`/`xG` im Original.
  static const Map<String, double> idealWeights = {
    'seasonAttack': 15,
    'seasonDefenseOpponent': 15,
    'recentFormAttack': 8,
    'recentFormDefenseOpponent': 8,
    'standingsGoalRateOpponentDefense': 8,
    'leagueGoalContext': 5,
    // Bewusst 0 - nicht auf 0 substituiert, sondern nie als Feature erzeugt:
    // 'xgXga': 30 (strukturell nie verfügbar von API-Football),
    // 'shotsChanceQuality': 7 (noch keine Extraktion aus den Rohdaten),
  };

  static GoalsV1Result compute({
    required Map<String, Object?> availability,
    required String homeTeamId,
    required String awayTeamId,
    double? leagueAvgHomeGoalsPerGame,
    double? leagueAvgAwayGoalsPerGame,
  }) {
    final standingsRows = _flattenStandings(availability['standingsData']);
    final homeStanding = _findTeamStanding(standingsRows, homeTeamId);
    final awayStanding = _findTeamStanding(standingsRows, awayTeamId);

    final homeRecent =
        _recentGoalsPerGame(availability['homeRecentData'], homeTeamId);
    final awayRecent =
        _recentGoalsPerGame(availability['awayRecentData'], awayTeamId);

    final homeResult = combineWeightedFeatures([
      WeightedFeature(
        key: 'seasonAttack',
        idealWeight: idealWeights['seasonAttack']!,
        value: _number(availability['homeGoalsForAverageHome']),
      ),
      WeightedFeature(
        key: 'seasonDefenseOpponent',
        idealWeight: idealWeights['seasonDefenseOpponent']!,
        value: _number(availability['awayGoalsAgainstAverageAway']),
      ),
      WeightedFeature(
        key: 'recentFormAttack',
        idealWeight: idealWeights['recentFormAttack']!,
        value: homeRecent?.scoredPerGame,
      ),
      WeightedFeature(
        key: 'recentFormDefenseOpponent',
        idealWeight: idealWeights['recentFormDefenseOpponent']!,
        value: awayRecent?.concededPerGame,
      ),
      WeightedFeature(
        key: 'standingsGoalRateOpponentDefense',
        idealWeight: idealWeights['standingsGoalRateOpponentDefense']!,
        value: awayStanding?.goalsAgainstPerGame,
      ),
      WeightedFeature(
        key: 'leagueGoalContext',
        idealWeight: idealWeights['leagueGoalContext']!,
        value: leagueAvgHomeGoalsPerGame,
      ),
    ]);

    final awayResult = combineWeightedFeatures([
      WeightedFeature(
        key: 'seasonAttack',
        idealWeight: idealWeights['seasonAttack']!,
        value: _number(availability['awayGoalsForAverageAway']),
      ),
      WeightedFeature(
        key: 'seasonDefenseOpponent',
        idealWeight: idealWeights['seasonDefenseOpponent']!,
        value: _number(availability['homeGoalsAgainstAverageHome']),
      ),
      WeightedFeature(
        key: 'recentFormAttack',
        idealWeight: idealWeights['recentFormAttack']!,
        value: awayRecent?.scoredPerGame,
      ),
      WeightedFeature(
        key: 'recentFormDefenseOpponent',
        idealWeight: idealWeights['recentFormDefenseOpponent']!,
        value: homeRecent?.concededPerGame,
      ),
      WeightedFeature(
        key: 'standingsGoalRateOpponentDefense',
        idealWeight: idealWeights['standingsGoalRateOpponentDefense']!,
        value: homeStanding?.goalsAgainstPerGame,
      ),
      WeightedFeature(
        key: 'leagueGoalContext',
        idealWeight: idealWeights['leagueGoalContext']!,
        value: leagueAvgAwayGoalsPerGame,
      ),
    ]);

    final expectedHome = homeResult.value?.clamp(0.20, 3.80).toDouble();
    final expectedAway = awayResult.value?.clamp(0.20, 3.80).toDouble();

    return GoalsV1Result(
      expectedHome: expectedHome,
      expectedAway: expectedAway,
      expectedTotal: (expectedHome != null && expectedAway != null)
          ? expectedHome + expectedAway
          : null,
      homeFeatureCoverage: _coverage(homeResult),
      awayFeatureCoverage: _coverage(awayResult),
      warnings: [
        if (expectedHome == null || expectedAway == null)
          'Keine ausreichenden Daten für GLOBAL_GOALS_V1 - alle Features fehlten.',
        'Keine echten xG/xGA-Daten vorhanden (strukturell nie verfügbar von API-Football).',
        'Schüsse/Chancenqualität noch nicht als Feature implementiert.',
        'Match-Kontext/Motivation noch nicht als Feature implementiert.',
      ],
    );
  }

  static Map<String, Object?> _coverage(RenormalizationResult result) => {
        'originalWeights': result.originalWeights,
        'effectiveWeights': result.effectiveWeights,
        'availableFeatures': result.availableFeatureKeys,
        'missingFeatures': result.missingFeatureKeys,
      };

  static List<Map<String, Object?>> _flattenStandings(Object? standingsData) {
    if (standingsData is! List) return const [];
    final rows = <Map<String, Object?>>[];
    for (final entry in standingsData) {
      if (entry is! Map) continue;
      final league = entry['league'];
      if (league is! Map) continue;
      final groups = league['standings'];
      if (groups is! List) continue;
      for (final group in groups) {
        if (group is! List) continue;
        for (final row in group) {
          if (row is Map) rows.add(Map<String, Object?>.from(row));
        }
      }
    }
    return rows;
  }

  static _StandingSnapshot? _findTeamStanding(
    List<Map<String, Object?>> rows,
    String teamId,
  ) {
    for (final row in rows) {
      final team = row['team'];
      if (team is! Map) continue;
      if (team['id']?.toString() != teamId) continue;
      final all = row['all'];
      if (all is! Map) continue;
      final played = _int(all['played']);
      if (played <= 0) continue;
      final goals = all['goals'];
      final goalsFor = goals is Map ? _number(goals['for']) : null;
      final goalsAgainst = goals is Map ? _number(goals['against']) : null;
      if (goalsFor == null || goalsAgainst == null) continue;
      return _StandingSnapshot(
        goalsForPerGame: goalsFor / played,
        goalsAgainstPerGame: goalsAgainst / played,
        played: played,
      );
    }
    return null;
  }

  static _RecentFormSnapshot? _recentGoalsPerGame(
    Object? recentData,
    String teamId,
  ) {
    if (recentData is! List || recentData.isEmpty) return null;
    var scored = 0.0;
    var conceded = 0.0;
    var counted = 0;
    // Section 4 (Claude AN2.txt): abgesagte/abgebrochene/ergebnislos
    // verschobene Spiele raus, Freundschaftsspiele nur als Lückenfüller -
    // siehe fixture_form_filter.dart für die geteilte Begründung.
    for (final entry in selectFormFixtures(recentData)) {
      final teams = entry['teams'];
      if (teams is! Map) continue;
      final home = teams['home'];
      final away = teams['away'];
      final homeId = home is Map ? home['id']?.toString() : null;
      final awayId = away is Map ? away['id']?.toString() : null;
      final goals = entry['goals'];
      if (goals is! Map) continue;
      final homeGoals = _number(goals['home']);
      final awayGoals = _number(goals['away']);
      if (homeGoals == null || awayGoals == null) continue;

      if (homeId == teamId) {
        scored += homeGoals;
        conceded += awayGoals;
        counted++;
      } else if (awayId == teamId) {
        scored += awayGoals;
        conceded += homeGoals;
        counted++;
      }
    }
    if (counted == 0) return null;
    return _RecentFormSnapshot(
      scoredPerGame: scored / counted,
      concededPerGame: conceded / counted,
      sampleSize: counted,
    );
  }

  static double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  static int _int(Object? value) => value is int
      ? value
      : value is num
          ? value.round()
          : int.tryParse(value?.toString() ?? '') ?? 0;
}

class _StandingSnapshot {
  const _StandingSnapshot({
    required this.goalsForPerGame,
    required this.goalsAgainstPerGame,
    required this.played,
  });
  final double goalsForPerGame;
  final double goalsAgainstPerGame;
  final int played;
}

class _RecentFormSnapshot {
  const _RecentFormSnapshot({
    required this.scoredPerGame,
    required this.concededPerGame,
    required this.sampleSize,
  });
  final double scoredPerGame;
  final double concededPerGame;
  final int sampleSize;
}

class GoalsV1Result {
  const GoalsV1Result({
    required this.expectedHome,
    required this.expectedAway,
    required this.expectedTotal,
    required this.homeFeatureCoverage,
    required this.awayFeatureCoverage,
    required this.warnings,
  });

  final double? expectedHome;
  final double? expectedAway;
  final double? expectedTotal;
  final Map<String, Object?> homeFeatureCoverage;
  final Map<String, Object?> awayFeatureCoverage;
  final List<String> warnings;

  Map<String, Object?> toJson() => {
        'version': GlobalGoalsV1Engine.version,
        'expectedHome': expectedHome,
        'expectedAway': expectedAway,
        'expectedTotal': expectedTotal,
        'homeFeatureCoverage': homeFeatureCoverage,
        'awayFeatureCoverage': awayFeatureCoverage,
        'warnings': warnings,
      };
}
