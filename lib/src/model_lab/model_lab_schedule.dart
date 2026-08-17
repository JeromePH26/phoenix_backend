import '../config/model_lab_config.dart';

/// Section 47/49: DST-sichere Europe/Berlin-Zeitumrechnung sowie die
/// First-Wednesday-Regel für den Monthly Champion Review. Bewusst dieselbe
/// einfache Sommerzeit-Heuristik wie `ApiRoutes._berlinNow` (letzter Sonntag
/// im März/Oktober), damit Model Lab und bestehende Cron-Jobs konsistent
/// rechnen.
class ModelLabSchedule {
  const ModelLabSchedule._();

  static DateTime berlinNow([DateTime? nowUtc]) {
    final utc = (nowUtc ?? DateTime.now()).toUtc();
    return toBerlin(utc);
  }

  static DateTime toBerlin(DateTime utc) {
    final marchSwitch = _lastSundayUtc(utc.year, DateTime.march);
    final octoberSwitch = _lastSundayUtc(utc.year, DateTime.october);
    final summerTime =
        !utc.isBefore(marchSwitch) && utc.isBefore(octoberSwitch);
    return utc.add(Duration(hours: summerTime ? 2 : 1));
  }

  static DateTime _lastSundayUtc(int year, int month) {
    final lastDay = DateTime.utc(year, month + 1, 0);
    final sunday = lastDay.subtract(Duration(days: lastDay.weekday % 7));
    return DateTime.utc(year, month, sunday.day, 1);
  }

  /// Section 48/49: nur der ERSTE Mittwoch eines Kalendermonats zählt als
  /// offizieller Champion Review. Andere Mittwoche sind ein sauberer no-op.
  static bool isFirstWednesday(DateTime berlinLocal, ModelLabConfig config) {
    return berlinLocal.weekday == config.monthlyReviewWeekday &&
        berlinLocal.day <= config.monthlyReviewMaxDayOfMonth;
  }

  static bool isLearningDay(DateTime berlinLocal, ModelLabConfig config) {
    return berlinLocal.weekday == config.learningRunWeekday;
  }

  /// Nächster Dienstag ab (inklusive) dem übergebenen Berlin-Zeitpunkt, für
  /// die "Next Learning Run"-Anzeige im Model Lab Overview.
  static DateTime nextLearningRun(DateTime berlinLocal, ModelLabConfig config) {
    var candidate = DateTime(
      berlinLocal.year,
      berlinLocal.month,
      berlinLocal.day,
      config.learningRunHourBerlin,
    );
    while (candidate.weekday != config.learningRunWeekday ||
        !candidate.isAfter(berlinLocal)) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return candidate;
  }

  /// Nächster erster Mittwoch des Monats ab (inklusive) dem übergebenen
  /// Berlin-Zeitpunkt, für die "Next Champion Review"-Anzeige.
  static DateTime nextMonthlyReview(
    DateTime berlinLocal,
    ModelLabConfig config,
  ) {
    var year = berlinLocal.year;
    var month = berlinLocal.month;

    DateTime firstWednesdayOf(int y, int m) {
      var day = DateTime(y, m, 1);
      while (day.weekday != config.monthlyReviewWeekday) {
        day = day.add(const Duration(days: 1));
      }
      return day;
    }

    var candidate = firstWednesdayOf(year, month);
    if (!candidate.isAfter(berlinLocal)) {
      month += 1;
      if (month > 12) {
        month = 1;
        year += 1;
      }
      candidate = firstWednesdayOf(year, month);
    }
    return candidate;
  }
}
