import 'dart:math' as math;

/// Namens-Normalisierung und Ähnlichkeits-Maße für das Zuordnen externer
/// Roh-Teamnamen (Historical Twins / ClubElo) zu den PHÖNIX-eigenen
/// Provider-Team-IDs.
///
/// Zuvor lag diese Logik nur lokal in `bin/phoenix_twins_match_teams.dart`.
/// M1 (docs/PHASE1_ENGINE_AUDIT.md) braucht denselben Resolver an mehreren
/// Stellen (Twin-Linkage, Elo-Linkage, laufende `football_teams`-Pflege) und
/// unter Unit-Test. Die Normalisierungs-/Ähnlichkeitslogik ist bewusst
/// unverändert aus dem Bin-Skript übernommen (Refactor, kein Verhaltens-
/// wechsel) - Erweiterungen der Alias-/Strip-Listen sind ein separater,
/// bewusster Schritt.
class TeamNameResolver {
  const TeamNameResolver._();

  /// Akzeptanzschwelle für eine eindeutige Namenszuordnung.
  static const double matchThreshold = 0.82;

  /// Mindestabstand des besten zum zweitbesten Kandidaten - darunter gilt die
  /// Zuordnung als mehrdeutig und wird verworfen (kein Raten).
  static const double minMarginOverSecondBest = 0.05;

  static const Map<String, String> _accentMap = {
    'ä': 'a', 'ö': 'o', 'ü': 'u', 'ß': 'ss', 'é': 'e', 'è': 'e', 'ê': 'e',
    'á': 'a', 'à': 'a', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ñ': 'n', 'ç': 'c',
    'ã': 'a', 'õ': 'o', 'ý': 'y', 'č': 'c', 'š': 's', 'ž': 'z',
  };

  static const Map<String, String> _aliasReplacements = {
    ' utd': ' united',
    'man united': 'manchester united',
    'man city': 'manchester city',
    'spurs': 'tottenham',
    'wolves': 'wolverhampton',
    "nott'm forest": 'nottingham forest',
  };

  /// Vereins-/Rechtsform-Kürzel, die für den Vergleich keinen Informations-
  /// gehalt tragen und entfernt werden.
  static const List<String> _stripTokens = [
    'fc', 'cf', 'sc', 'afc', 'ac', 'cd', 'ud', 'sd', 'ca', 'cp', 'ec', 'rc',
    'club', 'calcio', 'futbol', 'football', 'ssd', 'asd', 'us', 'as',
    '1.', 'tsg', 'sv', 'vfb', 'vfl', 'bsc', 'fsv', 'sg',
  ];

  /// Kleinschreibung, Akzente entfernt, bekannte Aliase ersetzt, Rechtsform-
  /// Kürzel entfernt, auf einzelne Leerzeichen normalisiert.
  static String normalize(String raw) {
    var s = raw.toLowerCase();
    _accentMap.forEach((k, v) => s = s.replaceAll(k, v));
    _aliasReplacements.forEach((k, v) {
      if (s.contains(k)) s = s.replaceAll(k, v);
    });
    final tokens = s
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .where((t) => !_stripTokens.contains(t))
        .toList();
    return tokens.join(' ');
  }

  /// Ähnlichkeit zweier bereits normalisierter Namen: das Maximum aus
  /// Token-Jaccard und (zeichenbasierter) Levenshtein-Ähnlichkeit, jeweils
  /// in [0, 1].
  static double similarity(String normalizedA, String normalizedB) {
    if (normalizedA == normalizedB) return normalizedA.isEmpty ? 0.0 : 1.0;
    final ta = normalizedA.split(' ').where((t) => t.isNotEmpty).toSet();
    final tb = normalizedB.split(' ').where((t) => t.isNotEmpty).toSet();
    if (ta.isEmpty || tb.isEmpty) return 0.0;
    final intersection = ta.intersection(tb).length;
    final union = ta.union(tb).length;
    final jaccard = union == 0 ? 0.0 : intersection / union;
    return math.max(jaccard, _levenshteinSimilarity(normalizedA, normalizedB));
  }

  /// Bestes Match von [rawName] gegen Kandidaten `{normalisierterName: kennung}`.
  /// Gibt die Kennung nur zurück, wenn der beste Score >= [matchThreshold]
  /// liegt UND der Abstand zum zweitbesten >= [minMarginOverSecondBest] ist;
  /// sonst `null` (mehrdeutig / kein Treffer). [result] wird, falls
  /// übergeben, mit Diagnosewerten befüllt.
  static T? bestMatch<T>(
    String rawName,
    Map<String, T> normalizedCandidates, {
    TeamMatchResult? result,
  }) {
    final normTarget = normalize(rawName);
    if (normTarget.isEmpty) return null;

    String? bestKey;
    var bestScore = -1.0;
    var secondBestScore = -1.0;
    for (final key in normalizedCandidates.keys) {
      final score = similarity(normTarget, key);
      if (score > bestScore) {
        secondBestScore = bestScore;
        bestScore = score;
        bestKey = key;
      } else if (score > secondBestScore) {
        secondBestScore = score;
      }
    }

    result
      ?..bestScore = bestScore < 0 ? 0.0 : bestScore
      ..secondBestScore = secondBestScore < 0 ? 0.0 : secondBestScore
      ..bestCandidateKey = bestKey;

    if (bestKey == null || bestScore < matchThreshold) {
      result?.status = TeamMatchStatus.noMatch;
      return null;
    }
    if ((bestScore - secondBestScore) < minMarginOverSecondBest) {
      result?.status = TeamMatchStatus.ambiguous;
      return null;
    }
    result?.status = TeamMatchStatus.matched;
    return normalizedCandidates[bestKey];
  }

  /// Plausibilitätsprüfung für einen geratenen Liga-Namen gegen ein
  /// erwartetes Stichwort (z. B. "Bundesliga" vs. der echte `league_name`).
  static bool leagueNamePlausible(String actualName, String hintKeyword) {
    final actual = actualName.toLowerCase();
    final hint = hintKeyword.toLowerCase();
    if (actual.contains(hint) || hint.contains(actual)) return true;
    return hint
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 4)
        .any(actual.contains);
  }

  static double _levenshteinSimilarity(String a, String b) {
    final maxLen = math.max(a.length, b.length);
    if (maxLen == 0) return 1.0;
    return 1.0 - (_levenshtein(a, b) / maxLen);
  }

  static int _levenshtein(String a, String b) {
    final la = a.length, lb = b.length;
    if (la == 0) return lb;
    if (lb == 0) return la;
    var prev = List<int>.generate(lb + 1, (j) => j);
    for (var i = 1; i <= la; i++) {
      final curr = List<int>.filled(lb + 1, 0);
      curr[0] = i;
      for (var j = 1; j <= lb; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = [curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost]
            .reduce(math.min);
      }
      prev = curr;
    }
    return prev[lb];
  }
}

enum TeamMatchStatus { matched, ambiguous, noMatch }

/// Veränderbarer Diagnose-Container für [TeamNameResolver.bestMatch].
class TeamMatchResult {
  TeamMatchStatus status = TeamMatchStatus.noMatch;
  double bestScore = 0.0;
  double secondBestScore = 0.0;
  String? bestCandidateKey;
}
