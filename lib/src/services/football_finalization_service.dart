import '../database/database.dart';

class FootballFinalizationService {
  FootballFinalizationService({required this.database});

  final PhoenixDatabase database;

  Future<Map<String, Object?>> finalize({
    required int phaseTwoScanRunId,
  }) async {
    final rows = await database.footballFinalizationRows(phaseTwoScanRunId);
    final results = <Map<String, Object?>>[];

    for (final row in rows) {
      final selection = _map(row['selection']);
      if (selection['qualifiesForTip'] == false) continue;

      final phaseTwo = _map(row['phaseTwoPayload']);
      final phaseTwoMeta = _map(phaseTwo['phaseTwo']);
      final simulation = _map(row['simulation']);
      final aiOuter = _map(row['aiContext']);
      final ai = _map(aiOuter['context']);
      final phoenixTip = _map(selection['phoenixTip']);
      final bestMarket = phoenixTip.isNotEmpty
          ? phoenixTip
          : _map(selection['bestMarket']);
      final value = _map(selection['value']);
      final trust = _map(selection['trust']);

      final probability = _number(
        bestMarket['probability'] ?? bestMarket['modelProbability'],
      );
      final dataQuality = _integer(
        row['data_quality'] ?? phaseTwoMeta['dataQuality'],
      );

      var baseTrust = _integer(
        trust['score'] ?? selection['trustScore'],
      );
      if (baseTrust == 0) {
        baseTrust = _fallbackTrust(
          probability: probability,
          dataQuality: dataQuality,
        );
      }

      final rawAdjustment = _integer(ai['suggestedTrustAdjustment']);
      final aiAdjustment = rawAdjustment.clamp(-5, 5);
      final finalTrust = (baseTrust + aiAdjustment).clamp(0, 100);
      final isValueTip = value['isValueTip'] == true;
      final assignedUnits = _assignedUnits(
        isValueTip: isValueTip,
        finalTrust: finalTrust,
      );

      final kickoff =
          selection['kickoff']?.toString() ??
          simulation['kickoff']?.toString() ??
          phaseTwo['kickoff']?.toString() ??
          '';
      final parsedKickoff = DateTime.tryParse(kickoff);
      final tipDate = parsedKickoff?.toUtc().toIso8601String().substring(0, 10) ??
          DateTime.now().toUtc().toIso8601String().substring(0, 10);

      final tip = <String, Object?>{
        'phaseTwoScanRunId': phaseTwoScanRunId,
        'fixtureId': row['fixture_id']?.toString() ?? '',
        'tipDate': tipDate,
        'kickoff': kickoff,
        'homeTeam': selection['homeTeam'] ?? simulation['homeTeam'] ?? phaseTwo['homeTeam'],
        'awayTeam': selection['awayTeam'] ?? simulation['awayTeam'] ?? phaseTwo['awayTeam'],
        'league': selection['league'] ?? simulation['league'] ?? phaseTwo['league'],
        'marketKey': bestMarket['marketKey'] ?? bestMarket['key'],
        'marketLabel': bestMarket['market'] ?? bestMarket['label'],
        'modelProbability': probability,
        'fairOdds': _number(bestMarket['fairOdds']),
        'marketOdds': _number(value['marketOdds']),
        'valuePercent': _number(value['valuePercent']),
        'isValueTip': isValueTip,
        'dataQuality': dataQuality,
        'baseTrust': baseTrust,
        'aiTrustAdjustment': aiAdjustment,
        'finalTrust': finalTrust,
        'trustLevel': _trustLevel(finalTrust),
        'verificationStatus': ai['verificationStatus'] ?? 'not_checked',
        'contextEffect': ai['contextEffect'] ?? 'neutral',
        'lineupStatus': ai['lineupStatus'] ?? 'not_available',
        'explanation': ai['summary'] ??
            'PHÖNIX-Tipp auf Grundlage von Datenmodell und Simulation.',
        'contextPoints': ai['contextPoints'] ?? <Object?>[],
        'injuries': ai['injuries'] ?? <Object?>[],
        'sourceUrls': ai['sourceUrls'] ?? <Object?>[],
        'topScorelines': simulation['topScorelines'] ?? <Object?>[],
        'publicationStatus': finalTrust >= 50 ? 'published' : 'withheld',
        'assignedUnits': assignedUnits,
        'profitUnits': null,
        'resultStatus': 'pending',
        'engineRule':
            'Die Engine berechnet Wahrscheinlichkeit, faire Quote und Value. Gemini prüft ausschließlich den aktuellen Kontext.',
      };

      await database.saveFootballFinalTip(
        phaseTwoScanRunId: phaseTwoScanRunId,
        fixtureId: tip['fixtureId']!.toString(),
        tip: tip,
      );
      results.add(tip);
    }

    return {
      'status': 'completed',
      'phaseTwoScanRunId': phaseTwoScanRunId,
      'processed': rows.length,
      'published': results.where((e) => e['publicationStatus'] == 'published').length,
      'results': results,
    };
  }

  double _assignedUnits({
    required bool isValueTip,
    required int finalTrust,
  }) {
    if (!isValueTip || finalTrust < 50) return 0.0;
    if (finalTrust >= 90) return 2.5;
    if (finalTrust >= 80) return 2.0;
    if (finalTrust >= 70) return 1.5;
    if (finalTrust >= 60) return 1.0;
    return 0.5;
  }

  int _fallbackTrust({
    required double? probability,
    required int dataQuality,
  }) {
    final probabilityPart = ((probability ?? 0) * 0.35).round();
    final qualityPart = (dataQuality * 0.30).round();
    final stabilityPart = 8;
    final separationPart = 10;
    return (probabilityPart + qualityPart + stabilityPart + separationPart)
        .clamp(0, 100);
  }

  String _trustLevel(int score) {
    if (score >= 80) return 'high';
    if (score >= 65) return 'good';
    if (score >= 50) return 'medium';
    return 'low';
  }

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  int _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
