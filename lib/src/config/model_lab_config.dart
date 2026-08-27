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
    required this.staleLockMinutes,
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

  /// Section 64: ein Advisory-Lock (`phoenix_model_lab_locks`), der älter als
  /// dieser Wert ist, gilt als verwaist (Prozess wurde vermutlich durch einen
  /// Deploy/Crash beendet, bevor `finally { releaseModelLabLock(...) }`
  /// erreicht wurde) und darf automatisch neu vergeben werden. Ein
  /// gleichzeitig noch als "running" markierter Learning Run wird dabei als
  /// "failed" nachgetragen, statt für immer hängen zu bleiben.
  final int staleLockMinutes;

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
      // Gesenkt 2026-08-27 von 50 auf 40: die Eligibility-Analyse gegen die
      // Produktionsdaten zeigte 98 sonst voll verwertbare, abgerechnete
      // Spiele mit Pre-Match-Snapshot im Bereich data_quality 40-49
      // (Histogramm: darunter fällt es schnell ab, die 30 Spiele bei 0-9
      // sind echter Datenmüll). 40 holt den knapp-drunter-Bereich rein,
      // ohne die klar unbrauchbaren Snapshots aufzunehmen.
      minDataQuality: readInt('PHOENIX_MODEL_LAB_MIN_DATA_QUALITY', 40),
      minLearningEligibleSamples:
          readInt('PHOENIX_MODEL_LAB_MIN_ELIGIBLE_SAMPLES', 50),
      leagueAdaptationSampleThreshold:
          readInt('PHOENIX_MODEL_LAB_LEAGUE_ADAPTATION_THRESHOLD', 100),
      strongerAdaptationSampleThreshold:
          readInt('PHOENIX_MODEL_LAB_STRONGER_ADAPTATION_THRESHOLD', 300),
      fullLeagueEngineSampleThreshold:
          readInt('PHOENIX_MODEL_LAB_FULL_LEAGUE_ENGINE_THRESHOLD', 600),
      shrinkageK: readInt('PHOENIX_MODEL_LAB_SHRINKAGE_K', 150),
      // Erweitert 2026-08-23: der alte Suchraum (±0.20 um 0.5, nur 4
      // Gitterpunkte) war so eng, dass ein Challenger kaum je einen messbar
      // anderen Torerwartungswert als der Champion produzieren konnte - bei
      // wenigen hundert Beobachtungen bleibt der Unterschied dann fast immer
      // im Rauschen und es entsteht praktisch nie eine klare Verbesserung.
      // ±0.30 mit 6 statt 4 Punkten deckt einen deutlich größeren Teil des
      // sinnvollen Bereichs ab, bleibt aber innerhalb von [0,1] weit von den
      // physikalisch bedeutungslosen Extremen (reine Angriffs- bzw. reine
      // Verteidigungsgewichtung) entfernt.
      attackWeightMin:
          readDouble('PHOENIX_MODEL_LAB_ATTACK_WEIGHT_MIN', 0.20),
      attackWeightMax:
          readDouble('PHOENIX_MODEL_LAB_ATTACK_WEIGHT_MAX', 0.80),
      attackWeightGrid: readGrid(
        'PHOENIX_MODEL_LAB_ATTACK_WEIGHT_GRID',
        const [0.20, 0.35, 0.45, 0.55, 0.65, 0.80],
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
          readInt('PHOENIX_MODEL_LAB_MAX_CHALLENGERS', 6),
      staleLockMinutes:
          readInt('PHOENIX_MODEL_LAB_STALE_LOCK_MINUTES', 180),
    );
  }
}
