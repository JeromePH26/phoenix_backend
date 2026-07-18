import '../database/database.dart';

class FootballFinalizationService {
  FootballFinalizationService({required this.database});

  final PhoenixDatabase database;
  static const modelVersion = 'phoenix_full_v1';

  Future<Map<String, Object?>> finalize({
    required int phaseTwoScanRunId,
  }) async {
    final rows = await database.finalizationCandidates(
      phaseTwoScanRunId: phaseTwoScanRunId,
    );

    var published = 0;
    final outputs = <Map<String, Object?>>[];

    for (final row in rows) {
      final fixtureId = row['fixture_id']?.toString() ?? '';
      final payload = _map(row['payload']);
      final simulation = _map(row['simulation']);
      final selection = _map(row['selection']);
      final value = _map(selection['value']);
      final trust = _map(selection['trust']);
      final phaseFour = _map(simulation['phaseFour']);

      final dataQuality = _int(row['data_quality']);
      var confidence = _int(trust['score']) +
          _int(phaseFour['confidenceDelta']).clamp(-10, 5);
      confidence = confidence.clamp(0, 100);

      final probabilities = _map(simulation['probabilities']);
      final appProbabilities = {
        'home': _fraction(probabilities['homeWin']),
        'draw': _fraction(probabilities['draw']),
        'away': _fraction(probabilities['awayWin']),
        ...probabilities,
      };

      final phoenixTip = _map(selection['phoenixTip']);
      final recommendation = phoenixTip['market']?.toString();
      final publish = dataQuality >= 50 &&
          probabilities.isNotEmpty &&
          phaseFour['critical'] != true;

      final finalPayload = <String, Object?>{
        'fixtureId': fixtureId,
        'probabilities': appProbabilities,
        'fairOdds': simulation['fairOdds'],
        'goalExpectations': simulation['goalExpectations'],
        'topScores': simulation['topScores'],
        'stability': simulation['stability'],
        'phaseFour': phaseFour,
        'phoenixTip': phoenixTip,
        'value': value,
        'trust': {
          ...trust,
          'score': confidence,
        },
        'warnings': simulation['warnings'],
        'published': publish,
      };

      await database.upsertFootballMatchFromPayload(
        fixtureId: fixtureId,
        payload: payload,
      );
      await database.saveFinalFootballAnalysis(
        fixtureId: fixtureId,
        modelVersion: modelVersion,
        dataQuality: dataQuality,
        confidence: confidence,
        recommendation: recommendation,
        payload: finalPayload,
      );

      if (publish) published++;
      outputs.add(finalPayload);
    }

    return {
      'status': 'completed',
      'processed': outputs.length,
      'published': published,
      'results': outputs,
    };
  }

  double _fraction(Object? value) {
    final number = _number(value) ?? 0;
    return number > 1 ? number / 100 : number;
  }

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

  double? _number(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().replaceAll(',', '.') ?? '');
  }

  int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}
