import 'dart:math';

/// Produces fact-bound German Phoenix reports.  Every sentence is selected
/// from a deterministic library and only emitted when the required input is
/// actually available; the composer never invents a card, a transfer or a
/// match incident.
class PhoenixEditorialComposer {
  const PhoenixEditorialComposer();

  PhoenixEditorialArticle composePreview(PhoenixEditorialMatch match) {
    final home = match.homeTeam;
    final away = match.awayTeam;
    final homeProbability = match.homeProbability;
    final drawProbability = match.drawProbability;
    final awayProbability = match.awayProbability;
    final favourite = _favouriteLabel(
      home: home,
      away: away,
      homeProbability: homeProbability,
      drawProbability: drawProbability,
      awayProbability: awayProbability,
    );
    final title = _pick([
      '$home gegen $away: Phoenix erwartet $favourite',
      '$home – $away: Die Phoenix-Vorschau',
      'Vor dem Anpfiff: $home gegen $away',
    ], match.fixtureId);
    final probabilitySentence = homeProbability == null ||
            drawProbability == null ||
            awayProbability == null
        ? 'Die Partie wird anhand der verfügbaren Saison- und Formdaten eingeordnet.'
        : 'Das Modell sieht $home bei ${_percent(homeProbability)} %, ein Unentschieden bei ${_percent(drawProbability)} % und $away bei ${_percent(awayProbability)} %.';
    final formSentence = _formSentence(match);
    final body = [
      '$home empfängt $away in der ${match.leagueName}.',
      probabilitySentence,
      formSentence,
      'Die Einschätzung wird bis zum Anpfiff aktualisiert, sobald neue bestätigte Spiel- oder Kaderdaten vorliegen.',
    ].where((value) => value.isNotEmpty).join(' ');
    return PhoenixEditorialArticle(
      kind: 'match_preview',
      title: title,
      summary: _shorten(body),
      body: body,
      importance: _previewImportance(match),
    );
  }

  PhoenixEditorialArticle composeReview(PhoenixEditorialMatch match) {
    final home = match.homeTeam;
    final away = match.awayTeam;
    final homeGoals = match.homeGoals!;
    final awayGoals = match.awayGoals!;
    final winner = homeGoals == awayGoals
        ? ''
        : homeGoals > awayGoals
            ? home
            : away;
    final resultText = '$home $homeGoals:$awayGoals $away';
    final title = homeGoals == awayGoals
        ? _pick([
            '$home und $away teilen die Punkte',
            'Kein Sieger zwischen $home und $away',
          ], match.fixtureId)
        : _pick([
            '$winner entscheidet das Duell gegen ${winner == home ? away : home}',
            '$winner setzt sich durch',
          ], match.fixtureId);
    final expected = _expectedOutcome(match);
    final first = homeGoals == awayGoals
        ? 'Nach dem Abpfiff steht ein $resultText.'
        : '$winner gewinnt mit $resultText.';
    final modelSentence = expected == null
        ? 'Für dieses Spiel lag keine vollständige Vorab-Prognose vor; Phoenix bewertet den Abschluss deshalb ausschließlich über das bestätigte Ergebnis.'
        : expected
            ? 'Das Ergebnis liegt im Bereich der stärksten Phoenix-Erwartung vor dem Anpfiff.'
            : 'Das Ergebnis weicht von der stärksten Phoenix-Erwartung vor dem Anpfiff ab – genau diese Abweichungen fließen in die laufende Modellauswertung ein.';
    final incidentSentence = _eventSentence(match);
    final body = [
      first,
      modelSentence,
      incidentSentence,
      'Der Bericht verwendet nur bestätigte Endstände und Spielereignisse. Fehlende Details werden nicht ergänzt.',
    ].where((value) => value.isNotEmpty).join(' ');
    return PhoenixEditorialArticle(
      kind: 'match_review',
      title: title,
      summary: _shorten(body),
      body: body,
      importance: expected == true ? 68 : 76,
    );
  }

  PhoenixEditorialArticle composeTransfer({
    required String teamName,
    required String playerName,
    required String direction,
    required String leagueName,
    required String transferId,
  }) {
    final incoming = direction == 'in';
    final title = incoming
        ? '$teamName verstärkt den Kader'
        : '$teamName verzeichnet einen Abgang';
    final detail = incoming
        ? '$playerName wechselt zu $teamName.'
        : '$playerName verlässt $teamName.';
    final body =
        '$detail Phoenix führt den bestätigten Transfer in der Kaderbewertung für die $leagueName. Eine sportliche Auswirkung wird erst gewichtet, wenn Rolle, Einsatzdaten oder weitere bestätigte Kaderinformationen vorliegen.';
    return PhoenixEditorialArticle(
      kind: incoming ? 'transfer_in' : 'transfer_out',
      title: title,
      summary: _shorten(body),
      body: body,
      importance: 72,
    );
  }

  bool? _expectedOutcome(PhoenixEditorialMatch match) {
    final home = match.homeProbability;
    final draw = match.drawProbability;
    final away = match.awayProbability;
    if (home == null || draw == null || away == null) return false;
    final highest = max(home, max(draw, away));
    if (highest == home) return match.homeGoals! >= match.awayGoals!;
    if (highest == draw) return match.homeGoals == match.awayGoals;
    return match.awayGoals! >= match.homeGoals!;
  }

  String _eventSentence(PhoenixEditorialMatch match) {
    if (match.redCards > 0) {
      return match.redCards == 1
          ? 'Eine bestätigte rote Karte ist als Schlüsselmoment im Spielverlauf hinterlegt.'
          : '${match.redCards} bestätigte rote Karten prägten den Spielverlauf.';
    }
    if (match.goalEvents > 0) {
      return 'Im gespeicherten Spielverlauf sind ${match.goalEvents} Torereignisse hinterlegt.';
    }
    return '';
  }

  String _formSentence(PhoenixEditorialMatch match) {
    if (match.homeFormPoints == null && match.awayFormPoints == null) return '';
    if (match.homeFormPoints != null && match.awayFormPoints != null) {
      final difference = match.homeFormPoints! - match.awayFormPoints!;
      if (difference.abs() < .15) {
        return 'Die jüngste Form beider Teams liegt im Phoenix-Modell eng beieinander.';
      }
      final team = difference > 0 ? match.homeTeam : match.awayTeam;
      return '$team bringt in der jüngsten Form den besseren Ausgangswert mit.';
    }
    return 'Die Formdaten liegen aktuell nur teilweise vor und werden deshalb zurückhaltend gewichtet.';
  }

  String _favouriteLabel({
    required String home,
    required String away,
    required double? homeProbability,
    required double? drawProbability,
    required double? awayProbability,
  }) {
    if (homeProbability == null ||
        drawProbability == null ||
        awayProbability == null) {
      return 'ein enges Spiel';
    }
    final highest = max(homeProbability, max(drawProbability, awayProbability));
    if (highest < .42) return 'eine offene Partie';
    return highest == homeProbability
        ? '$home als Favoriten'
        : highest == awayProbability
            ? '$away als Favoriten'
            : 'ein Unentschieden als wahrscheinlichstes Einzelresultat';
  }

  int _previewImportance(PhoenixEditorialMatch match) {
    final probabilities = [
      match.homeProbability,
      match.drawProbability,
      match.awayProbability
    ].whereType<double>();
    if (probabilities.isEmpty) return 50;
    return (45 + probabilities.reduce(max) * 45).round().clamp(45, 88).toInt();
  }

  String _percent(double value) => '${(value * 100).round()}';

  String _shorten(String value) =>
      value.length <= 310 ? value : '${value.substring(0, 307)}…';

  String _pick(List<String> variants, String seed) => variants[
      seed.codeUnits.fold<int>(0, (sum, code) => sum + code) % variants.length];
}

class PhoenixEditorialArticle {
  const PhoenixEditorialArticle({
    required this.kind,
    required this.title,
    required this.summary,
    required this.body,
    required this.importance,
  });

  final String kind;
  final String title;
  final String summary;
  final String body;
  final int importance;
}

class PhoenixEditorialMatch {
  const PhoenixEditorialMatch({
    required this.fixtureId,
    required this.leagueId,
    required this.leagueName,
    required this.homeTeamId,
    required this.homeTeam,
    required this.awayTeamId,
    required this.awayTeam,
    required this.kickoff,
    this.homeGoals,
    this.awayGoals,
    this.homeProbability,
    this.drawProbability,
    this.awayProbability,
    this.homeFormPoints,
    this.awayFormPoints,
    this.goalEvents = 0,
    this.redCards = 0,
  });

  final String fixtureId,
      leagueId,
      leagueName,
      homeTeamId,
      homeTeam,
      awayTeamId,
      awayTeam;
  final DateTime kickoff;
  final int? homeGoals, awayGoals;
  final double? homeProbability, drawProbability, awayProbability;
  final double? homeFormPoints, awayFormPoints;
  final int goalEvents, redCards;
}
