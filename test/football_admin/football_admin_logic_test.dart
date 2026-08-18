import 'package:phoenix_backend/src/football_admin/football_admin_logic.dart';
import 'package:test/test.dart';

void main() {
  group('parseMatchFlagsPatch', () {
    test('accepts a single valid flag and maps to the DB column name', () {
      final result = parseMatchFlagsPatch({'visible': false});
      expect(result.isValid, isTrue);
      expect(result.flags, {'visible': false});
      expect(result.reason, isNull);
      expect(result.comment, isNull);
    });

    test('accepts a subset of all five flags plus reason/comment', () {
      final result = parseMatchFlagsPatch({
        'analysisEnabled': false,
        'tipEnabled': false,
        'reason': 'Doppelte Ansetzung',
        'comment': 'Bitte prüfen',
      });
      expect(result.isValid, isTrue);
      expect(result.flags, {
        'analysis_enabled': false,
        'tip_enabled': false,
      });
      expect(result.reason, 'Doppelte Ansetzung');
      expect(result.comment, 'Bitte prüfen');
    });

    test('maps every known JSON field to its DB column', () {
      final result = parseMatchFlagsPatch({
        'visible': true,
        'analysisEnabled': true,
        'tipEnabled': true,
        'learningEnabled': true,
        'liveEnabled': true,
      });
      expect(result.isValid, isTrue);
      expect(result.flags, {
        'visible': true,
        'analysis_enabled': true,
        'tip_enabled': true,
        'learning_enabled': true,
        'live_enabled': true,
      });
    });

    test('rejects an unknown field instead of silently ignoring it', () {
      final result = parseMatchFlagsPatch({'visible': true, 'typo': true});
      expect(result.isValid, isFalse);
      expect(result.error, contains('typo'));
    });

    test('rejects a non-boolean value for a known flag', () {
      final result = parseMatchFlagsPatch({'visible': 'yes'});
      expect(result.isValid, isFalse);
      expect(result.error, contains('visible'));
    });

    test('rejects an empty body (no flags at all)', () {
      final result = parseMatchFlagsPatch({});
      expect(result.isValid, isFalse);
    });

    test('rejects a body containing only reason/comment, no flags', () {
      final result = parseMatchFlagsPatch({'reason': 'nur ein Kommentar'});
      expect(result.isValid, isFalse);
    });

    test('treats a blank reason/comment as not provided', () {
      final result = parseMatchFlagsPatch({
        'visible': true,
        'reason': '   ',
        'comment': '',
      });
      expect(result.isValid, isTrue);
      expect(result.reason, isNull);
      expect(result.comment, isNull);
    });
  });

  group('mapFlagsToJsonKeys', () {
    test('translates DB column names back to the camelCase JSON names', () {
      final result = mapFlagsToJsonKeys({
        'visible': false,
        'analysis_enabled': true,
        'tip_enabled': false,
        'learning_enabled': true,
        'live_enabled': false,
      });
      expect(result, {
        'visible': false,
        'analysisEnabled': true,
        'tipEnabled': false,
        'learningEnabled': true,
        'liveEnabled': false,
      });
    });

    test('round-trips with parseMatchFlagsPatch', () {
      final patch = parseMatchFlagsPatch({'tipEnabled': false});
      expect(mapFlagsToJsonKeys(patch.flags), {'tipEnabled': false});
    });
  });

  group('clampListLimit', () {
    test('falls back to the default when null', () {
      expect(clampListLimit(null), 50);
    });

    test('falls back to the default when below 1', () {
      expect(clampListLimit(0), 50);
      expect(clampListLimit(-5), 50);
    });

    test('caps at the maximum', () {
      expect(clampListLimit(9999), 200);
    });

    test('passes through a value within bounds', () {
      expect(clampListLimit(75), 75);
    });

    test('honors custom default/max', () {
      expect(clampListLimit(null, defaultValue: 200, maxValue: 500), 200);
      expect(clampListLimit(600, defaultValue: 200, maxValue: 500), 500);
    });
  });

  group('clampOffset', () {
    test('falls back to 0 when null or negative', () {
      expect(clampOffset(null), 0);
      expect(clampOffset(-1), 0);
    });

    test('passes through a non-negative value', () {
      expect(clampOffset(40), 40);
    });
  });

  group('parseBoolParam', () {
    test('parses true/false case-insensitively', () {
      expect(parseBoolParam('true'), isTrue);
      expect(parseBoolParam('TRUE'), isTrue);
      expect(parseBoolParam('false'), isFalse);
      expect(parseBoolParam('False'), isFalse);
    });

    test('returns null when not provided', () {
      expect(parseBoolParam(null), isNull);
    });

    test('returns null for an invalid value instead of throwing', () {
      expect(parseBoolParam('yes'), isNull);
      expect(parseBoolParam(''), isNull);
    });
  });

  group('computeAssetStatus', () {
    final now = DateTime.utc(2026, 8, 18);

    test('MISSING when not cached at all', () {
      expect(
        computeAssetStatus(cached: false, hasBytes: false, now: now),
        'MISSING',
      );
    });

    test('MISSING when cached but empty content', () {
      expect(
        computeAssetStatus(
          cached: true,
          hasBytes: false,
          updatedAt: now,
          now: now,
        ),
        'MISSING',
      );
    });

    test('OK when cached, non-empty, and recently updated', () {
      expect(
        computeAssetStatus(
          cached: true,
          hasBytes: true,
          updatedAt: now.subtract(const Duration(days: 10)),
          now: now,
        ),
        'OK',
      );
    });

    test('STALE when cached but older than the threshold', () {
      expect(
        computeAssetStatus(
          cached: true,
          hasBytes: true,
          updatedAt: now.subtract(const Duration(days: 91)),
          now: now,
        ),
        'STALE',
      );
    });

    test('boundary: exactly the threshold is still OK, one day past is STALE', () {
      expect(
        computeAssetStatus(
          cached: true,
          hasBytes: true,
          updatedAt: now.subtract(kAssetStaleAfter),
          now: now,
        ),
        'OK',
      );
      expect(
        computeAssetStatus(
          cached: true,
          hasBytes: true,
          updatedAt: now.subtract(kAssetStaleAfter + const Duration(days: 1)),
          now: now,
        ),
        'STALE',
      );
    });

    test('respects a custom staleAfter duration', () {
      expect(
        computeAssetStatus(
          cached: true,
          hasBytes: true,
          updatedAt: now.subtract(const Duration(days: 5)),
          now: now,
          staleAfter: const Duration(days: 3),
        ),
        'STALE',
      );
    });
  });

  group('isAllowedAssetContentType', () {
    test('accepts the documented image types', () {
      expect(isAllowedAssetContentType('image/png'), isTrue);
      expect(isAllowedAssetContentType('image/jpeg'), isTrue);
      expect(isAllowedAssetContentType('image/webp'), isTrue);
      expect(isAllowedAssetContentType('image/svg+xml'), isTrue);
    });

    test('is case-insensitive', () {
      expect(isAllowedAssetContentType('IMAGE/PNG'), isTrue);
    });

    test('rejects unknown or missing content types', () {
      expect(isAllowedAssetContentType('application/pdf'), isFalse);
      expect(isAllowedAssetContentType('image/gif'), isFalse);
      expect(isAllowedAssetContentType(null), isFalse);
    });
  });

  group('validateAssetReplacePayload', () {
    test('rejects a disallowed content type', () {
      final error = validateAssetReplacePayload(
        contentType: 'application/pdf',
        byteLength: 1000,
      );
      expect(error, isNotNull);
    });

    test('rejects empty image data', () {
      final error = validateAssetReplacePayload(
        contentType: 'image/png',
        byteLength: 0,
      );
      expect(error, isNotNull);
    });

    test('rejects a payload over the size limit', () {
      final error = validateAssetReplacePayload(
        contentType: 'image/png',
        byteLength: kMaxAssetReplaceBytes + 1,
      );
      expect(error, isNotNull);
    });

    test('accepts a valid payload at or under the size limit', () {
      expect(
        validateAssetReplacePayload(
          contentType: 'image/jpeg',
          byteLength: kMaxAssetReplaceBytes,
        ),
        isNull,
      );
      expect(
        validateAssetReplacePayload(
          contentType: 'image/jpeg',
          byteLength: 12345,
        ),
        isNull,
      );
    });

    test('honors a custom maxBytes', () {
      final error = validateAssetReplacePayload(
        contentType: 'image/png',
        byteLength: 2000,
        maxBytes: 1000,
      );
      expect(error, isNotNull);
    });
  });
}
