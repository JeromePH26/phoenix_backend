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
  bool _schemaReady = false;
  Future<void>? _schemaInitializing;

  Router get router {
    final router = Router();
    router.get('/sections', _listSections);
    router.post('/sections', _createSection);
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
        SELECT s.section_key, s.name, s.description, s.category, s.app_path,
               s.is_custom, s.status,
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

  Future<Response> _createSection(Request request) async {
    final actor = await _actor(request, permission: 'appControl.manage');
    if (actor is Response) return actor;
    try {
      await _ensureSchema();
      final body = await _body(request);
      if (body == null) return _badRequest('Ungültige Eingabe.');
      final name = body['name']?.toString().trim() ?? '';
      final description = body['description']?.toString().trim() ?? '';
      final category = body['category']?.toString().trim() ?? '';
      final appPath = body['appPath']?.toString().trim() ?? '';
      final key = _sectionKey(body['key']?.toString() ?? name);
      if (name.isEmpty ||
          name.length > 80 ||
          description.isEmpty ||
          description.length > 240 ||
          category.isEmpty ||
          key == null) {
        return _badRequest(
            'Name, Beschreibung, Kategorie und gültiger Schlüssel sind erforderlich.');
      }
      if (await _section(key) != null)
        return _badRequest('Dieser Bereich existiert bereits.');
      final db = await database.connection();
      await db.execute(Sql.named('''
        INSERT INTO studio_sections
          (section_key, name, description, category, app_path, is_custom, sort_order)
        VALUES (@key, @name, @description, @category, @path, TRUE,
          (SELECT COALESCE(MAX(sort_order), 0) + 10 FROM studio_sections))
      '''), parameters: {
        'key': key,
        'name': name,
        'description': description,
        'category': category,
        'path': appPath.isEmpty ? null : appPath
      });
      await _audit(actor,
          action: 'studio.section_created',
          key: key,
          next: {'name': name, 'category': category, 'appPath': appPath});
      return _sectionDetail(request, key);
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

  Future<void> _ensureSchema() {
    if (_schemaReady) return Future.value();
    return _schemaInitializing ??= _createSchema();
  }

  Future<void> _createSchema() async {
    try {
      final db = await database.connection();
      await db.execute('''
      CREATE TABLE IF NOT EXISTS studio_sections (
        section_key TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        description TEXT NOT NULL,
        category TEXT NOT NULL DEFAULT 'Allgemein',
        app_path TEXT NULL,
        is_custom BOOLEAN NOT NULL DEFAULT FALSE,
        status TEXT NOT NULL DEFAULT 'disabled'
          CHECK (status IN ('active', 'disabled', 'draft', 'published')),
        sort_order INTEGER NOT NULL DEFAULT 0,
        active_version_id BIGINT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    ''');
      await db.execute(
          'ALTER TABLE studio_sections ADD COLUMN IF NOT EXISTS category TEXT NOT NULL DEFAULT \'Allgemein\'');
      await db.execute(
          'ALTER TABLE studio_sections ADD COLUMN IF NOT EXISTS app_path TEXT NULL');
      await db.execute(
          'ALTER TABLE studio_sections ADD COLUMN IF NOT EXISTS is_custom BOOLEAN NOT NULL DEFAULT FALSE');
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
        (
          'h2h',
          'Direkter Vergleich',
          'Vergangene Duelle der beiden Teams.',
          40
        ),
        (
          'historical_twins',
          'Historische Zwillinge',
          'Ähnliche historische Spielprofile.',
          50
        ),
        ('injuries', 'Ausfälle', 'Verletzte und gesperrte Spieler.', 60),
        (
          'home_overview',
          'Startseite',
          'Karten, Kennzahlen und Einstiegsbereich.',
          70
        ),
        (
          'games_list',
          'Spieleübersicht',
          'Tagesliste, Filter und Spielkarten.',
          80
        ),
        (
          'live_ticker',
          'Live-Ticker',
          'Live-Spiele, Ereignisse und Spielstand.',
          90
        ),
        (
          'recommendations',
          'PHÖNIX Empfehlungen',
          'Top-Tipps und Begründungen.',
          100
        ),
        (
          'best_markets',
          'Beste Märkte',
          'Marktübersicht und Wahrscheinlichkeiten.',
          110
        ),
        (
          'value_calculator',
          'Value-Rechner',
          'Quote, Wahrscheinlichkeit und Einsatz.',
          120
        ),
        (
          'combo_builder',
          'Kombi-Builder',
          'Auswahl und Darstellung einer Kombination.',
          130
        ),
        (
          'history',
          'Historie',
          'Abgerechnete Tipps, Filter und Performance.',
          140
        ),
        (
          'favorites',
          'Favoriten',
          'Favorisierte Spiele, Teams und Ligen.',
          150
        ),
        (
          'news',
          'PHÖNIX Berichte',
          'Eigene Spieltags- und Liga-Berichte.',
          160
        ),
        (
          'match_analysis',
          'Spielanalyse',
          'Analyse-Kopf, Top-Tipp und Märkte.',
          170
        ),
        (
          'probabilities',
          '1X2 Wahrscheinlichkeiten',
          'Wahrscheinlichkeitsbalken für Heim, Remis und Auswärts.',
          180
        ),
        (
          'team_goals',
          'Teamtore',
          'Teambezogene Torwahrscheinlichkeiten.',
          190
        ),
        ('league_table', 'Tabelle', 'Ligatabelle mit Wappen und Form.', 200),
        (
          'team_profile',
          'Teamprofil',
          'Teamdaten, Kader, Form und nächste Spiele.',
          210
        ),
        (
          'league_profile',
          'Ligaprofil',
          'Ligadaten, Tabelle und kommende Spiele.',
          220
        ),
        (
          'notifications',
          'Benachrichtigungen',
          'Tore, Anstoß, Ergebnisse und News.',
          230
        ),
        (
          'settings',
          'Einstellungen',
          'App-Einstellungen und Darstellungsoptionen.',
          240
        ),
        (
          'splash',
          'Startanimation',
          'Splashscreen, Branding und Ladevorgang.',
          250
        ),
      ];
      for (final section in sections) {
        await db.execute(Sql.named('''
        INSERT INTO studio_sections (section_key, name, description, category, app_path, sort_order)
        VALUES (@key, @name, @description, @category, @path, @sort)
        ON CONFLICT (section_key) DO NOTHING
      '''), parameters: {
          'key': section.$1,
          'name': section.$2,
          'description': section.$3,
          'category': _seedCategory(section.$1),
          'path': _seedPath(section.$1),
          'sort': section.$4,
        });
      }
      _schemaReady = true;
    } finally {
      if (!_schemaReady) _schemaInitializing = null;
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
        'category': row['category'],
        'appPath': row['app_path'],
        'isCustom': row['is_custom'],
        'status': row['status'],
        'updatedAt': _timestamp(row['updated_at']),
        'draftUpdatedAt': _timestamp(row['draft_updated_at']),
        'draftUpdatedBy': row['draft_updated_by'],
        'publishedVersion': row['published_version'],
        'publishedAt': _timestamp(row['published_at']),
      };

  String? _sectionKey(String raw) {
    final key = raw
        .toLowerCase()
        .trim()
        .replaceAll(RegExp('[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return key.isEmpty || key.length > 60 ? null : key;
  }

  String _seedCategory(String key) {
    if (const {
      'lineup',
      'match_detail',
      'form',
      'h2h',
      'historical_twins',
      'injuries',
      'match_analysis',
      'probabilities',
      'team_goals'
    }.contains(key)) return 'Spielansicht';
    if (const {'team_profile', 'league_profile', 'league_table'}.contains(key))
      return 'Profile & Ligen';
    if (const {'settings', 'notifications', 'splash'}.contains(key))
      return 'App & Konto';
    return 'Start & Navigation';
  }

  String _seedPath(String key) => '/$key';

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
    const tones = {
      'brand',
      'teal',
      'blue',
      'green',
      'amber',
      'red',
      'slate',
      'white'
    };
    const surfaces = {'transparent', 'surface', 'dark', 'brand'};
    const sizes = {'small', 'medium', 'large'};
    const weights = {'regular', 'medium', 'bold'};
    const paddings = {'none', 'small', 'medium', 'large'};
    const radii = {'small', 'medium', 'large', 'pill'};
    const borders = {'none', 'subtle', 'strong'};
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
      final tone = props['tone']?.toString();
      final surface = props['surface']?.toString();
      final textSize = props['textSize']?.toString();
      final textWeight = props['textWeight']?.toString();
      final padding = props['padding']?.toString();
      final radius = props['radius']?.toString();
      final border = props['border']?.toString();
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
          'tone': tones.contains(tone) ? tone : 'brand',
          'surface': surfaces.contains(surface) ? surface : 'surface',
          'textSize': sizes.contains(textSize) ? textSize : 'medium',
          'textWeight': weights.contains(textWeight) ? textWeight : 'regular',
          'padding': paddings.contains(padding) ? padding : 'medium',
          'radius': radii.contains(radius) ? radius : 'medium',
          'border': borders.contains(border) ? border : 'subtle',
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
