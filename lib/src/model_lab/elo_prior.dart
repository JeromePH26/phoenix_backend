import 'dart:math';

/// M3b (AN2 §17/§20): leitet aus einem Pre-Match-Elo einen Angriff/Abwehr-
/// PRIOR ab, auf den der Team-Stärke-Fit (`TeamStrengthEngine`) dünn besetzte
/// und Aufsteiger-Teams zieht - statt wie bisher auf einen flachen 1.0.
///
/// Modell: Elo misst die GESAMTstärke eines Teams, die sich als Tor-
/// Überlegenheit `log(attack / defense)` niederschlägt. Ein Team X
/// Standardabweichungen über dem Ligaschnitt bekommt
///   attackPrior  = exp(+k * z)
///   defensePrior = exp(-k * z)     (kleiner = bessere Abwehr)
/// mit `z` = standardisierter Elo-Abstand zum Ligaschnitt und einem global
/// (über alle Ligen) gefitteten Koeffizienten `k`.
class EloPrior {
  const EloPrior({required this.k});

  /// Halbe Steigung von `log(Tore erzielt / Tore kassiert)` auf den
  /// standardisierten Elo-Abstand. Fällt auf 0 zurück (= flacher 1.0-Prior)
  /// wenn zu wenige Beobachtungen vorliegen.
  final double k;

  static const EloPrior neutral = EloPrior(k: 0);

  /// Angriff/Abwehr-Prior für ein Team gegeben sein Elo, den Liga-Mittelwert
  /// und die Liga-Streuung der Elo-Abstände. `null`-Elo oder `sd <= 0` ->
  /// neutral (1.0 / 1.0).
  ({double attack, double defense}) forTeam({
    double? elo,
    required double leagueMeanElo,
    required double leagueEloSd,
  }) {
    if (elo == null || leagueEloSd <= 0 || k == 0) {
      return (attack: 1.0, defense: 1.0);
    }
    final z = ((elo - leagueMeanElo) / leagueEloSd).clamp(-3.0, 3.0);
    final att = exp(k * z);
    return (attack: att, defense: 1.0 / att);
  }

  /// Baut die Priors einer Liga aus einem bereits gefitteten globalen
  /// Elo-Koeffizienten und den zeitlich korrekten Elo-Werten der Teams.
  /// Fehlt die nötige Streuung oder ein Team-Elo, bleibt das betroffene Team
  /// neutral. Damit ist ein dünner/inkompletter Elo-Bestand nie ein Grund,
  /// eine künstlich starke Tendenz zu erzeugen.
  Map<String, ({double attack, double defense})> forLeague(
    Map<String, double> eloByTeam,
  ) {
    if (eloByTeam.length < 2 || k == 0) return const {};
    final values = eloByTeam.values.toList();
    final mean = values.reduce((a, b) => a + b) / values.length;
    var variance = 0.0;
    for (final value in values) {
      variance += (value - mean) * (value - mean);
    }
    final sd = sqrt(variance / values.length);
    if (sd <= 0) return const {};
    return {
      for (final entry in eloByTeam.entries)
        entry.key: forTeam(
          elo: entry.value,
          leagueMeanElo: mean,
          leagueEloSd: sd,
        ),
    };
  }

  /// Fittet `k` per einfacher Regression durch den Ursprung von
  /// `s = log(goalsFor / goalsAgainst)` auf `z` über alle übergebenen
  /// Team-Beobachtungen (bereits standardisiert, siehe [standardize]).
  /// `k = slope / 2` (Überlegenheit = `log(attack/defense) = 2*k*z`).
  static EloPrior fit(List<({double z, double supremacyLog})> observations) {
    final usable = observations
        .where((o) => o.z.isFinite && o.supremacyLog.isFinite)
        .toList();
    if (usable.length < 30) return neutral;
    var sxx = 0.0;
    var sxy = 0.0;
    for (final o in usable) {
      sxx += o.z * o.z;
      sxy += o.z * o.supremacyLog;
    }
    if (sxx <= 0) return neutral;
    final slope = sxy / sxx;
    final k = slope / 2.0;
    // Physikalisch unsinnige Extreme abschneiden (ein z=+3-Team hätte bei
    // k=0.5 schon exp(1.5)~4.5x Angriff).
    return EloPrior(k: k.clamp(0.0, 0.6));
  }

  /// Hilfe: standardisiert die je-Team-Elo-Abstände einer Liga und paart sie
  /// mit der beobachteten Tor-Überlegenheit (log). `goalsFor`/`goalsAgainst`
  /// sind Summen über die Trainingsspiele des Teams.
  static List<({double z, double supremacyLog})> standardize(
    List<({double eloDiff, double goalsFor, double goalsAgainst})> teams,
  ) {
    final diffs = teams.map((t) => t.eloDiff).where((d) => d.isFinite).toList();
    if (diffs.length < 2) return const [];
    final mean = diffs.reduce((a, b) => a + b) / diffs.length;
    var variance = 0.0;
    for (final d in diffs) {
      variance += (d - mean) * (d - mean);
    }
    final sd = sqrt(variance / diffs.length);
    if (sd <= 0) return const [];
    const epsilon = 0.3; // Additive Glättung gegen 0-Tore.
    return [
      for (final t in teams)
        if (t.eloDiff.isFinite)
          (
            z: (t.eloDiff - mean) / sd,
            supremacyLog: log((t.goalsFor + epsilon) /
                (t.goalsAgainst + epsilon)),
          ),
    ];
  }
}
