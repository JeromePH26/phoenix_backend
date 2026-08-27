/// Bekannte football-data.co.uk-Divisionscodes (Feld `division` in
/// `historical_twin_matches`) -> Land / Ligastufe / Namens-Stichwort /
/// vermutete API-Football-Liga-ID.
///
/// [DivisionHint.guessedLeagueId] ist die häufig dokumentierte
/// API-Football-Liga-ID. Sie wird NIE blind übernommen, sondern gegen
/// `football_leagues` verifiziert (Land muss passen UND der echte
/// `league_name` muss zum [nameKeyword] passen), sonst greift ein Fallback
/// über Land+Stufe+Namenssuche, sonst bleibt der Code "nicht aufgelöst".
/// Siehe `bin/phoenix_division_map_report.dart` (Verifikation + optionales
/// Befüllen von `football_division_map`).
///
/// Zuvor lag diese Liste als privates `const` in
/// `bin/phoenix_twins_match_teams.dart`; M1 hebt sie in ein testbares Modul.
class DivisionHint {
  const DivisionHint(
    this.division,
    this.country,
    this.tier,
    this.nameKeyword,
    this.guessedLeagueId,
  );

  /// football-data.co.uk-Code, z. B. `E0`, `D1`, `SP1`.
  final String division;
  final String country;

  /// Ligastufe (1 = oberste). `null`, wenn der Datensatz keine klare Stufe
  /// vorgibt (z. B. Ligen mit Auf-/Abstiegs-Playoffs über mehrere Ebenen).
  final int? tier;

  /// Stichwort, das im echten `football_leagues.league_name` vorkommen muss,
  /// damit eine geratene ID akzeptiert wird.
  final String nameKeyword;

  /// Häufig dokumentierte API-Football-Liga-ID - nur ein Startpunkt für die
  /// Verifikation.
  final int? guessedLeagueId;
}

/// Die verifizierbaren Divisions-Hinweise. Deckt aktuell ~38 überwiegend
/// europäische Erst-/Zweitligen ab; alles darüber hinaus bleibt in
/// `historical_twin_matches` unverknüpft (Datenklasse RESEARCH, siehe M2).
const List<DivisionHint> kDivisionHints = <DivisionHint>[
  DivisionHint('E0', 'England', 1, 'Premier League', 39),
  DivisionHint('E1', 'England', 2, 'Championship', 40),
  DivisionHint('E2', 'England', 3, 'League One', 41),
  DivisionHint('E3', 'England', 4, 'League Two', 42),
  DivisionHint('EC', 'England', 5, 'National League', 43),
  DivisionHint('SC0', 'Scotland', 1, 'Premiership', 179),
  DivisionHint('SC1', 'Scotland', 2, 'Championship', 180),
  DivisionHint('SC2', 'Scotland', 3, 'League One', 181),
  DivisionHint('SC3', 'Scotland', 4, 'League Two', 182),
  DivisionHint('D1', 'Germany', 1, 'Bundesliga', 78),
  DivisionHint('D2', 'Germany', 2, '2. Bundesliga', 79),
  DivisionHint('SP1', 'Spain', 1, 'La Liga', 140),
  DivisionHint('SP2', 'Spain', 2, 'Segunda', 141),
  DivisionHint('I1', 'Italy', 1, 'Serie A', 135),
  DivisionHint('I2', 'Italy', 2, 'Serie B', 136),
  DivisionHint('F1', 'France', 1, 'Ligue 1', 61),
  DivisionHint('F2', 'France', 2, 'Ligue 2', 62),
  DivisionHint('N1', 'Netherlands', 1, 'Eredivisie', 88),
  DivisionHint('B1', 'Belgium', 1, 'Pro League', 144),
  DivisionHint('P1', 'Portugal', 1, 'Primeira Liga', 94),
  DivisionHint('T1', 'Turkey', 1, 'Süper Lig', 203),
  DivisionHint('G1', 'Greece', 1, 'Super League', 197),
  DivisionHint('ROM', 'Romania', 1, 'Liga', 283),
  DivisionHint('POL', 'Poland', 1, 'Ekstraklasa', 106),
  DivisionHint('RUS', 'Russia', 1, 'Premier League', 235),
  DivisionHint('SWE', 'Sweden', 1, 'Allsvenskan', 113),
  DivisionHint('SUI', 'Switzerland', 1, 'Super League', 207),
  DivisionHint('NOR', 'Norway', 1, 'Eliteserien', 103),
  DivisionHint('DEN', 'Denmark', 1, 'Superliga', 119),
  DivisionHint('FIN', 'Finland', 1, 'Veikkausliiga', 244),
  DivisionHint('IRL', 'Ireland', 1, 'Premier Division', 357),
  DivisionHint('AUT', 'Austria', 1, 'Bundesliga', 218),
  DivisionHint('ARG', 'Argentina', null, 'Liga Profesional', 128),
  DivisionHint('BRA', 'Brazil', 1, 'Serie A', 71),
  DivisionHint('MEX', 'Mexico', 1, 'Liga MX', 262),
  DivisionHint('USA', 'USA', 1, 'Major League Soccer', 253),
  DivisionHint('JAP', 'Japan', 1, 'J1 League', 98),
  DivisionHint('CHN', 'China', null, 'Super League', 169),
];
