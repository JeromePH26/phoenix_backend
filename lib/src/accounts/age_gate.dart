/// PHÖNIX ACCOUNT SYSTEM (Abschnitt 3/4): serverseitige Altersprüfung.
/// Reine, deterministische Funktion - keine Datenbankzugriffe, damit sie
/// ohne Postgres testbar bleibt. Berechnet das Alter IMMER live aus
/// `date_of_birth`, statt ein statisches Alter zu speichern (Abschnitt 3:
/// "NICHT dauerhaft ein statisches Alter wie age = 23 speichern").
library;

const int kMinimumAccountAge = 18;

/// Alter in vollen Jahren am Stichtag [asOf] (Standard: jetzt), exakt bis
/// zum Tag berechnet - nicht nur Jahresdifferenz.
int calculateAge(DateTime dateOfBirth, {DateTime? asOf}) {
  final now = asOf ?? DateTime.now();
  var age = now.year - dateOfBirth.year;
  final hadBirthdayThisYear = (now.month > dateOfBirth.month) ||
      (now.month == dateOfBirth.month && now.day >= dateOfBirth.day);
  if (!hadBirthdayThisYear) age -= 1;
  return age;
}

/// Abschnitt 3: mindestens 18 Jahre, exakt zum Stichtag geprüft (kein
/// Rundungsfehler bei "17 Jahre 364 Tage").
bool passesAgeGate(DateTime dateOfBirth, {DateTime? asOf}) {
  return calculateAge(dateOfBirth, asOf: asOf) >= kMinimumAccountAge;
}
