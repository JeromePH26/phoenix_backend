import 'dart:async';
import 'dart:io';

import '../database/database.dart';
import 'football_engine_input_service.dart';
import 'football_background_enrichment_service.dart';
import 'football_daily_combo_service.dart';
import 'football_market_selection_service.dart';
import 'football_phase_one_scan_service.dart';
import 'football_phase_two_scan_service.dart';
import 'football_service.dart';
import 'football_simulation_service.dart';
import 'football_value_service.dart';

class FootballDailyPipelineService {
  FootballDailyPipelineService({
    required this.database,
    required this.football,
  });

  final PhoenixDatabase database;
  final FootballService football;

  // "gemini" bewusst NICHT mehr im Namen: der KI-Kontext-Schritt ist
  // deaktiviert (siehe Kommentar weiter unten), diese Version rechnet rein
  // statistisch. Ein Name mit "gemini" würde live KI-Beteiligung vortäuschen.
  static const publishedModelVersion =
      'phoenix_daily_pipeline_v10_stat_all_matches_100k';

  Future<void> run({
    required int jobId,
    required DateTime date,
    int? limit,
    // 0 statt vorher 60: jede gescannte Analyse soll gespeichert werden;
    // welche Tipps angezeigt werden, entscheidet weiterhin der App-seitige
    // minimumQuality-Filter beim Abruf, nicht dieser Speicher-Gate.
    int minimumDataQuality = 0,
    int simulations = 100000,
  }) async {
    try {
      // Kein fachliches 20er-Limit mehr: verarbeitet alle Spiele der festen
      // Liga-Whitelist. 1000 ist nur ein technischer Schutz gegen fehlerhafte
      // Providerantworten und liegt weit über der Whitelist-Tagesmenge.
      const effectiveLimit = 1000;
      final safeQuality = minimumDataQuality.clamp(0, 100);
      final safeSimulations = simulations.clamp(1000, 100000);

      await _step(jobId, 'phase1');
      stdout.writeln(
        '[PHOENIX PIPELINE] Job $jobId: Phase 1 startet '
        '(alle Whitelist-Spiele, Qualitätsminimum $safeQuality).',
      );
      final phaseOne = await FootballPhaseOneScanService(
        database: database,
        football: football,
      ).run(date, eligibleLimit: effectiveLimit);
      final phaseOneId = _integer(phaseOne['scanRunId']);
      stdout.writeln(
        '[PHOENIX PIPELINE] Job $jobId: Phase 1 fertig – '
        'gesamt=${_integer(phaseOne['total'])}, '
        'freigegeben=${_integer(phaseOne['eligibleCount'])}.',
      );

      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'running',
        currentStep: 'phase2_prepare',
        phaseOneScanRunId: phaseOneId,
      );

      final phaseTwoService = FootballPhaseTwoScanService(
        database: database,
        football: football,
      );

      // Phase 2 prüft bis zu 100 heutige Kandidaten auf ihre echte
      // Datenqualität. Erst danach verarbeiten Engine und Simulation
      // ausschließlich alle qualifizierten Whitelist-Spiele.
      final prepared = await phaseTwoService.prepare(
        phaseOneScanRunId: phaseOneId,
        limit: effectiveLimit,
        minimumDataQuality: safeQuality,
      );

      stdout.writeln(
        '[PHOENIX PIPELINE] Job $jobId: Phase 2 vorbereitet – '
        'Kandidaten=${_integer(prepared['limit'])}.',
      );

      if (prepared['started'] != true) {
        await _finish(
          jobId: jobId,
          step: 'no_eligible_matches',
          processed: 0,
          published: 0,
        );
        return;
      }

      final phaseTwoId = _integer(prepared['scanRunId']);

      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'running',
        currentStep: 'phase2_processing',
        phaseTwoScanRunId: phaseTwoId,
      );

      final phaseTwoResult = await phaseTwoService.processPrepared(prepared);
      final allowed = _integer(phaseTwoResult['allowed']);
      stdout.writeln(
        '[PHOENIX PIPELINE] Job $jobId: Phase 2 fertig – '
        'geprüft=${_integer(phaseTwoResult['checked'])}, freigegeben=$allowed.',
      );

      if (allowed <= 0) {
        await _finish(
          jobId: jobId,
          step: 'no_quality_matches',
          processed: _integer(phaseTwoResult['checked']),
          published: 0,
          phaseTwoId: phaseTwoId,
        );
        return;
      }

      // Ein KI-Kontext-Schritt (Verletzungen/Aufstellungen) lief hier früher
      // über eine football-spezifische GeminiContextService.verifyPhaseTwoMatches().
      // Diese Klasse existiert im Repo nicht mehr - gemini_context_service.dart
      // enthält inzwischen eine Tennis-Implementierung, und openai_context_service.dart
      // liefert ein anderes Antwortschema (verificationStatus/suggestedTrustAdjustment
      // statt applied/reliability/homeGoalDelta/awayGoalDelta), das
      // FootballEngineInputService._normalize() nicht versteht. Der Schritt wird
      // deshalb bewusst ausgelassen, statt eine Klasse einzubinden, deren Ausgabe
      // von der Engine stillschweigend ignoriert würde. FootballEngineInputService
      // fällt ohne Kontext automatisch auf die statistische Basis zurück, die
      // Pipeline bleibt also voll funktionsfähig.
      await _step(jobId, 'engine_input');
      final engineResult = await FootballEngineInputService(
        database: database,
      ).prepare(phaseTwoScanRunId: phaseTwoId, limit: effectiveLimit);

      final preparedInputs = _integer(engineResult['prepared']);
      stdout.writeln(
        '[PHOENIX PIPELINE] Job $jobId: Engine-Eingaben=$preparedInputs.',
      );
      if (preparedInputs <= 0) {
        throw StateError('Keine Engine-Eingaben wurden erzeugt.');
      }

      await _step(jobId, 'simulation');
      final simulationResult =
          await FootballSimulationService(database: database).run(
        phaseTwoScanRunId: phaseTwoId,
        limit: effectiveLimit,
        simulations: safeSimulations,
      );

      final simulated = _integer(simulationResult['processed']);
      stdout.writeln(
        '[PHOENIX PIPELINE] Job $jobId: Simulationen=$simulated.',
      );
      if (simulated <= 0) {
        throw StateError('Keine Simulation wurde erzeugt.');
      }

      await _step(jobId, 'market_selection');
      final marketResult =
          await FootballMarketSelectionService(database: database).select(
        phaseTwoScanRunId: phaseTwoId,
        limit: effectiveLimit,
        minimumProbability: 68,
      );

      final selected = _integer(marketResult['processed']);
      stdout.writeln(
        '[PHOENIX PIPELINE] Job $jobId: Marktauswahl=$selected.',
      );
      if (selected <= 0) {
        throw StateError('Keine Marktauswahl wurde erzeugt.');
      }

      await _step(jobId, 'value_check_optional');

      try {
        await FootballValueService(
          database: database,
          football: football,
        ).check(
          phaseTwoScanRunId: phaseTwoId,
          limit: effectiveLimit,
          minimumMarketOdds: 1.40,
          minimumValuePercent: 5,
        );
      } catch (_) {
        // Ohne Quote bleibt der PHÖNIX-Tipp sichtbar; nur Value fehlt.
      }

      await _step(jobId, 'publishing');
      final publishResult = await _publishAnalyses(
        phaseTwoScanRunId: phaseTwoId,
        date: date,
      );

      await _step(jobId, 'daily_combo');
      final rawPublished = publishResult['publishedAnalyses'];
      final publishedAnalyses = rawPublished is List
          ? rawPublished.map(_map).toList(growable: false)
          : const <Map<String, Object?>>[];
      final dailyCombo = await FootballDailyComboService(
        database: database,
      ).buildAndSave(date: date, analyses: publishedAnalyses);
      stdout.writeln(
        '[PHOENIX PIPELINE] Tages-Kombi: '
        '${dailyCombo == null ? 'keine geeigneten zwei Tipps' : 'erstellt'}',
      );

      await _finish(
        jobId: jobId,
        step: 'completed',
        processed: _integer(publishResult['processed']),
        published: _integer(publishResult['published']),
        phaseTwoId: phaseTwoId,
      );

      // Datenpool und Beobachtung laufen nach der öffentlichen Pipeline mit
      // festem Budget weiter. Sie schreiben dieselben Detail- und Coverage-
      // Daten, erzeugen aber keine Analysen oder Tipps.
      unawaited(
        FootballBackgroundEnrichmentService(
          database: database,
          football: football,
        ).run(date: date).then((result) {
          stdout.writeln('[PHOENIX BACKGROUND] $result');
        }).catchError((Object error, StackTrace stackTrace) {
          stderr.writeln('[PHOENIX BACKGROUND] Fehler: $error');
          stderr.writeln(stackTrace);
        }),
      );
    } catch (error, stackTrace) {
      stderr.writeln('[PHOENIX PIPELINE] Job $jobId fehlgeschlagen: $error');
      stderr.writeln(stackTrace);
      await database.updateFootballDailyPipelineJob(
        jobId: jobId,
        status: 'failed',
        currentStep: 'failed',
        error: error,
        completed: true,
      );
    }
  }

  Future<Map<String, Object?>> _publishAnalyses({
    required int phaseTwoScanRunId,
    required DateTime date,
  }) async {
    final rows = await database.finalizationCandidates(
      phaseTwoScanRunId: phaseTwoScanRunId,
    );

    var processed = 0;
    var published = 0;
    final publishedAnalyses = <Map<String, Object?>>[];

    for (final row in rows) {
      processed++;

      final fixtureId = _string(row['fixture_id']);
      final dataQuality = _integer(row['data_quality']);
      final matchPayload = _map(row['payload']);
      final simulation = _map(row['simulation']);
      final selection = _map(row['selection']);

      if (fixtureId.isEmpty || simulation.isEmpty || selection.isEmpty) {
        continue;
      }

      final rawProbabilities = _map(simulation['probabilities']);
      final rawFairOdds = _map(simulation['fairOdds']);
      // Same-game-Kombis und Doppelte Chance 12 sind bewusst kein Teil der
      // öffentlichen PHÖNIX-Märkte. Sie bleiben höchstens intern in einer
      // Simulation verfügbar, erscheinen aber nie mehr als Analyse-Tipp.
      bool hiddenMarket(String key) {
        final normalized = key.toLowerCase();
        return normalized.startsWith('combo') || normalized == 'dc12';
      }

      rawProbabilities.removeWhere((key, _) => hiddenMarket(key));
      rawFairOdds.removeWhere((key, _) => hiddenMarket(key));
      final publicSimulation = <String, Object?>{
        ...simulation,
        'probabilities': rawProbabilities,
        'fairOdds': rawFairOdds,
      };
      final analysisLead = _map(selection['phoenixTip']);
      final qualifiesForTip = selection['qualifiesForTip'] == true;
      final phoenixTip = qualifiesForTip ? analysisLead : <String, Object?>{};
      final trust = _map(selection['trust']);
      final aiContext = _map(simulation['aiContext']);

      final baseConfidence = _integer(trust['score']).clamp(0, 100);
      final contextConfidenceDelta = aiContext['applied'] == true
          ? _integer(aiContext['confidenceDelta']).clamp(-10, 5)
          : 0;
      final confidence = (baseConfidence + contextConfidenceDelta).clamp(
        0,
        100,
      );

      // Eine Markt-Führung bleibt als Analysehinweis erhalten. Als PHÖNIX-Tipp
      // wird sie jedoch nur veröffentlicht und gespeichert, wenn der strenge
      // Publish-Gate erfüllt ist. Sonst verfälschen Fallbacks die Trefferquote.
      final recommendation = _string(phoenixTip['market']);
      final marketKey = _string(phoenixTip['marketKey']);
      final publicSelection = <String, Object?>{
        ...selection,
        'analysisLead': analysisLead,
        'phoenixTip': phoenixTip,
        'display': {
          ..._map(selection['display']),
          'showPhoenixTip': qualifiesForTip,
        },
      };

      final homeProbability = _probability(
        rawProbabilities['home'] ?? rawProbabilities['homeWin'],
      );
      final drawProbability = _probability(rawProbabilities['draw']);
      final awayProbability = _probability(
        rawProbabilities['away'] ?? rawProbabilities['awayWin'],
      );

      final fairOdds = <String, Object?>{
        ...rawFairOdds,
        'home': rawFairOdds['home'] ?? rawFairOdds['homeWin'],
        'draw': rawFairOdds['draw'],
        'away': rawFairOdds['away'] ?? rawFairOdds['awayWin'],
        'homeWin': rawFairOdds['homeWin'] ?? rawFairOdds['home'],
        'awayWin': rawFairOdds['awayWin'] ?? rawFairOdds['away'],
        'over25': rawFairOdds['over25'],
        'under25': rawFairOdds['under25'],
        'bttsYes': rawFairOdds['bttsYes'],
        'bttsNo': rawFairOdds['bttsNo'],
      };

      final analysisPayload = <String, Object?>{
        ...matchPayload,
        'source': 'server_prepared',
        'modelVersion': publishedModelVersion,
        'dataQuality': dataQuality,
        'confidence': confidence,
        'baseConfidence': baseConfidence,
        'contextConfidenceDelta': contextConfidenceDelta,
        'recommendation': recommendation,
        'topTip': {
          'marketKey': marketKey,
          'market': recommendation,
          'probability': phoenixTip['probability'],
          'fairOdds': phoenixTip['fairOdds'],
        },
        'tracking': {
          'isPhoenixTopTip': recommendation.isNotEmpty,
          'roiRequiresVerifiedMarketOdds': true,
        },
        'probabilities': {
          ...rawProbabilities.map(
            (key, value) => MapEntry(key, _probability(value)),
          ),
          'home': homeProbability,
          'draw': drawProbability,
          'away': awayProbability,
          'homeWin': homeProbability,
          'awayWin': awayProbability,
          'over25': _probability(rawProbabilities['over25']),
          'under25': _probability(rawProbabilities['under25']),
          'bttsYes': _probability(rawProbabilities['bttsYes']),
          'bttsNo': _probability(rawProbabilities['bttsNo']),
        },
        'fairOdds': fairOdds,
        'marketOddsByKey': {
          ..._map(selection['marketOddsByKey']),
          if (marketKey.isNotEmpty)
            marketKey: _map(selection['value'])['marketOdds'],
        },
        'goalExpectations': simulation['goalExpectations'],
        'topScorelines': simulation['topScorelines'],
        'phoenixTip': phoenixTip,
        'analysisLead': analysisLead,
        'selection': publicSelection,
        'simulation': publicSimulation,
        'simulationCount': simulation['simulations'],
        'aiContext': aiContext,
        'contextApplied': aiContext['applied'] == true,
        'contextSource': aiContext['contextSource'],
        'contextSourceScanRunId': aiContext['contextSourceScanRunId'],
        'fallbackUsed': aiContext['fallbackUsed'] == true,
        'publishedAt': DateTime.now().toUtc().toIso8601String(),
        // Section "GLOBAL CHAMPION VERSIONIERUNG": rein dokumentarisch, ändert
        // keine Prediction-Werte. Benennt ehrlich, dass 1X2/BTTS/Totals/Team
        // Goals aktuell noch dieselbe Baseline-Formel teilen (siehe
        // FootballEngineInputService._averageAvailable): ein reiner
        // Torquote/Gegentorquote-Durchschnitt, gespeist in dieselbe
        // Poisson-Monte-Carlo-Simulation. DC/DNB sind bereits mathematisch aus
        // der 1X2-Verteilung abgeleitet, keine eigene Engine. Erst wenn eine
        // Engine-Familie durch ein echtes gewichtetes Feature-Modell ersetzt
        // wird, bekommt sie hier eine eigene V1-Kennung.
        'engineVersions': {
          'oneXTwo': 'GLOBAL_1X2_V0_BASELINE',
          'goals': 'GLOBAL_GOALS_V0_BASELINE',
          'btts': 'GLOBAL_BTTS_V0_BASELINE',
          'totals': 'GLOBAL_TOTALS_V0_BASELINE',
          'teamGoals': 'GLOBAL_TEAM_GOALS_V0_BASELINE',
          'doubleChance': 'DERIVED_FROM_1X2_V0_BASELINE',
          'drawNoBet': 'DERIVED_FROM_1X2_V0_BASELINE',
          'simulation': 'poisson_monte_carlo_v6_extended_markets',
        },
      };

      await database.upsertFootballMatchFromPayload(
        fixtureId: fixtureId,
        payload: matchPayload,
      );

      final inserted = await database.saveFinalFootballAnalysis(
        fixtureId: fixtureId,
        modelVersion: publishedModelVersion,
        dataQuality: dataQuality,
        confidence: confidence,
        recommendation: recommendation.isEmpty ? null : recommendation,
        payload: analysisPayload,
      );

      // Ein bereits veröffentlichter Tipp ist eingefroren. Kein zusätzlicher
      // History-Eintrag und keine neue Tages-Kombi aus einem späteren,
      // abweichenden Re-Scan dürfen ihn unbemerkt verändern.
      if (inserted) {
        await database.saveFootballAnalysisHistory(
          phaseTwoScanRunId: phaseTwoScanRunId,
          fixtureId: fixtureId,
          modelVersion: publishedModelVersion,
          dataQuality: dataQuality,
          confidence: confidence,
          payload: analysisPayload,
        );

        published++;
        publishedAnalyses.add(analysisPayload);
      }
    }

    return {
      'processed': processed,
      'published': published,
      'publishedAnalyses': publishedAnalyses,
    };
  }

  Future<void> _finish({
    required int jobId,
    required String step,
    required int processed,
    required int published,
    int? phaseTwoId,
  }) async {
    await database.updateFootballDailyPipelineJob(
      jobId: jobId,
      status: 'completed',
      currentStep: step,
      phaseTwoScanRunId: phaseTwoId,
      processed: processed,
      published: published,
      completed: true,
    );
    stdout.writeln(
      '[PHOENIX PIPELINE] Job $jobId abgeschlossen: '
      'step=$step processed=$processed published=$published',
    );
  }

  Future<void> _step(int jobId, String step) {
    stdout.writeln('[PHOENIX PIPELINE] Job $jobId: Schritt $step.');
    return database.updateFootballDailyPipelineJob(
      jobId: jobId,
      status: 'running',
      currentStep: step,
    );
  }

  double _probability(Object? value) {
    final number = _number(value) ?? 0;
    final decimal = number > 1 ? number / 100 : number;
    return double.parse(decimal.clamp(0.0, 1.0).toStringAsFixed(6));
  }

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  String _string(Object? value) => value?.toString().trim() ?? '';

  int _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
