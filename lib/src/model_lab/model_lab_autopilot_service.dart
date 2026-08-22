import '../config/model_lab_config.dart';
import '../database/database.dart';
import 'learning_market.dart';
import 'model_registry_service.dart';
import 'shadow_prediction_service.dart';

/// Kontrollierter täglicher Selbstlern-Zyklus.
///
/// Er verändert niemals Produktionsgewichte. Er rechnet ausschließlich
/// bereits eingefrorene Pre-Match-Prognosen ab und legt neue Shadows an. Das
/// macht die Beobachtung von Spieltag zu Spieltag vollständig automatisch,
/// während Champion-Wechsel weiterhin die statistischen Gates des Monthly
/// Reviews erfüllen müssen.
class ModelLabAutopilotService {
  ModelLabAutopilotService({required this.database, required this.config});

  final PhoenixDatabase database;
  final ModelLabConfig config;

  static const String lockName = 'model_lab_autopilot';

  Future<Map<String, Object?>> run({required String triggerType}) async {
    final locked = await database.acquireModelLabLock(
      lockName,
      staleAfterMinutes: config.staleLockMinutes,
    );
    if (!locked) {
      return {
        'status': 'skipped',
        'reason': 'Ein anderer Tageszyklus läuft bereits (Lock aktiv).',
      };
    }

    try {
      final registry = ModelRegistryService(database: database, config: config);
      var baselinesEnsured = 0;
      for (final market in LearningMarket.values) {
        await registry.ensureGlobalBaseline(market.key);
        baselinesEnsured += 1;
      }

      final shadows =
          ShadowPredictionService(database: database, config: config);
      // Reihenfolge ist fachlich wichtig: erst das echte Ergebnis sichern,
      // anschließend ausschließlich künftige Fixtures einfrieren.
      final settled = await shadows.settlePendingShadowPredictions();
      final created = await shadows.generatePendingShadowPredictions();
      final summary = <String, Object?>{
        'baselinesEnsured': baselinesEnsured,
        'settled': settled,
        'created': created,
        'triggerType': triggerType,
      };
      await database.insertModelLabAuditLog(
        action: 'autopilot_completed',
        actor: triggerType == 'scheduled' ? 'system' : 'admin',
        details: summary,
      );
      return {'status': 'completed', ...summary};
    } catch (error) {
      await database.insertModelLabAuditLog(
        action: 'autopilot_failed',
        actor: triggerType == 'scheduled' ? 'system' : 'admin',
        details: {'error': error.toString(), 'triggerType': triggerType},
      );
      rethrow;
    } finally {
      await database.releaseModelLabLock(lockName);
    }
  }
}
