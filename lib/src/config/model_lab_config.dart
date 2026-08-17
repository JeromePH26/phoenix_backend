import 'dart:io';

/// Zentrale, ENV-basierte Konfiguration für das PHÖNIX MODEL LAB
/// (Self-Learning Engine V0). Keine der hier definierten Zahlen darf im
/// restlichen Model-Lab-Code als "Magic Number" dupliziert werden - jeder
/// Service liest ausschließlich über diese Klasse.
class ModelLabConfig {
  const ModelLabConfig({
    required this.promotionEnabled,
    required this.minDataQuality,
    required this.minLearningEligibleSamples,
    required this.leagueAdaptationSampleThreshold,
    required this.strongerAdaptationSampleThreshold,
    required this.fullLeagueEngineSampleThreshold,
    required this.shrinkageK,
    required this.attackWeightMin,
    required this.attackWeightMax,
    required this.attackWeightGrid,
    required this.holdoutFraction,
    required this.walkForwardMinTrainingWindow,
    required this.walkForwardStepSize,
    required this.minHoldoutSample,
    required this.minValidationSample,
    required this.minShadowSample,
    required this.minPromotionSample,
    required this.bootstrapResamples,
    required this.bootstrapConfidenceLevel,
    required this.calibrationMinBucketSample,
    required this.redCardEarlyMinute,
    required this.redCardLateMinute,
    required this.learningRunWeekday,
    required this.learningRunHourBerlin,
    required this.monthlyReviewWeekday,
    required this.monthlyReviewMaxDayOfMonth,
    required this.maxChallengersPerLeagueMarket,
  });

  /// Section 53/54: Solange false, wird KEINE echte Promotion durchgeführt -
  /// weder über UI noch über die API. Serverseitig erzwungen.
  final bool promotionEnabled;

  /// Section 23: Minimale Data Quality, damit ein Match als Learning-eligible
  /// gilt. Default 50.
  final int minDataQuality;

  /// Section 23/93: Minimale Anzahl Learning-eligible Matches, bevor eine
  /// Liga×Markt-Kombination überhaupt als Kandidat betrachtet wird.
  final int minLearningEligibleSamples;

  /// Section 8: Sample-Grenzen für Global-Only / League-Adaptation / stärkere
  /// Anpassung / echte League Engine.
  final int leagueAdaptationSampleThreshold; // ab hier: vorsichtige Adaption
  final int strongerAdaptationSampleThreshold; // ab hier: stärkere Adaption
  final int fullLeagueEngineSampleThreshold; // ab hier: echte League Engine

  /// Section 15: Shrinkage-Konstante k in factor = n / (n + k). Je kleiner k,
  /// desto schneller darf sich eine Liga vom Global-Gewicht entfernen.
  final int shrinkageK;

  /// Section 14: Suchraum-Grenzen für den einzigen V0-Gewichtsparameter
  /// (attackWeight, siehe engine_replica.dart). Global/Champion-Baseline ist
  /// immer genau 0.5 (identisch zur produktiven Engine).
  final double attackWeightMin;
  final double attackWeightMax;

  /// Kontrollierte, feste Kandidaten-Werte für attackWeight (V5-C1..Cn).
  final List<double> attackWeightGrid;

  /// Section 32: Anteil der chronologisch jüngsten eligible Matches, der
  /// als Final Holdout reserviert wird und nie in die Candidate Search /
  /// Trainingsphase einfließt.
  final double holdoutFraction;

  /// Section 30: Startgröße des ersten Trainingsfensters für Walk-Forward
  /// (in Matches), sowie Schrittgröße je weiterem Testfenster.
  final int walkForwardMinTrainingWindow;
  final int walkForwardStepSize;

  /// Section 44: Mindest-Stichproben, unterhalb derer NIE promoted werden
  /// darf, unabhängig vom Ergebnis.
  final int minHoldoutSample;
  final int minValidationSample;
  final int minShadowSample;

  /// Kombinierte Mindestanzahl (Holdout + Shadow) für eine
  /// PROMOTION EMPFOHLEN - Empfehlung im Monthly Review.
  final int minPromotionSample;

  /// Section 43: Paired-Bootstrap-Parameter für die statistische
  /// Unsicherheit im Champion/Challenger-Vergleich.
  final int bootstrapResamples;
  final double bootstrapConfidenceLevel;

  /// Section 41/76: Minimale Anzahl Vorhersagen pro Calibration-Bucket,
  /// bevor er angezeigt wird.
  final int calibrationMinBucketSample;

  /// Section 26: Minutenschwellen für die distortion_score-Diagnose bei
  /// roten Karten (früh = hohe Verzerrung, spät = geringe Verzerrung).
  final int redCardEarlyMinute;
  final int redCardLateMinute;

  /// Section 45/47: Wochentag (1=Montag..7=Sonntag, DateTime-Konvention) und
  /// Berlin-Stunde für den automatischen Tuesday Learning Run.
  final int learningRunWeekday;
  final int learningRunHourBerlin;

  /// Section 48/49: Wochentag für den Monthly Champion Review sowie die
  /// maximale Kalendertagnummer, ab der ein Mittwoch noch als "erster
  /// Mittwoch des Monats" gilt.
  final int monthlyReviewWeekday;
  final int monthlyReviewMaxDayOfMonth;

  /// Section 12: Obergrenze gleichzeitig aktiver Challenger je Liga×Markt,
  /// damit ein Learning Run nicht unbegrenzt viele immutable Modelle erzeugt.
  final int maxChallengersPerLeagueMarket;

  factory ModelLabConfig.fromEnvironment() {
    String read(String key, [String fallback = '']) =>
        Platform.environment[key]?.trim() ?? fallback;
    int readInt(String key, int fallback) =>
        int.tryParse(read(key)) ?? fallback;
    double readDouble(String key, double fallback) =>
        double.tryParse(read(key)) ?? fallback;
    bool readBool(String key, bool fallback) {
      final value = read(key).toLowerCase();
      if (value.isEmpty) return fallback;
      return value == 'true' || value == '1';
    }

    List<double> readGrid(String key, List<double> fallback) {
      final raw = read(key);
      if (raw.isEmpty) return fallback;
      final values = raw
          .split(',')
          .map((entry) => double.tryParse(entry.trim()))
          .whereType<double>()
          .toList();
      return values.isEmpty ? fallback : values;
    }

    return ModelLabConfig(
      // Section 53: Default FALSE - keine Promotion ohne explizites Opt-in.
      promotionEnabled:
          readBool('PHOENIX_MODEL_PROMOTION_ENABLED', false),
      minDataQuality: readInt('PHOENIX_MODEL_LAB_MIN_DATA_QUALITY', 50),
      minLearningEligibleSamples:
          readInt('PHOENIX_MODEL_LAB_MIN_ELIGIBLE_SAMPLES', 50),
      leagueAdaptationSampleThreshold:
          readInt('PHOENIX_MODEL_LAB_LEAGUE_ADAPTATION_THRESHOLD', 100),
      strongerAdaptationSampleThreshold:
          readInt('PHOENIX_MODEL_LAB_STRONGER_ADAPTATION_THRESHOLD', 300),
      fullLeagueEngineSampleThreshold:
          readInt('PHOENIX_MODEL_LAB_FULL_LEAGUE_ENGINE_THRESHOLD', 600),
      shrinkageK: readInt('PHOENIX_MODEL_LAB_SHRINKAGE_K', 150),
      attackWeightMin:
          readDouble('PHOENIX_MODEL_LAB_ATTACK_WEIGHT_MIN', 0.30),
      attackWeightMax:
          readDouble('PHOENIX_MODEL_LAB_ATTACK_WEIGHT_MAX', 0.70),
      attackWeightGrid: readGrid(
        'PHOENIX_MODEL_LAB_ATTACK_WEIGHT_GRID',
        const [0.40, 0.45, 0.55, 0.60],
      ),
      holdoutFraction:
          readDouble('PHOENIX_MODEL_LAB_HOLDOUT_FRACTION', 0.20),
      walkForwardMinTrainingWindow:
          readInt('PHOENIX_MODEL_LAB_WALK_FORWARD_MIN_TRAINING', 60),
      walkForwardStepSize:
          readInt('PHOENIX_MODEL_LAB_WALK_FORWARD_STEP', 20),
      minHoldoutSample: readInt('PHOENIX_MODEL_LAB_MIN_HOLDOUT_SAMPLE', 40),
      minValidationSample:
          readInt('PHOENIX_MODEL_LAB_MIN_VALIDATION_SAMPLE', 40),
      minShadowSample: readInt('PHOENIX_MODEL_LAB_MIN_SHADOW_SAMPLE', 30),
      minPromotionSample:
          readInt('PHOENIX_MODEL_LAB_MIN_PROMOTION_SAMPLE', 120),
      bootstrapResamples:
          readInt('PHOENIX_MODEL_LAB_BOOTSTRAP_RESAMPLES', 2000),
      bootstrapConfidenceLevel:
          readDouble('PHOENIX_MODEL_LAB_BOOTSTRAP_CONFIDENCE', 0.95),
      calibrationMinBucketSample:
          readInt('PHOENIX_MODEL_LAB_CALIBRATION_MIN_BUCKET', 20),
      redCardEarlyMinute:
          readInt('PHOENIX_MODEL_LAB_RED_CARD_EARLY_MINUTE', 30),
      redCardLateMinute:
          readInt('PHOENIX_MODEL_LAB_RED_CARD_LATE_MINUTE', 75),
      learningRunWeekday:
          readInt('PHOENIX_MODEL_LAB_LEARNING_WEEKDAY', DateTime.tuesday),
      learningRunHourBerlin:
          readInt('PHOENIX_MODEL_LAB_LEARNING_HOUR_BERLIN', 4),
      monthlyReviewWeekday: readInt(
        'PHOENIX_MODEL_LAB_MONTHLY_REVIEW_WEEKDAY',
        DateTime.wednesday,
      ),
      monthlyReviewMaxDayOfMonth:
          readInt('PHOENIX_MODEL_LAB_MONTHLY_REVIEW_MAX_DAY', 7),
      maxChallengersPerLeagueMarket:
          readInt('PHOENIX_MODEL_LAB_MAX_CHALLENGERS', 4),
    );
  }
}
