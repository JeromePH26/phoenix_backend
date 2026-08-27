import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../database/database.dart';
import '../http/json_response.dart';
import 'control_center_auth_guard.dart';

/// Isolierter Backend-Bereich für PHÖNIX Studio. Die Tabellen und Routen
/// liegen bewusst außerhalb der großen Control-Center-Dateien, damit Studio
/// unabhängig erweitert werden kann und keinerlei App-Bereich direkt live
/// verändert. Eine Veröffentlichung setzt ausschließlich eine freigegebene
/// Studio-Version als aktiv – die Flutter-App bindet diese später gezielt ein.
class StudioRoutes {
  StudioRoutes({required this.database})
      : guard = ControlCenterAuthGuard(database: database);

  final PhoenixDatabase database;
  final ControlCenterAuthGuard guard;

  Router get router {
    final router = Router();
    router.get('/sections', _listSections);
    router.get('/sections/<key>', _sectionDetail);
    router.patch('/sections/<key>', _updateSection);
    router.put('/sections/<key>/draft', _saveDraft);
    router.post('/sections/<key>/publish', _publish);
    router.post('/sections/<key>/rollback/<version|[0-9]+>', _rollback);
    return router;
  }

  Future<Response> _listSections(Request request) async {
    final actor = await _actor(request, permission: 'appControl.view');
    if (actor is Response) return actor;
    try {
      await _ensureSchema();
      final db = await database.connection();
      final result = await db.execute('''
        SELECT s.section_key, s.name, s.description, s.status,
               s.updated_at, d.updated_at AS draft_updated_at,
               d.updated_by AS draft_updated_by,
               v.version_number AS published_version,
               v.created_at AS published_at
        FROM studio_sections s
        LEFT JOIN studio_drafts d ON d.section_key = s.section_key
        LEFT JOIN studio_versions v ON v.id = s.active_version_id
        ORDER BY s.sort_order, s.name
      ''');
      return jsonResponse({
        'sections': result
            .map((row) =>
                _sectionSummary(Map<String, Object?>.from(row.toColumnMap())))
            .toList(),
      });
    } catch (error) {
      return _error(error);
    }
  }

  Future<Response> _sectionDetail(Request request, String key) async {
    final actor = await _actor(request, permission: 'appControl.view');
    if (actor is Response) return actor;
    try {
      await _ensureSchema();
      final section = await _section(key);
      if (section == null) return _notFound();
      final db = await database.connection();
      final draftResult = await db.execute(Sql.named('''
        SELECT document, updated_at, updated_by
        FROM studio_drafts WHERE section_key = @key
      '''), parameters: {'key': key});
      final versions = await db.execute(Sql.named('''
        SELECT id, version_number, created_at, created_by, change_note
        FROM studio_versions
        WHERE section_key = @key
        ORDER BY version_number DESC
        LIMIT 20
      '''), parameters: {'key': key});
      final published = await db.execute(Sql.named('''
        SELECT document, version_number, created_at, created_by
        FROM studio_versions WHERE id = @id
      '''), parameters: {'id': section['active_version_id']});
      return jsonResponse({
        'section': _sectionSummary(section),
        'draft': draftResult.isEmpty
            ? null
            : {
                'document':
                    _document(draftResult.first.toColumnMap()['document']),
                'updatedAt':
                    _timestamp(draftResult.first.toColumnMap()['updated_at']),
                'updatedBy': draftResult.first.toColumnMap()['updated_by'],
              },
        'published': published.isEmpty
            ? null
            : {
                'document':
                    _document(published.first.toColumnMap()['document']),
                'version': published.first.toColumnMap()['version_number'],
                'createdAt':
                    _timestamp(published.first.toColumnMap()['created_at']),
                'createdBy': published.first.toColumnMap()['created_by'],
              },
        'versions': versions.map((row) {
          final item = row.toColumnMap();
          return {
            'id': item['id'],
            'version': item['version_number'],
            'createdAt': _timestamp(item['created_at']),
            'createdBy': item['created_by'],
            'note': item['change_note'],
          };
        }).toList(),
      });
    } catch (error) {
      return _error(error);
    }
  }

  Future<Response> _updateSection(Request request, String key) async {
    final actor = await _actor(request, permission: 'appControl.manage');
    if (actor is Response) return actor;
    try {
      await _ensureSchema();
      final body = await _body(request);
      if (body == null) return _badRequest('Ungültige Eingabe.');
      final status = body['status']?.toString() ?? '';
      if (!const {'active', 'disabled', 'draft', 'published'}
          .contains(status)) {
        return _badRequest('Bitte einen gültigen Bereichsstatus wählen.');
      }
      final previous = await _section(key);
      if (previous == null) return _notFound();
      final db = await database.connection();
      await db.execute(Sql.named('''
        UPDATE studio_sections SET status = @status, updated_at = NOW()
        WHERE section_key = @key
      '''), parameters: {'status': status, 'key': key});
      await _audit(actor,
          action: 'studio.section_status_changed',
          key: key,
          previous: {'status': previous['status']},
          next: {'status': status});
      return _sectionDetail(request, key);
    } catch (error) {
      return _error(error);
    }
  }

  Future<Response> _saveDraft(Request request, String key) async {
    final actor = await _actor(request, permission: 'appControl.manage');
    if (actor is Response) return actor;
    try {
      await _ensureSchema();
      if (await _section(key) == null) return _notFound();
      final body = await _body(request);
      if (body == null) return _badRequest('Ungültige Eingabe.');
      final document = _validatedDocument(body['document']);
      if (document == null)
        return _badRequest('Der Entwurf enthält ungültige Bausteine.');
      final db = await database.connection();
      await db.execute(Sql.named('''
        INSERT INTO studio_drafts (section_key, document, updated_by, updated_at)
        VALUES (@key, CAST(@document AS JSONB), @by, NOW())
        ON CONFLICT (section_key) DO UPDATE SET
          document = EXCLUDED.document, updated_by = EXCLUDED.updated_by,
          updated_at = NOW()
      '''), parameters: {
        'key': key,
        'document': jsonEncode(document),
        'by': actor.login,
      });
      await db.execute(Sql.named('''
        UPDATE studio_sections
        SET status = CASE WHEN status = 'published' THEN status ELSE 'draft' END,
            updated_at = NOW()
        WHERE section_key = @key
      '''), parameters: {'key': key});
      await _audit(actor,
          action: 'studio.draft_saved',
          key: key,
          next: {'blockCount': document['blocks'].length});
      return jsonResponse({
        'status': 'saved',
        'savedAt': DateTime.now().toUtc().toIso8601String()
      });
    } catch (error) {
      return _error(error);
    }
  }

  Future<Response> _publish(Request request, String key) async {
    final actor = await _actor(request, permission: 'release.manage');
    if (actor is Response) return actor;
    try {
      await _ensureSchema();
      final section = await _section(key);
      if (section == null) return _notFound();
      final db = await database.connection();
      final draft = await db.execute(Sql.named('''
        SELECT document FROM studio_drafts WHERE section_key = @key
      '''), parameters: {'key': key});
      if (draft.isEmpty)
        return _badRequest('Es gibt keinen Entwurf zum Veröffentlichen.');
      final document =
          _validatedDocument(_document(draft.first.toColumnMap()['document']));
      if (document == null || document['blocks'].isEmpty) {
        return _badRequest(
            'Der Entwurf braucht mindestens einen gültigen Baustein.');
      }
      final body = await _body(request) ?? const <String, dynamic>{};
      final note = body['note']?.toString().trim();
      final result = await database.runTx((tx) async {
        final versionResult = await tx.execute(Sql.named('''
          SELECT COALESCE(MAX(version_number), 0) + 1 AS next_version
          FROM studio_versions WHERE section_key = @key
        '''), parameters: {'key': key});
        final version =
            (versionResult.first.toColumnMap()['next_version'] as num).toInt();
        final inserted = await tx.execute(Sql.named('''
          INSERT INTO studio_versions
            (section_key, version_number, document, created_by, change_note)
          VALUES (@key, @version, CAST(@document AS JSONB), @by, @note)
          RETURNING id
        '''), parameters: {
          'key': key,
          'version': version,
          'document': jsonEncode(document),
          'by': actor.login,
          'note': note?.isEmpty == true ? null : note,
        });
        final id = inserted.first.toColumnMap()['id'];
        await tx.execute(Sql.named('''
          UPDATE studio_sections
          SET active_version_id = @id, status = 'published', updated_at = NOW()
          WHERE section_key = @key
        '''), parameters: {'id': id, 'key': key});
        return {'id': id, 'version': version};
      });
      await _audit(actor,
          action: 'studio.version_published',
          key: key,
          previous: {'activeVersionId': section['active_version_id']},
          next: result);
      return jsonResponse({'status': 'published', ...result});
    } catch (error) {
      return _error(error);
    }
  }

  Future<Response> _rollback(
      Request request, String key, String versionText) async {
    final actor = await _actor(request, permission: 'release.manage');
    if (actor is Response) return actor;
    try {
      await _ensureSchema();
      final version = int.tryParse(versionText);
      if (version == null || await _section(key) == null) return _notFound();
      final db = await database.connection();
      final candidate = await db.execute(Sql.named('''
        SELECT id FROM studio_versions
        WHERE section_key = @key AND version_number = @version
      '''), parameters: {'key': key, 'version': version});
      if (candidate.isEmpty) return _notFound();
      final versionId = candidate.first.toColumnMap()['id'];
      await db.execute(Sql.named('''
        UPDATE studio_sections
        SET active_version_id = @id, status = 'published', updated_at = NOW()
        WHERE section_key = @key
      '''), parameters: {'id': versionId, 'key': key});
      await _audit(actor,
          action: 'studio.version_restored',
          key: key,
          next: {'version': version});
      return jsonResponse({'status': 'restored', 'version': version});
    } catch (error) {
      return _error(error);
    }
  }

  Future<dynamic> _actor(Request request, {required String permission}) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final employee = auth.employee!;
    if (!employee.hasPermission(permission)) return _forbidden();
    return employee;
  }

  Future<void> _ensureSchema() async {
    final db = await database.connection();
    await db.execute('''
      CREATE TABLE IF NOT EXISTS studio_sections (
        section_key TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'disabled'
          CHECK (status IN ('active', 'disabled', 'draft', 'published')),
        sort_order INTEGER NOT NULL DEFAULT 0,
        active_version_id BIGINT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS studio_drafts (
        section_key TEXT PRIMARY KEY REFERENCES studio_sections(section_key) ON DELETE CASCADE,
        document JSONB NOT NULL,
        updated_by TEXT NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS studio_versions (
        id BIGSERIAL PRIMARY KEY,
        section_key TEXT NOT NULL REFERENCES studio_sections(section_key) ON DELETE CASCADE,
        version_number INTEGER NOT NULL,
        document JSONB NOT NULL,
        created_by TEXT NOT NULL,
        change_note TEXT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE(section_key, version_number)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_studio_versions_section_version
      ON studio_versions (section_key, version_number DESC)
    ''');
    const sections = [
      (
        'lineup',
        'Aufstellung',
        'Voraussichtliche oder bestätigte Teamaufstellungen.',
        10
      ),
      (
        'match_detail',
        'Spielübersicht',
        'Kopfbereich und Kerndaten eines Spiels.',
        20
      ),
      ('form', 'Form', 'Formkurven und jüngste Spiele der Teams.', 30),
      ('h2h', 'Direkter Vergleich', 'Vergangene Duelle der beiden Teams.', 40),
      (
        'historical_twins',
        'Historische Zwillinge',
        'Ähnliche historische Spielprofile.',
        50
      ),
      ('injuries', 'Ausfälle', 'Verletzte und gesperrte Spieler.', 60),
    ];
    for (final section in sections) {
      await db.execute(Sql.named('''
        INSERT INTO studio_sections (section_key, name, description, sort_order)
        VALUES (@key, @name, @description, @sort)
        ON CONFLICT (section_key) DO NOTHING
      '''), parameters: {
        'key': section.$1,
        'name': section.$2,
        'description': section.$3,
        'sort': section.$4,
      });
    }
  }

  Future<Map<String, Object?>?> _section(String key) async {
    final db = await database.connection();
    final result = await db.execute(Sql.named('''
      SELECT s.*, v.version_number AS published_version, v.created_at AS published_at,
             d.updated_at AS draft_updated_at, d.updated_by AS draft_updated_by
      FROM studio_sections s
      LEFT JOIN studio_versions v ON v.id = s.active_version_id
      LEFT JOIN studio_drafts d ON d.section_key = s.section_key
      WHERE s.section_key = @key
    '''), parameters: {'key': key});
    return result.isEmpty
        ? null
        : Map<String, Object?>.from(result.first.toColumnMap());
  }

  Map<String, Object?> _sectionSummary(Map<String, Object?> row) => {
        'key': row['section_key'],
        'name': row['name'],
        'description': row['description'],
        'status': row['status'],
        'updatedAt': _timestamp(row['updated_at']),
        'draftUpdatedAt': _timestamp(row['draft_updated_at']),
        'draftUpdatedBy': row['draft_updated_by'],
        'publishedVersion': row['published_version'],
        'publishedAt': _timestamp(row['published_at']),
      };

  String? _timestamp(Object? value) =>
      value is DateTime ? value.toUtc().toIso8601String() : value?.toString();

  Map<String, dynamic> _document(Object? value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return <String, dynamic>{'blocks': <Object?>[]};
  }

  Map<String, dynamic>? _validatedDocument(Object? raw) {
    final document = raw is Map ? Map<String, dynamic>.from(raw) : null;
    final blocks = document?['blocks'];
    if (blocks is! List || blocks.length > 40) return null;
    const allowed = {
      'heading',
      'text',
      'card',
      'button',
      'image',
      'team_badge',
      'stat_row',
      'divider',
      'spacer'
    };
    final cleaned = <Map<String, Object?>>[];
    for (final item in blocks) {
      if (item is! Map) return null;
      final type = item['type']?.toString() ?? '';
      final id = item['id']?.toString() ?? '';
      if (!allowed.contains(type) || id.isEmpty || id.length > 80) return null;
      final props = item['props'] is Map
          ? Map<String, Object?>.from(item['props'] as Map)
          : <String, Object?>{};
      final text = props['text']?.toString() ?? '';
      if (text.length > 300) return null;
      final align = props['align']?.toString();
      final spacing = props['spacing']?.toString();
      cleaned.add({
        'id': id,
        'type': type,
        'props': {
          'text': text,
          'align': const {'left', 'center', 'right'}.contains(align)
              ? align
              : 'left',
          'visible': props['visible'] is bool ? props['visible'] : true,
          'spacing': const {'small', 'medium', 'large'}.contains(spacing)
              ? spacing
              : 'medium',
        },
      });
    }
    return {'blocks': cleaned};
  }

  Future<Map<String, dynamic>?> _body(Request request) async {
    try {
      final decoded = jsonDecode(await request.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _audit(dynamic actor,
          {required String action,
          required String key,
          Map<String, Object?>? previous,
          Map<String, Object?>? next}) =>
      database.insertAdminAuditLog(
          employeeId: actor.id,
          employeeLogin: actor.login,
          area: 'studio',
          objectType: 'studio_section',
          objectId: key,
          action: action,
          previousValue: previous,
          newValue: next);

  Response _forbidden() =>
      jsonResponse({'error': 'Keine Berechtigung für PHÖNIX Studio.'},
          statusCode: 403);
  Response _notFound() =>
      jsonResponse({'error': 'Studio-Bereich nicht gefunden.'},
          statusCode: 404);
  Response _badRequest(String message) =>
      jsonResponse({'error': message}, statusCode: 400);
  Response _error(Object error) =>
      jsonResponse({'error': error.toString()}, statusCode: 500);
}
