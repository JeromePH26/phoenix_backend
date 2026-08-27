import 'dart:io';

import 'package:phoenix_backend/src/config/model_lab_config.dart';
import 'package:phoenix_backend/src/database/database.dart';
import 'package:phoenix_backend/src/model_lab/learning_dataset_builder.dart';

/// M2: befüllt `phoenix_learning_dataset` - je LIVE-Pre-Match-Snapshot x
/// Markt eine Zeile mit Datenklasse (production / learning / research /
/// quarantine) und Ausschlussgrund. Dieselbe Logik läuft als Kopf-Schritt
/// jedes Learning Runs; dieses Skript ist der manuelle Anstoß.
///
/// Standardmäßig DRY RUN. Mit `--write` wird die Tabelle befüllt.
///
///   dart run bin/phoenix_classify_dataset.dart
///   dart run bin/phoenix_classify_dataset.dart --write
Future<void> main(List<String> args) async {
  final write = args.contains('--write');
  final databaseUrl = (Platform.environment['DATABASE_PUBLIC_URL'] ??
          Platform.environment['DATABASE_URL'] ??
          '')
      .trim();
  final database = PhoenixDatabase(databaseUrl);
  final builder = LearningDatasetBuilder(
    database: database,
    config: ModelLabConfig.fromEnvironment(),
  );

  try {
    await database.migrate();
    final summary = await builder.classifyLiveDataset(write: write);

    stdout.writeln('== phoenix_learning_dataset (source=live) ==');
    stdout.writeln('Fixtures klassifiziert: ${summary['fixtures']}');
    stdout.writeln('Zeilen: ${summary['rows']}');
    for (final key in const ['production', 'learning', 'research', 'quarantine']) {
      stdout.writeln('  ${key.padRight(12)} ${summary[key] ?? 0}');
    }
    stdout.writeln(write
        ? '\nGeschrieben.'
        : '\nDRY RUN - nichts geschrieben. Mit --write erneut ausführen.');
  } finally {
    await database.close();
  }
}
