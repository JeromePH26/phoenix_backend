import '../database/database.dart';
import 'football_service.dart';

class FootballPhaseOneScanService {
  FootballPhaseOneScanService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  Future<Map<String, Object?>> run(
    DateTime date, {
    bool includeDetails = false,
  }) async {
    final scanRunId = await database.createFootballScanRun(date);

    try {
      final matches = await football.matchesForDate(date);
      final eligible = <Map<String, Object?>>[];
      final excluded = <Map<String, Object?>>[];
      final reasons = <String, int>{};

      for (final match in matches) {
        final decision = await _decide(match);

        await database.savePhaseOneDecision(
          scanRunId: scanRunId,
          fixtureId: _string(match['id']),
          leagueId: _string(match['leagueId']),
          season: _int(match['season']),
          eligible: decision.eligible,
          decisionStatus: decision.status,
          exclusionReason: decision.reason,
          payload: {
            ...match,
            'phaseOne': decision.toJson(),
          },
        );

        final enriched = <String, Object?>{
          ...match,
          'phaseOne': decision.toJson(),
        };

        if (decision.eligible) {
          eligible.add(enriched);
        } else {
          excluded.add(enriched);
          final reason = decision.reason ?? 'unknown';
          reasons[reason] = (reasons[reason] ?? 0) + 1;
        }
      }

      final result = <String, Object?>{
        'scanRunId': scanRunId,
        'phase': 1,
        'date': _day(date),
        'total': matches.length,
        'eligibleCount': eligible.length,
        'excludedCount': excluded.length,
        'exclusionReasons': reasons,
        if (includeDetails) 'eligibleMatches': eligible,
        if (includeDetails) 'excludedMatches': excluded,
      };

      await database.completeFootballScanRun(
        scanRunId: scanRunId,
        totalMatches: matches.length,
        eligibleMatches: eligible.length,
        excludedMatches: excluded.length,
        payload: {'exclusionReasons': reasons},
      );

      return result;
    } catch (error) {
      await database.failFootballScanRun(scanRunId, error);
      rethrow;
    }
  }

  Future<_PhaseOneDecision> _decide(Map<String, Object?> match) async {
    final leagueId = _string(match['leagueId']);
    final leagueName = _string(match['league']);
    final country = _string(match['country']);
    final round = _string(match['round']);
    final season = _int(match['season']);
    final status = _string(match['status']).toUpperCase();

    if (leagueId.isEmpty || leagueName.isEmpty || season <= 0) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'missing_basic_data',
      );
    }

    if (_isCancelledOrUnscheduled(status)) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'invalid_fixture_status',
      );
    }

    if (_isFriendly(leagueName, round)) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'friendly',
      );
    }

    if (_isYouthCompetition(leagueName, round)) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'youth_competition',
      );
    }

    final gender = _detectGender(leagueName);
    final level = _detectCompetitionLevel(leagueName);

    if (gender == 'women' &&
        level != 1 &&
        !_isWomenInternationalCup(leagueName)) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'women_below_first_tier',
      );
    }

    final knownTopCompetition = _isKnownTopCompetition(leagueName);
    final profile = await database.leagueProfile(leagueId, season);

    if (profile == null) {
      await database.upsertLeagueSeen(
        leagueId: leagueId,
        leagueName: leagueName,
        country: country,
        season: season,
        gender: gender,
        competitionLevel: level,
        initialHistoricalStatus:
            knownTopCompetition ? 'provisional' : 'observation',
        initialSeasonStatus:
            knownTopCompetition ? 'provisional' : 'observation',
      );

      if (knownTopCompetition) {
        return const _PhaseOneDecision(
          eligible: true,
          status: 'provisional',
          reason: null,
        );
      }

      return const _PhaseOneDecision(
        eligible: false,
        status: 'observation',
        reason: 'unknown_league',
      );
    }

    await database.upsertLeagueSeen(
      leagueId: leagueId,
      leagueName: leagueName,
      country: country,
      season: season,
      gender: gender,
      competitionLevel: level,
      initialHistoricalStatus:
          _string(profile['historical_status']).isEmpty
              ? 'observation'
              : _string(profile['historical_status']),
      initialSeasonStatus:
          _string(profile['season_status']).isEmpty
              ? 'observation'
              : _string(profile['season_status']),
    );

    final manualStatus = _string(profile['manual_status']);
    if (manualStatus == 'blacklist') {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'blacklist',
        reason: 'manual_blacklist',
      );
    }

    if (manualStatus == 'whitelist') {
      return const _PhaseOneDecision(
        eligible: true,
        status: 'approved',
        reason: null,
      );
    }

    final seasonStatus = _string(profile['season_status']);
    if (seasonStatus == 'approved' || seasonStatus == 'provisional') {
      return _PhaseOneDecision(
        eligible: true,
        status: seasonStatus,
        reason: null,
      );
    }

    if (seasonStatus == 'restricted') {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'restricted',
        reason: 'restricted_coverage',
      );
    }

    if (seasonStatus == 'blacklist') {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'blacklist',
        reason: 'automatic_blacklist',
      );
    }

    final historicalStatus = _string(profile['historical_status']);
    if (historicalStatus == 'approved' || knownTopCompetition) {
      return const _PhaseOneDecision(
        eligible: true,
        status: 'provisional',
        reason: null,
      );
    }

    return const _PhaseOneDecision(
      eligible: false,
      status: 'observation',
      reason: 'league_under_observation',
    );
  }

  bool _isCancelledOrUnscheduled(String status) =>
      const {'CANC', 'PST', 'ABD', 'AWD', 'WO'}.contains(status);

  bool _isFriendly(String leagueName, String round) {
    final value = '$leagueName $round'.toLowerCase();
    return value.contains('friendly') ||
        value.contains('friendlies') ||
        value.contains('club friendly') ||
        value.contains('international friendly') ||
        value.contains('test match') ||
        value.contains('testspiel');
  }

  bool _isYouthCompetition(String leagueName, String round) {
    final value = '$leagueName $round'.toLowerCase();

    final youthTokens = <RegExp>[
      RegExp(r'\bu17\b'),
      RegExp(r'\bu18\b'),
      RegExp(r'\bu19\b'),
      RegExp(r'\bu20\b'),
      RegExp(r'\bu21\b'),
      RegExp(r'\byouth\b'),
      RegExp(r'\bjuniors?\b'),
      RegExp(r'\bjunioren\b'),
      RegExp(r'\bprimavera\b'),
      RegExp(r'\bacademy\b'),
    ];

    return youthTokens.any((pattern) => pattern.hasMatch(value));
  }

  String _detectGender(String leagueName) {
    final value = leagueName.toLowerCase();
    if (value.contains('women') ||
        value.contains('women\'s') ||
        value.contains('frauen') ||
        value.contains('feminine') ||
        value.contains('féminine') ||
        value.contains('femenina') ||
        value.contains('femminile')) {
      return 'women';
    }
    return 'men';
  }

  int? _detectCompetitionLevel(String leagueName) {
    final value = leagueName.toLowerCase();

    if (RegExp(r'\b(2nd|second|liga 2|division 2|2\. liga|2\. bundesliga)\b')
        .hasMatch(value)) {
      return 2;
    }
    if (RegExp(r'\b(3rd|third|liga 3|division 3|3\. liga)\b')
        .hasMatch(value)) {
      return 3;
    }

    if (_isKnownTopCompetition(leagueName)) return 1;
    return null;
  }

  bool _isWomenInternationalCup(String leagueName) {
    final value = leagueName.toLowerCase();
    return value.contains('champions league women') ||
        value.contains('women champions league') ||
        value.contains('uefa women') ||
        value.contains('world cup women') ||
        value.contains('women world cup') ||
        value.contains('euro women') ||
        value.contains('women euro');
  }

  bool _isKnownTopCompetition(String leagueName) {
    final value = leagueName.toLowerCase();

    const knownNames = <String>[
      'premier league',
      'bundesliga',
      '2. bundesliga',
      '3. liga',
      'la liga',
      'serie a',
      'ligue 1',
      'eredivisie',
      'primeira liga',
      'super lig',
      'süper lig',
      'jupiler pro league',
      'austrian bundesliga',
      'super league',
      'major league soccer',
      'champions league',
      'europa league',
      'conference league',
      'dfb pokal',
      'fa cup',
      'copa del rey',
      'coppa italia',
      'coupe de france',
      'frauen-bundesliga',
      'women\'s super league',
      'division 1 feminine',
      'division 1 féminine',
      'liga f',
      'serie a women',
      'nwsl',
    ];

    return knownNames.any(value.contains);
  }

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _int(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _day(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class _PhaseOneDecision {
  const _PhaseOneDecision({
    required this.eligible,
    required this.status,
    required this.reason,
  });

  final bool eligible;
  final String status;
  final String? reason;

  Map<String, Object?> toJson() => {
        'eligible': eligible,
        'status': status,
        if (reason != null) 'reason': reason,
      };
}
