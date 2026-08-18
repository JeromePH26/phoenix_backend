import 'dart:io';

import 'package:bcrypt/bcrypt.dart';

import '../config/app_config.dart';
import '../database/database.dart';

/// PHÖNIX CONTROL CENTER: einmaliger Bootstrap des ersten `OWNER`-Mitarbeiters.
///
/// Chicken-and-egg-Problem: ohne Mitarbeiter kann sich niemand einloggen, um
/// den ersten Mitarbeiter anzulegen. Läuft bei jedem Serverstart NACH
/// `database.migrate()`, greift aber ausschließlich lesend+einmalig
/// schreibend:
///   - `admin_employees` ist leer UND alle drei
///     `PHOENIX_CC_BOOTSTRAP_OWNER_*`-Variablen sind gesetzt -> genau ein
///     OWNER wird angelegt.
///   - `admin_employees` ist NICHT leer -> es passiert nichts, unabhängig
///     davon, ob die Env-Vars noch gesetzt sind (kein Überschreiben, keine
///     Duplikate).
class ControlCenterBootstrap {
  ControlCenterBootstrap({required this.database, required this.config});

  final PhoenixDatabase database;
  final AppConfig config;

  Future<void> run() async {
    if (!database.isConfigured) return;
    if (!config.hasControlCenterBootstrapConfig) return;

    final existingCount = await database.countAdminEmployees();
    if (!shouldBootstrap(
      employeeTableIsEmpty: existingCount == 0,
      hasBootstrapConfig: config.hasControlCenterBootstrapConfig,
    )) {
      return;
    }

    final passwordHash = BCrypt.hashpw(
      config.controlCenterBootstrapOwnerPassword,
      BCrypt.gensalt(),
    );

    await database.insertAdminEmployee(
      name: 'Bootstrap Owner',
      login: config.controlCenterBootstrapOwnerLogin,
      email: config.controlCenterBootstrapOwnerEmail,
      passwordHash: passwordHash,
      role: 'OWNER',
    );

    stdout.writeln(
      'PHÖNIX Control Center: Bootstrap-OWNER "${config.controlCenterBootstrapOwnerLogin}" '
      'wurde angelegt, weil admin_employees leer war. '
      'Bitte PHOENIX_CC_BOOTSTRAP_OWNER_LOGIN/EMAIL/PASSWORD jetzt aus der '
      'Umgebung entfernen.',
    );
  }
}

/// Reine Entscheidungsfunktion (ohne DB-Zugriff), damit sie unabhängig
/// testbar ist: Bootstrap läuft nur, wenn die Tabelle nachweislich leer ist
/// UND die komplette Konfiguration vorhanden ist. Läuft NIE, wenn die
/// Tabelle bereits Zeilen enthält (kein destruktives Verhalten).
bool shouldBootstrap({
  required bool employeeTableIsEmpty,
  required bool hasBootstrapConfig,
}) {
  return employeeTableIsEmpty && hasBootstrapConfig;
}
