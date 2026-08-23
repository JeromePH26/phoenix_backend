import 'dart:io';

import '../database/database.dart';
import '../model_lab/football_league_tier.dart';
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
    int? eligibleLimit,
    int backgroundFixtureLimit = 30,
    Future<void> Function(int processed, int total)? onProgress,
  }) async {
    final scanRunId = await database.createFootballScanRun(date);

    try {
      stdout.writeln('[PHOENIX PHASE1] Lade globalen Spieltag ${_day(date)}.');
      final matches = await football.matchesForDate(date);
      stdout.writeln(
        '[PHOENIX PHASE1] Provider-Spieltag geladen: ${matches.length} Fixtures.',
      );
      // Der Spielplan wird weltweit in den Datenpool übernommen. Nur die
      // Fokus-Ligen dürfen später in Phase 2 zur öffentlichen Analyse
      // weiterlaufen; Beobachtung und Datenpool bauen dagegen ausschließlich
      // Historie, Tabellen und spätere Shadow-/Learning-Daten auf.
      final knownTiers = await database.footballLeagueTiers(
        matches.map((match) => _string(match['leagueId'])),
      );
      final relevantMatches = matches.where((match) {
        final leagueId = _string(match['leagueId']);
        return leagueId.isNotEmpty &&
            (knownTiers[leagueId] ?? FootballLeagueTier.dataPool) !=
                FootballLeagueTier.blocked;
      }).toList(growable: false);
      final focusCount = relevantMatches.where((match) {
        return (knownTiers[_string(match['leagueId'])] ??
                FootballLeagueTier.dataPool) ==
            FootballLeagueTier.focus;
      }).length;

      // Öffentliche Fokus-Spiele dürfen nicht warten, bis mehrere hundert
      // Datenpool-Partien einzeln gespeichert wurden. Der Datenpool bleibt
      // aktiv, erhält pro Tageslauf aber ein festes Hintergrundbudget.
      final focusMatches = relevantMatches.where((match) {
        return (knownTiers[_string(match['leagueId'])] ??
                FootballLeagueTier.dataPool) ==
            FootballLeagueTier.focus;
      });
      final backgroundMatches = relevantMatches.where((match) {
        return (knownTiers[_string(match['leagueId'])] ??
                FootballLeagueTier.dataPool) !=
            FootballLeagueTier.focus;
      });
      final scheduledMatches = <Map<String, Object?>>[
        ...focusMatches,
        ...backgroundMatches.take(backgroundFixtureLimit.clamp(0, 100)),
      ];
      stdout.writeln(
        '[PHOENIX PHASE1] Datenpool: ${relevantMatches.length} Fixtures, '
        '$focusCount Fokus-Fixtures heute, ${scheduledMatches.length} '
        'davon in diesem Lauf eingeplant.',
      );
      final eligible = <Map<String, Object?>>[];
      final excluded = <Map<String, Object?>>[];
      final reasons = <String, int>{};
      final safeEligibleLimit = eligibleLimit?.clamp(1, 1000);
      var processed = 0;

      for (final match in scheduledMatches) {
        if (safeEligibleLimit != null && eligible.length >= safeEligibleLimit) {
          break;
        }
        processed++;
        final leagueId = _string(match['leagueId']);
        final tier = knownTiers[leagueId] ?? FootballLeagueTier.dataPool;
        await _ensureLeagueInDataPool(match);

        // Der Tages-Spielplan bleibt für jede nicht gesperrte Liga erhalten.
        // Dies ist bewusst der gemeinsame Datenpfad: Fokus, Beobachtung und
        // Datenpool nutzen später dieselben Tabellen, Teams und Ergebnisse.
        await database.upsertFootballMatchFromPayload(
          fixtureId: _string(match['id']),
          payload: match,
        );

        // Nur Fokus-Ligen erhalten eine Phase-2-Freigabe. Dadurch bleiben
        // öffentliche Analysen stabil, während alle anderen Ligen trotzdem
        // langfristig vollständige historische Daten aufbauen.
        final decision = tier == FootballLeagueTier.focus
            ? _decideWhitelisted(match)
            : _PhaseOneDecision(
                eligible: false,
                status: tier.storageKey,
                reason: 'background_${tier.storageKey}',
              );

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

        if (onProgress != null &&
            (processed == 1 ||
                processed % 10 == 0 ||
                processed == scheduledMatches.length)) {
          await onProgress(processed, scheduledMatches.length);
        }
      }

      final result = <String, Object?>{
        'scanRunId': scanRunId,
        'phase': 1,
        'date': _day(date),
        'total': processed,
        'totalAvailable': relevantMatches.length,
        'backgroundScheduled': scheduledMatches.length - focusCount,
        'eligibleCount': eligible.length,
        'excludedCount': excluded.length,
        'exclusionReasons': reasons,
        if (includeDetails) 'eligibleMatches': eligible,
        if (includeDetails) 'excludedMatches': excluded,
      };

      await database.completeFootballScanRun(
        scanRunId: scanRunId,
        totalMatches: processed,
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

  Future<void> _ensureLeagueInDataPool(Map<String, Object?> match) async {
    final leagueId = _string(match['leagueId']);
    final leagueName = _string(match['league']);
    final season = _int(match['season']);
    if (leagueId.isEmpty || leagueName.isEmpty || season <= 0) return;

    final level = _detectCompetitionLevel(leagueName);
    await database.upsertLeagueSeen(
      leagueId: leagueId,
      leagueName: leagueName,
      country: _string(match['country']),
      season: season,
      gender: _detectGender(leagueName),
      competitionLevel: level,
      initialHistoricalStatus: 'observation',
      initialSeasonStatus: 'observation',
    );
  }

  // Für eine spätere Rückkehr zu einer tier-übergreifenden Freigabe bleibt
  // die vollständige Prüfregel erhalten; aktuell nutzt die Pipeline bewusst
  // ausschließlich _decideWhitelisted für Fokus-Ligen.
  // ignore: unused_element
  Future<_PhaseOneDecision> _decide(Map<String, Object?> match) async {
    final fixtureId = _string(match['id']);
    final homeTeamId = _string(match['homeTeamId']);
    final awayTeamId = _string(match['awayTeamId']);
    final homeTeam = _string(match['homeTeam']).isNotEmpty
        ? _string(match['homeTeam'])
        : _string(match['homeTeamName']);
    final awayTeam = _string(match['awayTeam']).isNotEmpty
        ? _string(match['awayTeam'])
        : _string(match['awayTeamName']);

    final leagueId = _string(match['leagueId']);
    final leagueName = _string(match['league']);
    final country = _string(match['country']);
    final round = _string(match['round']);
    final season = _int(match['season']);
    final status = _string(match['status']).toUpperCase();
    final kickoff = DateTime.tryParse(_string(match['kickoff']))?.toUtc();

    // Absolutes Minimum:
    // Nur eine fehlende Spiel-ID oder komplett fehlende Teams schließen aus.
    // Liga, Saison, Tabelle, Form, xG und Quoten werden erst in späteren
    // Phasen bewertet und dürfen Phase 1 nicht mehr blockieren.
    final hasHomeTeam = homeTeamId.isNotEmpty || homeTeam.isNotEmpty;
    final hasAwayTeam = awayTeamId.isNotEmpty || awayTeam.isNotEmpty;

    if (fixtureId.isEmpty || !hasHomeTeam || !hasAwayTeam) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'missing_absolute_minimum',
      );
    }

    if (_isCancelledOrUnscheduled(status)) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'invalid_fixture_status',
      );
    }

    // PHÖNIX ist ein reines Pre-Match-System.
    // Nur eindeutig noch nicht gestartete Spiele dürfen weiter analysiert
    // werden. Laufende, pausierte und bereits beendete Partien werden hier
    // ausgeschlossen, bevor sie API-, Gemini- oder Simulationskosten erzeugen.
    if (status != 'NS') {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'not_pre_match',
      );
    }

    // Ein NS-Status allein reicht nicht aus: Der Anstoß muss parsebar sein
    // und tatsächlich noch in der Zukunft liegen. Dadurch werden verspätete
    // Provider-Updates und alte NS-Datensätze zuverlässig abgefangen.
    if (kickoff == null) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'missing_or_invalid_kickoff',
      );
    }

    if (!kickoff.isAfter(DateTime.now().toUtc())) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'kickoff_not_in_future',
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

    // Ohne eindeutige Liga-ID kann die feste Whitelist nicht geprüft werden.
    if (leagueId.isEmpty || leagueName.isEmpty || season <= 0) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'missing_whitelist_metadata',
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

      return const _PhaseOneDecision(
        eligible: false,
        status: 'observation',
        reason: 'not_whitelisted',
      );
    }

    await database.upsertLeagueSeen(
      leagueId: leagueId,
      leagueName: leagueName,
      country: country,
      season: season,
      gender: gender,
      competitionLevel: level,
      initialHistoricalStatus: _string(profile['historical_status']).isEmpty
          ? 'observation'
          : _string(profile['historical_status']),
      initialSeasonStatus: _string(profile['season_status']).isEmpty
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

    return const _PhaseOneDecision(
      eligible: false,
      status: 'observation',
      reason: 'not_whitelisted',
    );
  }

  _PhaseOneDecision _decideWhitelisted(Map<String, Object?> match) {
    final fixtureId = _string(match['id']);
    final homeTeamId = _string(match['homeTeamId']);
    final awayTeamId = _string(match['awayTeamId']);
    final homeTeam = _string(match['homeTeam']).isNotEmpty
        ? _string(match['homeTeam'])
        : _string(match['homeTeamName']);
    final awayTeam = _string(match['awayTeam']).isNotEmpty
        ? _string(match['awayTeam'])
        : _string(match['awayTeamName']);
    final status = _string(match['status']).toUpperCase();
    final kickoff = DateTime.tryParse(_string(match['kickoff']))?.toUtc();
    final leagueName = _string(match['league']);
    final round = _string(match['round']);

    if (fixtureId.isEmpty ||
        (homeTeamId.isEmpty && homeTeam.isEmpty) ||
        (awayTeamId.isEmpty && awayTeam.isEmpty)) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'missing_absolute_minimum',
      );
    }
    if (_isCancelledOrUnscheduled(status)) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'invalid_fixture_status',
      );
    }
    if (status != 'NS') {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'not_pre_match',
      );
    }
    if (kickoff == null || !kickoff.isAfter(DateTime.now().toUtc())) {
      return const _PhaseOneDecision(
        eligible: false,
        status: 'excluded',
        reason: 'kickoff_not_in_future',
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
    return const _PhaseOneDecision(
      eligible: true,
      status: 'approved',
      reason: null,
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
    if (RegExp(r'\b(3rd|third|liga 3|division 3|3\. liga)\b').hasMatch(value)) {
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
      'allsvenskan',
      'veikkausliiga',
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

  String _day(DateTime value) => '${value.year.toString().padLeft(4, '0')}-'
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
