import 'package:phoenix_backend/src/services/phoenix_editorial_composer.dart';

void main() {
  const composer = PhoenixEditorialComposer();
  final runs = <PhoenixEditorialArticle>[
    composer.composePreview(_match('1',
        home: 'Eintracht Braunschweig',
        away: 'VfL Bochum',
        homeProbability: .52,
        drawProbability: .27,
        awayProbability: .21)),
    composer.composePreview(_match('2',
        home: 'Hamburger SV',
        away: 'FC St. Pauli',
        homeProbability: .38,
        drawProbability: .31,
        awayProbability: .31)),
    composer.composePreview(_match('3',
        home: 'Bayer 04 Leverkusen',
        away: 'FC Bayern München',
        homeProbability: .34,
        drawProbability: .26,
        awayProbability: .40)),
    composer.composePreview(_match('4',
        home: 'SC Freiburg',
        away: '1. FSV Mainz 05',
        homeProbability: null,
        drawProbability: null,
        awayProbability: null)),
    composer.composeReview(_match('5',
        home: 'Borussia Dortmund',
        away: 'RB Leipzig',
        homeGoals: 2,
        awayGoals: 1,
        homeProbability: .55,
        drawProbability: .24,
        awayProbability: .21,
        goalEvents: 3)),
    composer.composeReview(_match('6',
        home: 'VfB Stuttgart',
        away: 'Eintracht Frankfurt',
        homeGoals: 1,
        awayGoals: 1,
        homeProbability: .36,
        drawProbability: .33,
        awayProbability: .31)),
    composer.composeReview(_match('7',
        home: 'FC Augsburg',
        away: 'SV Werder Bremen',
        homeGoals: 0,
        awayGoals: 2,
        homeProbability: .51,
        drawProbability: .27,
        awayProbability: .22,
        redCards: 1)),
    composer.composeReview(_match('8',
        home: '1. FC Union Berlin',
        away: 'TSG Hoffenheim',
        homeGoals: 0,
        awayGoals: 0,
        homeProbability: null,
        drawProbability: null,
        awayProbability: null)),
    composer.composeTransfer(
        teamName: 'VfL Bochum',
        playerName: 'Max Muster',
        direction: 'in',
        leagueName: '2. Bundesliga',
        transferId: '9'),
    composer.composeTransfer(
        teamName: 'Eintracht Braunschweig',
        playerName: 'Alex Beispiel',
        direction: 'out',
        leagueName: '2. Bundesliga',
        transferId: '10'),
  ];

  for (var index = 0; index < runs.length; index++) {
    final article = runs[index];
    if (article.title.trim().isEmpty ||
        article.summary.trim().isEmpty ||
        article.body.trim().isEmpty) {
      throw StateError('Testlauf ${index + 1}: unvollständiger Bericht');
    }
    if (article.body.contains('rote Karte') && index != 6) {
      throw StateError(
          'Testlauf ${index + 1}: nicht bestätigtes Kartenereignis');
    }
    if (article.body.contains('Torereignisse') && index != 4) {
      throw StateError('Testlauf ${index + 1}: nicht bestätigtes Torereignis');
    }
    print('[${index + 1}/10] ${article.kind}: ${article.title}');
  }
  print('10/10 Phoenix-Editorial-Testläufe bestanden.');
}

PhoenixEditorialMatch _match(
  String id, {
  required String home,
  required String away,
  int? homeGoals,
  int? awayGoals,
  double? homeProbability,
  double? drawProbability,
  double? awayProbability,
  int goalEvents = 0,
  int redCards = 0,
}) =>
    PhoenixEditorialMatch(
      fixtureId: id,
      leagueId: '2',
      leagueName: 'Bundesliga',
      homeTeamId: 'h$id',
      homeTeam: home,
      awayTeamId: 'a$id',
      awayTeam: away,
      kickoff: DateTime.utc(2026, 8, 14, 18),
      homeGoals: homeGoals,
      awayGoals: awayGoals,
      homeProbability: homeProbability,
      drawProbability: drawProbability,
      awayProbability: awayProbability,
      goalEvents: goalEvents,
      redCards: redCards,
    );
