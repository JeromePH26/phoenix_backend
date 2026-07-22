import 'dart:math';

class TennisValueRiskService {
  const TennisValueRiskService();

  Map<String, Object?> calculate({
    required double probability,
    required List<double> odds,
    required double bankrollEuro,
    required int dataQuality,
    required double uncertainty,
    double kellyFactor = 0.25,
    double minimumEdgePercent = 5,
  }) {
    final valid = odds.where((v) => v > 1.01 && v < 100 && v.isFinite).toList()..sort();
    if (valid.length < 3) {
      return {
        'hasValue': false,
        'reason': 'Mindestens drei Buchmacherquoten erforderlich.',
        'bookmakerCount': valid.length,
        'recommendedStakePercent': 0.0,
        'recommendedStakeEuro': 0.0,
      };
    }

    final reference = _median(valid);
    final best = valid.last;
    final p = probability.clamp(0.01, 0.99);
    final fairOdds = 1 / p;
    final ev = p * reference;
    final edge = (ev - 1) * 100;
    final hasValue = edge >= minimumEdgePercent && dataQuality >= 60;

    final conservativeP = max(0.01, p - (uncertainty + (dataQuality < 80 ? 0.02 : 0.01)));
    final b = reference - 1;
    final fullKelly = max(0.0, ((b * conservativeP) - (1 - conservativeP)) / b);
    final fractionalKelly = fullKelly * kellyFactor.clamp(0.0, 0.5);

    final probabilityCap = p < 0.15 ? 0.5 : p < 0.30 ? 2.0 : 5.0;
    final qualityCap = dataQuality < 60 ? 0.0 : dataQuality < 70 ? 0.5 : dataQuality < 80 ? 1.5 : dataQuality < 90 ? 3.0 : 5.0;
    final stakePercent = hasValue ? min(fractionalKelly * 100, min(probabilityCap, qualityCap)) : 0.0;

    return {
      'referenceOdds': _r(reference),
      'bestOdds': _r(best),
      'fairOdds': _r(fairOdds),
      'expectedValueFactor': _r(ev),
      'edgePercent': _r(edge),
      'hasValue': hasValue,
      'bookmakerCount': valid.length,
      'kellyProbability': _r(conservativeP),
      'fullKellyPercent': _r(fullKelly * 100),
      'fractionalKellyFactor': kellyFactor,
      'fractionalKellyPercent': _r(fractionalKelly * 100),
      'recommendedStakePercent': _r(stakePercent),
      'recommendedStakeEuro': _r(bankrollEuro.clamp(0, double.infinity) * stakePercent / 100),
    };
  }

  double _median(List<double> values) {
    final mid = values.length ~/ 2;
    return values.length.isOdd ? values[mid] : (values[mid - 1] + values[mid]) / 2;
  }

  double _r(double value) => double.parse(value.toStringAsFixed(3));
}
