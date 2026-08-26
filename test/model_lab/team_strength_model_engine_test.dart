import 'package:phoenix_backend/src/model_lab/engine_replica.dart';
import 'package:phoenix_backend/src/model_lab/learning_market.dart';
import 'package:phoenix_backend/src/model_lab/learning_sample.dart';
import 'package:phoenix_backend/src/model_lab/team_strength_engine.dart';
import 'package:test/test.dart';

// PHÖNIX Engine-Umbau, Phase 2 (Plan "wild-cuddling-hoare", 2026-08-26):
// ModelEngine.teamStrength-Verdrahtung (das Fit-Objekt kommt von außen,
// anders als bei den übrigen ModelEngine-Kinds - siehe engine_replica.dart).
LearningSample _sample({
  String? homeTeamId,
  String? awayTeamId,
}) {
  return LearningSample(
    fixtureId: 'test-fixture',
    leagueId: '39',
    kickoff: DateTime.utc(2026, 1, 1),
    snapshotCreatedAt: DateTime.utc(2025, 12, 31),
    dataQuality: 80,
    features: const {},
    homeGoals: 2,
    awayGoals: 1,
    globalMarketAvailability:
        homeTeamId != null && awayTeamId != null ? const {} : null,
    globalMarketHomeTeamId: homeTeamId,
    globalMarketAwayTeamId: awayTeamId,
  );
}

void main() {
  group('ModelEngine.teamStrength', () {
    test('evaluate() returns null when the sample has no team IDs '
        '(no leakage-safe Phase-2 snapshot) - same contract as globalMarket', () {
      const fit = TeamStrengthFit(
        attack: {'A': 1.5},
        defense: {'A': 0.7},
        homeAdvantage: 1.35,
        iterations: 10,
        converged: true,
      );
      final engine = ModelEngine.teamStrength(fit);
      final output = engine.evaluate(
        market: LearningMarket.oneXTwo,
        sample: _sample(),
      );
      expect(output, isNull);
    });

    test('evaluate() looks up each team\'s fitted attack/defense and falls '
        'back to neutral strength for a team missing from the fit '
        '(cold start)', () {
      const fit = TeamStrengthFit(
        attack: {'A': 2.0},
        defense: {'A': 0.5},
        homeAdvantage: 1.4,
        iterations: 10,
        converged: true,
      );
      final engine = ModelEngine.teamStrength(fit);

      // A (stark, bekannt) zuhause gegen ein unbekanntes Team (Cold Start,
      // neutrale Staerke) -> klarer Heimsieg-Favorit.
      final output = engine.evaluate(
        market: LearningMarket.oneXTwo,
        sample: _sample(homeTeamId: 'A', awayTeamId: 'unknown-team'),
      )!;
      final sum = output.classProbabilities.fold(0.0, (a, b) => a + b);
      expect(sum, closeTo(1.0, 1e-6));
      // classProbabilities: [home, draw, away]
      expect(output.classProbabilities[0], greaterThan(output.classProbabilities[2]));
    });

    test('a non-converged fit is still usable by evaluate() (the caller '
        '- learning_run_service.dart - is responsible for only creating a '
        'challenger when fit.converged is true, evaluate() itself stays '
        'a pure function)', () {
      const fit = TeamStrengthFit(
        attack: {'A': 1.0, 'B': 1.0},
        defense: {'A': 1.0, 'B': 1.0},
        homeAdvantage: 1.0,
        iterations: 200,
        converged: false,
      );
      final engine = ModelEngine.teamStrength(fit);
      final output = engine.evaluate(
        market: LearningMarket.overUnder25,
        sample: _sample(homeTeamId: 'A', awayTeamId: 'B'),
      );
      expect(output, isNotNull);
    });

    test('toJson exposes the engine version and the fitted parameters', () {
      const fit = TeamStrengthFit(
        attack: {'A': 1.2},
        defense: {'A': 0.9},
        homeAdvantage: 1.3,
        iterations: 12,
        converged: true,
      );
      final json = ModelEngine.teamStrength(fit).toJson();
      expect(json['engineVersion'], TeamStrengthEngine.version);
      expect(json['homeAdvantage'], 1.3);
      expect(json['fitConverged'], isTrue);
      expect(json['teamCount'], 1);
      expect(json['attack'], {'A': 1.2});
    });

    test('isTeamStrength getter identifies the kind', () {
      const fit = TeamStrengthFit(
        attack: {},
        defense: {},
        homeAdvantage: 1.0,
        iterations: 0,
        converged: true,
      );
      final engine = ModelEngine.teamStrength(fit);
      expect(engine.isTeamStrength, isTrue);
      expect(const ModelEngine.dixonColes(0.0).isTeamStrength, isFalse);
    });
  });
}
