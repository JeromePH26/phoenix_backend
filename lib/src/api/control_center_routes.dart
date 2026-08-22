import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../config/app_config.dart';
import '../config/model_lab_config.dart';
import '../control_center/audit.dart';
import '../control_center/control_center_auth_guard.dart';
import '../control_center/employee.dart';
import '../control_center/employee_rules.dart';
import '../control_center/permissions.dart';
import '../control_center/session_policy.dart';
import '../database/database.dart';
import '../football_admin/football_admin_logic.dart';
import '../http/json_response.dart';
import '../model_lab/learning_dataset_builder.dart';
import '../security/totp.dart';
import '../services/firebase_push_service.dart';

/// PHÖNIX CONTROL CENTER Admin-API. Wird über
/// `router.mount('/api/admin/control-center/', ControlCenterRoutes(...).router)`
/// in `lib/src/api/routes.dart` eingehängt - exakt dasselbe Mount-Muster wie
/// `ModelLabRoutes`. Nutzt eine eigene, session-basierte Auth
/// (`admin_sessions` + `admin_employees`), komplett getrennt vom bestehenden
/// statischen `PHOENIX_ADMIN_TOKEN`, der für `/api/admin/*` (u.a.
/// `ModelLabRoutes`) unverändert weiterläuft.
class ControlCenterRoutes {
  ControlCenterRoutes({
    required this.config,
    required this.modelLabConfig,
    required this.database,
    required this.push,
  }) : guard = ControlCenterAuthGuard(database: database);

  final AppConfig config;
  final ModelLabConfig modelLabConfig;
  final PhoenixDatabase database;
  final FirebasePushService push;
  final ControlCenterAuthGuard guard;

  Router get router {
    final router = Router();

    router.post('/auth/login', _login);
    router.post('/auth/2fa/verify-login', _verifyTwoFactorLogin);
    router.get('/auth/2fa/status', _twoFactorStatus);
    router.post('/auth/2fa/setup', _setupTwoFactor);
    router.post('/auth/2fa/confirm', _confirmTwoFactor);
    router.post('/auth/2fa/disable', _disableTwoFactor);
    router.post('/auth/logout', _logout);
    router.get('/auth/me', _me);
    router.get('/employees', _listEmployees);
    router.post('/employees', _createEmployee);
    router.patch('/employees/<id|[0-9]+>', _updateEmployee);
    router.post('/employees/<id|[0-9]+>/disable', _disableEmployee);
    router.get('/audit-log', _auditLog);
    router.get('/overview', _overview);
    router.get('/search', _search);
    router.get('/api-usage', _apiUsage);
    router.get('/jobs', _jobs);
    router.get('/app-control/status', _appControlStatus);
    router.post('/app-control/status', _updateAppControlStatus);
    router.get('/app-control/modules', _listModules);
    router.patch('/app-control/modules/<moduleKey>', _updateModule);
    router.get('/devices', _listDevices);
    router.get('/devices/<installationId>', _deviceDetail);
    router.get('/support/assignable-employees', _assignableEmployees);
    router.get('/support/tickets', _listSupportTickets);
    router.get('/support/tickets/<id|[0-9]+>', _supportTicketDetail);
    router.patch('/support/tickets/<id|[0-9]+>', _updateSupportTicket);
    router.post('/support/tickets/<id|[0-9]+>/reply', _replySupportTicket);
    router.get('/news/articles', _listEditorialArticles);
    router.post('/news/articles', _createEditorialArticle);
    router.get('/news/articles/<id|[0-9]+>', _editorialArticleDetail);
    router.patch('/news/articles/<id|[0-9]+>', _updateEditorialArticle);
    router.get('/faq/articles', _listFaqArticles);
    router.post('/faq/articles', _createFaqArticle);
    router.patch('/faq/articles/<id|[0-9]+>', _updateFaqArticle);
    router.get('/advertising/campaigns', _listAdCampaigns);
    router.post('/advertising/campaigns', _createAdCampaign);
    router.get('/advertising/campaigns/<id|[0-9]+>', _adCampaignDetail);
    router.patch('/advertising/campaigns/<id|[0-9]+>', _updateAdCampaign);
    router.get('/push/broadcasts', _listPushBroadcasts);
    router.post('/push/broadcasts', _sendPushBroadcast);
    router.get('/push/target-count', _pushTargetCount);
    router.post('/push/test', _sendTestPush);
    router.get('/premium/features', _listPremiumFeaturesAdmin);
    router.patch('/premium/features/<featureKey>', _updatePremiumFeature);
    router.get('/feature-flags', _listFeatureFlags);
    router.post('/feature-flags', _createFeatureFlag);
    router.patch('/feature-flags/<flagKey>', _updateFeatureFlag);
    router.get('/release', _getReleaseConfig);
    router.patch('/release', _updateReleaseConfig);
    router.get('/incidents', _listIncidents);
    router.post('/incidents', _createIncident);
    router.get('/incidents/<id|[0-9]+>', _incidentDetail);
    router.patch('/incidents/<id|[0-9]+>', _updateIncident);
    router.get('/incidents/<id|[0-9]+>/timeline', _listIncidentTimeline);
    router.post('/incidents/<id|[0-9]+>/timeline', _addIncidentTimelineEvent);
    router.get('/security/sessions', _listSessions);
    router.get('/security/sessions/history', _sessionsHistory);
    router.post('/security/sessions/<token>/revoke', _revokeSession);
    router.get('/security/failed-logins', _listFailedLogins);
    router.get('/system-health', _systemHealth);
    router.get('/permissions/catalog', _permissionsCatalog);
    router.get('/system-audit', _systemAudit);
    router.get('/system-audit/history', _systemAuditHistory);
    router.get('/users', _listUsers);
    router.get('/users/<id|[0-9]+>', _userDetail);
    router.post('/users/<id|[0-9]+>/premium/grant', _grantUserPremium);
    router.post(
      '/users/<id|[0-9]+>/premium/<entitlementId|[0-9]+>/revoke',
      _revokeUserPremium,
    );
    router.post('/users/<id|[0-9]+>/bans', _banUser);
    router.post('/users/<id|[0-9]+>/bans/<banId|[0-9]+>/lift', _liftUserBan);
    router.post(
      '/users/<id|[0-9]+>/sessions/<token>/revoke',
      _revokeUserSession,
    );

    return router;
  }

  // -- Auth -----------------------------------------------------------

  Future<Response> _login(Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final login = body['login']?.toString().trim() ?? '';
      final password = body['password']?.toString() ?? '';
      if (login.isEmpty || password.isEmpty) return _invalidCredentials();

      // Section 32 (AN2): "Rate Limits" - vor jeder weiteren Prüfung, damit
      // ein Angreifer nicht beliebig viele Passwörter gegen denselben Login
      // durchprobieren kann. Zählt nur bereits gespeicherte fehlgeschlagene
      // Versuche, kein zusätzlicher Zustand nötig.
      final recentFailures = await database.countRecentFailedLogins(
        login: login,
        within: kLoginRateLimitWindow,
      );
      if (recentFailures >= kLoginRateLimitMaxAttempts) {
        return jsonResponse({
          'error': 'Zu viele fehlgeschlagene Login-Versuche. Bitte in ein paar Minuten erneut versuchen.',
        }, statusCode: 429);
      }

      final row = await database.adminEmployeeByLogin(login);
      if (row == null) {
        await database.recordFailedLogin(login: login, ip: _clientIp(request));
        return _invalidCredentials();
      }

      final passwordHash = row['password_hash']?.toString() ?? '';
      final employee = Employee.fromRow(row);
      final passwordOk =
          passwordHash.isNotEmpty && BCrypt.checkpw(password, passwordHash);
      if (!passwordOk || !employee.isActive) {
        await database.recordFailedLogin(login: login, ip: _clientIp(request));
        return _invalidCredentials();
      }

      // Section 32 (AN2): 2FA - Passwort korrekt, aber noch kein Session-
      // Token. Der Client muss zuerst /auth/2fa/verify-login mit dem
      // pendingToken + TOTP-Code aufrufen.
      final twoFactorStatus = await database.employeeTwoFactorStatus(employee.id);
      if (twoFactorStatus?['two_factor_enabled'] == true) {
        final pendingToken = generateSessionToken();
        await database.createPendingTwoFactorLogin(
          token: pendingToken,
          employeeId: employee.id,
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
          ip: _clientIp(request),
          userAgent: request.headers['user-agent'],
        );
        return jsonResponse({
          'requiresTwoFactor': true,
          'pendingToken': pendingToken,
        });
      }

      final token = generateSessionToken();
      final expiresAt = DateTime.now().toUtc().add(kControlCenterSessionTtl);
      await database.createAdminSession(
        employeeId: employee.id,
        token: token,
        expiresAt: expiresAt,
        ip: _clientIp(request),
        userAgent: request.headers['user-agent'],
      );
      await database.touchAdminEmployeeLastLogin(employee.id);

      return jsonResponse({
        'token': token,
        'expiresAt': expiresAt.toIso8601String(),
        'employee': {
          'id': employee.id,
          'name': employee.name,
          'login': employee.login,
          'email': employee.email,
          'role': employee.role,
          'department': employee.department,
        },
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // Section 32 (AN2): 2. Schritt nach requiresTwoFactor=true - konsumiert
  // das Einmal-Token und prüft den TOTP-Code, bevor eine echte Session
  // entsteht.
  Future<Response> _verifyTwoFactorLogin(Request request) async {
    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final pendingToken = body['pendingToken']?.toString() ?? '';
      final code = body['code']?.toString() ?? '';
      if (pendingToken.isEmpty || code.isEmpty) {
        return jsonResponse({'error': 'pendingToken und code sind erforderlich.'}, statusCode: 400);
      }

      final employeeId = await database.consumePendingTwoFactorLogin(pendingToken);
      if (employeeId == null) {
        return jsonResponse({
          'error': 'Ungültiger oder abgelaufener Vorgang. Bitte erneut einloggen.',
        }, statusCode: 401);
      }

      final status = await database.employeeTwoFactorStatus(employeeId);
      final secret = status?['two_factor_secret']?.toString();
      if (status?['two_factor_enabled'] != true || secret == null || secret.isEmpty) {
        return jsonResponse({'error': '2FA ist für dieses Konto nicht aktiv.'}, statusCode: 400);
      }
      if (!verifyTotpCode(secret, code)) {
        return jsonResponse({'error': 'Falscher Code.'}, statusCode: 401);
      }

      final row = await database.adminEmployeeById(employeeId);
      if (row == null) {
        return jsonResponse({'error': 'Mitarbeiter nicht gefunden.'}, statusCode: 404);
      }
      final employee = Employee.fromRow(row);
      if (!employee.isActive) {
        return jsonResponse({'error': 'Konto ist deaktiviert.'}, statusCode: 403);
      }

      final token = generateSessionToken();
      final expiresAt = DateTime.now().toUtc().add(kControlCenterSessionTtl);
      await database.createAdminSession(
        employeeId: employee.id,
        token: token,
        expiresAt: expiresAt,
        ip: _clientIp(request),
        userAgent: request.headers['user-agent'],
      );
      await database.touchAdminEmployeeLastLogin(employee.id);

      return jsonResponse({
        'token': token,
        'expiresAt': expiresAt.toIso8601String(),
        'employee': {
          'id': employee.id,
          'name': employee.name,
          'login': employee.login,
          'email': employee.email,
          'role': employee.role,
          'department': employee.department,
        },
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _twoFactorStatus(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    try {
      final status = await database.employeeTwoFactorStatus(actor.id);
      return jsonResponse({'enabled': status?['two_factor_enabled'] == true});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // Section 32 (AN2): eigenes 2FA einrichten - erzeugt ein neues Secret,
  // aktiviert aber noch nichts (siehe _confirmTwoFactorSetup).
  Future<Response> _setupTwoFactor(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;

    try {
      final secret = generateTotpSecret();
      await database.setEmployeeTwoFactorSecret(actor.id, secret);
      return jsonResponse({
        'secret': secret,
        'otpauthUrl': totpAuthUrl(secret: secret, accountLogin: actor.login),
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _confirmTwoFactor(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final code = body['code']?.toString() ?? '';
      final status = await database.employeeTwoFactorStatus(actor.id);
      final secret = status?['two_factor_secret']?.toString();
      if (secret == null || secret.isEmpty) {
        return jsonResponse({
          'error': 'Zuerst /auth/2fa/setup aufrufen, um ein Secret zu erzeugen.',
        }, statusCode: 400);
      }
      if (!verifyTotpCode(secret, code)) {
        return jsonResponse({'error': 'Falscher Code.'}, statusCode: 400);
      }
      await database.enableEmployeeTwoFactor(actor.id);
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'security',
        objectType: 'employee',
        objectId: actor.id.toString(),
        action: 'two_factor.enable',
        ip: _clientIp(request),
      );
      return jsonResponse({'status': 'enabled'});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _disableTwoFactor(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final code = body['code']?.toString() ?? '';
      final status = await database.employeeTwoFactorStatus(actor.id);
      final secret = status?['two_factor_secret']?.toString();
      if (status?['two_factor_enabled'] != true || secret == null || secret.isEmpty) {
        return jsonResponse({'error': '2FA ist für dieses Konto nicht aktiv.'}, statusCode: 400);
      }
      if (!verifyTotpCode(secret, code)) {
        return jsonResponse({'error': 'Falscher Code.'}, statusCode: 400);
      }
      await database.disableEmployeeTwoFactor(actor.id);
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'security',
        objectType: 'employee',
        objectId: actor.id.toString(),
        action: 'two_factor.disable',
        ip: _clientIp(request),
      );
      return jsonResponse({'status': 'disabled'});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _logout(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final token = _bearerToken(request);
    if (token != null) await database.revokeAdminSession(token);
    return jsonResponse({'status': 'logged_out'});
  }

  Future<Response> _me(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    return jsonResponse({'employee': auth.employee!.toPublicJson()});
  }

  // -- Employees --------------------------------------------------------

  Future<Response> _listEmployees(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('employees.view')) return _forbidden();

    try {
      final rows = await database.listAdminEmployeesWithActiveSessionCounts();
      final employees = rows.map((row) {
        final employee = Employee.fromRow(row);
        return <String, Object?>{
          ...employee.toPublicJson(),
          'activeSessionCount': (row['active_session_count'] as int?) ?? 0,
        };
      }).toList();
      return jsonResponse({'count': employees.length, 'employees': employees});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _createEmployee(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('employees.manage')) return _forbidden();

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }

      final name = body['name']?.toString().trim() ?? '';
      final login = body['login']?.toString().trim() ?? '';
      final email = body['email']?.toString().trim() ?? '';
      final password = body['password']?.toString() ?? '';
      final role = body['role']?.toString().trim().toUpperCase() ?? '';
      final department = body['department']?.toString().trim();

      if (name.isEmpty || login.isEmpty || email.isEmpty || password.isEmpty) {
        return jsonResponse({
          'error': 'name, login, email und password sind erforderlich.',
        }, statusCode: 400);
      }
      if (!kValidRoles.contains(role)) {
        return jsonResponse({
          'error': 'Ungültige Rolle. Erlaubt: ${kValidRoles.join(', ')}.',
        }, statusCode: 400);
      }
      if (!canAssignRole(actorRole: actor.role, targetRole: role)) {
        return jsonResponse({
          'error': 'Nur OWNER darf einen OWNER-Mitarbeiter anlegen.',
        }, statusCode: 403);
      }

      final overridesError = _extractPermissionOverrides(body['permissionOverrides']);
      if (overridesError.error != null) {
        return jsonResponse({'error': overridesError.error}, statusCode: 400);
      }

      final passwordHash = BCrypt.hashpw(password, BCrypt.gensalt());
      final created = await database.insertAdminEmployee(
        name: name,
        login: login,
        email: email,
        passwordHash: passwordHash,
        role: role,
        department: department?.isEmpty == true ? null : department,
        permissionOverrides: overridesError.overrides,
      );
      final createdEmployee = Employee.fromRow(created);

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'administration',
        objectType: 'employee',
        objectId: createdEmployee.id.toString(),
        action: 'employee.create',
        newValue: createdEmployee.toPublicJson(),
        ip: _clientIp(request),
      );

      return jsonResponse({'employee': createdEmployee.toPublicJson()}, statusCode: 201);
    } catch (error) {
      final message = error.toString();
      if (message.toLowerCase().contains('duplicate key') ||
          message.toLowerCase().contains('unique')) {
        return jsonResponse({'error': 'Login oder E-Mail bereits vergeben.'}, statusCode: 409);
      }
      return jsonResponse({'error': message}, statusCode: 500);
    }
  }

  Future<Response> _updateEmployee(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('employees.manage')) return _forbidden();

    final employeeId = int.tryParse(id);
    if (employeeId == null) {
      return jsonResponse({'error': 'Ungültige Employee-ID.'}, statusCode: 400);
    }

    try {
      final existingRow = await database.adminEmployeeById(employeeId);
      if (existingRow == null) {
        return jsonResponse({'error': 'Mitarbeiter nicht gefunden.'}, statusCode: 404);
      }
      final existing = Employee.fromRow(existingRow);

      if (!canModifyEmployeeRow(actorRole: actor.role, targetCurrentRole: existing.role)) {
        return jsonResponse({
          'error': 'Nur OWNER darf einen OWNER-Mitarbeiter bearbeiten.',
        }, statusCode: 403);
      }

      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }

      String? role;
      if (body.containsKey('role')) {
        role = body['role']?.toString().trim().toUpperCase();
        if (role == null || !kValidRoles.contains(role)) {
          return jsonResponse({'error': 'Ungültige Rolle.'}, statusCode: 400);
        }
        if (!canAssignRole(actorRole: actor.role, targetRole: role)) {
          return jsonResponse({
            'error': 'Nur OWNER darf die Rolle OWNER vergeben.',
          }, statusCode: 403);
        }
        // Owner-Lockout-Schutz gilt sinngemäß auch für eine Rollenänderung
        // weg von OWNER, nicht nur für das explizite Deaktivieren.
        if (existing.isOwner && role != 'OWNER') {
          final activeOwners = await database.countActiveOwners();
          if (wouldRemoveLastActiveOwner(
            targetIsOwner: true,
            targetCurrentlyActive: existing.isActive,
            activeOwnerCount: activeOwners,
          )) {
            return jsonResponse({
              'error': 'Der letzte aktive OWNER kann nicht seine OWNER-Rolle verlieren.',
            }, statusCode: 400);
          }
        }
      }

      final departmentProvided = body.containsKey('department');
      final department = departmentProvided
          ? body['department']?.toString().trim()
          : null;

      final overridesRaw = body.containsKey('permissionOverrides')
          ? body['permissionOverrides']
          : null;
      Map<String, Object?>? permissionOverrides;
      if (body.containsKey('permissionOverrides')) {
        final overridesResult = _extractPermissionOverrides(overridesRaw);
        if (overridesResult.error != null) {
          return jsonResponse({'error': overridesResult.error}, statusCode: 400);
        }
        permissionOverrides = overridesResult.overrides;
      }

      String? status;
      if (body.containsKey('status')) {
        status = body['status']?.toString().trim();
        if (status != 'active' && status != 'disabled') {
          return jsonResponse({
            'error': 'status muss active oder disabled sein.',
          }, statusCode: 400);
        }
        if (status == 'disabled') {
          final activeOwners = await database.countActiveOwners();
          if (wouldRemoveLastActiveOwner(
            targetIsOwner: existing.isOwner,
            targetCurrentlyActive: existing.isActive,
            activeOwnerCount: activeOwners,
          )) {
            return jsonResponse({
              'error': 'Der letzte aktive OWNER kann nicht deaktiviert werden.',
            }, statusCode: 400);
          }
        }
      }

      Map<String, Object?>? updatedRow;
      final hasNonStatusUpdates =
          role != null || departmentProvided || permissionOverrides != null;
      if (hasNonStatusUpdates) {
        updatedRow = await database.updateAdminEmployee(
          id: employeeId,
          role: role,
          departmentProvided: departmentProvided,
          department: (department?.isEmpty ?? false) ? null : department,
          permissionOverrides: permissionOverrides,
        );
      }

      if (status == 'disabled') {
        updatedRow = await database.disableAdminEmployeeAndRevokeSessions(employeeId);
      } else if (status == 'active') {
        updatedRow = await database.updateAdminEmployee(id: employeeId, status: 'active');
      }

      updatedRow ??= await database.adminEmployeeById(employeeId);
      if (updatedRow == null) {
        return jsonResponse({'error': 'Mitarbeiter nicht gefunden.'}, statusCode: 404);
      }
      final updated = Employee.fromRow(updatedRow);

      final diff = diffEmployeeFields(
        before: existing.toPublicJson(),
        after: updated.toPublicJson(),
      );
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'administration',
        objectType: 'employee',
        objectId: employeeId.toString(),
        action: 'employee.update',
        previousValue: diff.previousValue,
        newValue: diff.newValue,
        ip: _clientIp(request),
      );

      return jsonResponse({'employee': updated.toPublicJson()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _disableEmployee(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('employees.manage')) return _forbidden();

    final employeeId = int.tryParse(id);
    if (employeeId == null) {
      return jsonResponse({'error': 'Ungültige Employee-ID.'}, statusCode: 400);
    }

    try {
      final existingRow = await database.adminEmployeeById(employeeId);
      if (existingRow == null) {
        return jsonResponse({'error': 'Mitarbeiter nicht gefunden.'}, statusCode: 404);
      }
      final existing = Employee.fromRow(existingRow);

      if (!canModifyEmployeeRow(actorRole: actor.role, targetCurrentRole: existing.role)) {
        return jsonResponse({
          'error': 'Nur OWNER darf einen OWNER-Mitarbeiter deaktivieren.',
        }, statusCode: 403);
      }

      final activeOwners = await database.countActiveOwners();
      if (wouldRemoveLastActiveOwner(
        targetIsOwner: existing.isOwner,
        targetCurrentlyActive: existing.isActive,
        activeOwnerCount: activeOwners,
      )) {
        return jsonResponse({
          'error': 'Der letzte aktive OWNER kann nicht deaktiviert werden.',
        }, statusCode: 400);
      }

      final updatedRow = await database.disableAdminEmployeeAndRevokeSessions(employeeId);
      if (updatedRow == null) {
        return jsonResponse({'error': 'Mitarbeiter nicht gefunden.'}, statusCode: 404);
      }
      final updated = Employee.fromRow(updatedRow);

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'administration',
        objectType: 'employee',
        objectId: employeeId.toString(),
        action: 'employee.disable',
        previousValue: {'status': existing.status},
        newValue: {'status': updated.status},
        ip: _clientIp(request),
      );

      return jsonResponse({'employee': updated.toPublicJson()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Users (PHÖNIX Account System) --------------------------------------

  Future<Response> _listUsers(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('users.view')) return _forbidden();

    final query = request.url.queryParameters;
    final limit = clampListLimit(int.tryParse(query['limit'] ?? ''));
    final offset = clampOffset(int.tryParse(query['offset'] ?? ''));
    try {
      final result = await database.listUsersAdmin(
        search: query['search'],
        accountStatus: query['accountStatus'],
        hasPremium: parseBoolParam(query['hasPremium']),
        limit: limit,
        offset: offset,
      );
      return jsonResponse(_jsonSafe(result));
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _userDetail(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('users.view')) return _forbidden();

    final userId = int.tryParse(id);
    if (userId == null) {
      return jsonResponse({'error': 'Ungültige User-ID.'}, statusCode: 400);
    }
    try {
      final detail = await database.userAdminDetail(userId);
      if (detail == null) {
        return jsonResponse({'error': 'Nutzer nicht gefunden.'}, statusCode: 404);
      }
      return jsonResponse(_jsonSafe(detail));
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _grantUserPremium(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('premium.manualGrant')) return _forbidden();

    final userId = int.tryParse(id);
    if (userId == null) {
      return jsonResponse({'error': 'Ungültige User-ID.'}, statusCode: 400);
    }

    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(await request.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      body = decoded;
    } catch (_) {
      return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
    }

    const allowedSources = {
      'MANUAL', 'PROMOTION', 'STAFF', 'PARTNER', 'GOOGLE_PLAY', 'WEBSITE',
    };
    final source = body['source']?.toString().trim().toUpperCase() ?? '';
    if (!allowedSources.contains(source)) {
      return jsonResponse({
        'error': 'source muss eine von ${allowedSources.join(", ")} sein.',
      }, statusCode: 400);
    }
    final reason = body['reason']?.toString().trim();
    if (reason == null || reason.isEmpty) {
      return jsonResponse({'error': 'reason ist erforderlich.'}, statusCode: 400);
    }
    final tier = body['tier']?.toString();
    final expiresAtRaw = body['expiresAt']?.toString();
    final expiresAt = expiresAtRaw == null || expiresAtRaw.isEmpty
        ? null
        : DateTime.tryParse(expiresAtRaw);
    if (expiresAtRaw != null && expiresAtRaw.isNotEmpty && expiresAt == null) {
      return jsonResponse({'error': 'expiresAt ist kein gültiges Datum.'}, statusCode: 400);
    }

    try {
      final entitlement = await database.grantUserPremium(
        userId: userId,
        source: source,
        tier: tier,
        expiresAt: expiresAt,
        reason: reason,
        grantedByEmployeeId: actor.id,
      );

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'premium',
        objectType: 'user',
        objectId: id,
        action: 'premium.manual_grant',
        newValue: {'source': source, 'tier': tier, 'expiresAt': expiresAtRaw},
        reason: reason,
        ip: _clientIp(request),
      );

      return jsonResponse(_jsonSafe({'entitlement': entitlement}), statusCode: 201);
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _revokeUserPremium(
    Request request,
    String id,
    String entitlementId,
  ) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('premium.manualRevoke')) return _forbidden();

    final parsedEntitlementId = int.tryParse(entitlementId);
    if (parsedEntitlementId == null) {
      return jsonResponse({'error': 'Ungültige Entitlement-ID.'}, statusCode: 400);
    }

    String? reason;
    try {
      final decoded = jsonDecode(await request.readAsString());
      if (decoded is Map<String, dynamic>) {
        reason = decoded['reason']?.toString();
      }
    } catch (_) {
      // Body ist optional für Revoke.
    }

    try {
      final updated = await database.revokeUserPremium(
        entitlementId: parsedEntitlementId,
      );
      if (updated == null) {
        return jsonResponse({'error': 'Entitlement nicht gefunden.'}, statusCode: 404);
      }

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'premium',
        objectType: 'user',
        objectId: id,
        action: 'premium.manual_revoke',
        previousValue: {'entitlementId': parsedEntitlementId},
        reason: reason,
        ip: _clientIp(request),
      );

      return jsonResponse(_jsonSafe({'entitlement': updated}));
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _banUser(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('users.suspend')) return _forbidden();

    final userId = int.tryParse(id);
    if (userId == null) {
      return jsonResponse({'error': 'Ungültige User-ID.'}, statusCode: 400);
    }

    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(await request.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      body = decoded;
    } catch (_) {
      return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
    }

    final reason = body['reason']?.toString().trim();
    final internalReport = body['internalReport']?.toString().trim();
    if (reason == null || reason.isEmpty) {
      return jsonResponse({'error': 'reason ist erforderlich.'}, statusCode: 400);
    }
    if (internalReport == null || internalReport.isEmpty) {
      return jsonResponse({'error': 'internalReport ist erforderlich.'}, statusCode: 400);
    }
    const allowedDurations = {
      '1_HOUR', '24_HOURS', '7_DAYS', '30_DAYS', 'CUSTOM', 'PERMANENT',
    };
    final durationType = body['durationType']?.toString().trim().toUpperCase() ?? '';
    if (!allowedDurations.contains(durationType)) {
      return jsonResponse({
        'error': 'durationType muss eine von ${allowedDurations.join(", ")} sein.',
      }, statusCode: 400);
    }
    final expiresAtRaw = body['expiresAt']?.toString();
    final expiresAt = expiresAtRaw == null || expiresAtRaw.isEmpty
        ? null
        : DateTime.tryParse(expiresAtRaw);
    if (durationType == 'CUSTOM' && expiresAt == null) {
      return jsonResponse({
        'error': 'expiresAt ist bei durationType=CUSTOM erforderlich.',
      }, statusCode: 400);
    }
    final supportTicketId = int.tryParse(body['supportTicketId']?.toString() ?? '');

    try {
      final ban = await database.banUser(
        userId: userId,
        reason: reason,
        internalReport: internalReport,
        durationType: durationType,
        expiresAt: expiresAt ?? _expiryForDuration(durationType),
        supportTicketId: supportTicketId,
        createdByEmployeeId: actor.id,
      );

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'users',
        objectType: 'user',
        objectId: id,
        action: 'user.ban',
        newValue: {'durationType': durationType, 'caseNumber': ban['case_number']},
        reason: reason,
        comment: internalReport,
        ip: _clientIp(request),
      );

      return jsonResponse(_jsonSafe({'ban': ban}), statusCode: 201);
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  DateTime? _expiryForDuration(String durationType) {
    final now = DateTime.now().toUtc();
    switch (durationType) {
      case '1_HOUR':
        return now.add(const Duration(hours: 1));
      case '24_HOURS':
        return now.add(const Duration(hours: 24));
      case '7_DAYS':
        return now.add(const Duration(days: 7));
      case '30_DAYS':
        return now.add(const Duration(days: 30));
      default:
        return null; // CUSTOM (bereits explizit gesetzt) / PERMANENT
    }
  }

  Future<Response> _liftUserBan(Request request, String id, String banId) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('users.unsuspend')) return _forbidden();

    final parsedBanId = int.tryParse(banId);
    if (parsedBanId == null) {
      return jsonResponse({'error': 'Ungültige Ban-ID.'}, statusCode: 400);
    }

    String? liftReason;
    try {
      final decoded = jsonDecode(await request.readAsString());
      if (decoded is Map<String, dynamic>) {
        liftReason = decoded['reason']?.toString();
      }
    } catch (_) {
      // Body optional.
    }

    try {
      final lifted = await database.liftUserBan(
        banId: parsedBanId,
        liftedByEmployeeId: actor.id,
        liftReason: liftReason,
      );
      if (lifted == null) {
        return jsonResponse({
          'error': 'Sperre nicht gefunden oder bereits aufgehoben.',
        }, statusCode: 404);
      }

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'users',
        objectType: 'user',
        objectId: id,
        action: 'user.unban',
        previousValue: {'banId': parsedBanId},
        reason: liftReason,
        ip: _clientIp(request),
      );

      return jsonResponse(_jsonSafe({'ban': lifted}));
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _revokeUserSession(
    Request request,
    String id,
    String token,
  ) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('users.manage')) return _forbidden();

    try {
      final revoked = await database.revokeUserSessionByToken(token);
      if (!revoked) {
        return jsonResponse({
          'error': 'Session nicht gefunden oder bereits widerrufen.',
        }, statusCode: 404);
      }

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'users',
        objectType: 'user',
        objectId: id,
        action: 'user.session_revoke',
        ip: _clientIp(request),
      );

      return jsonResponse({'status': 'revoked'});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Audit log ----------------------------------------------------------

  Future<Response> _auditLog(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('audit.view')) return _forbidden();

    final params = request.url.queryParameters;
    final area = params['area'];
    final employeeIdParam = params['employeeId'];
    final employeeId = employeeIdParam == null ? null : int.tryParse(employeeIdParam);
    final action = params['action'];
    final objectId = params['objectId'];
    final dateFrom = params['dateFrom'] == null ? null : DateTime.tryParse(params['dateFrom']!);
    final dateTo = params['dateTo'] == null ? null : DateTime.tryParse(params['dateTo']!);
    final limit = int.tryParse(params['limit'] ?? '') ?? 100;
    final offset = int.tryParse(params['offset'] ?? '') ?? 0;

    try {
      final result = await database.listAdminAuditLog(
        area: area,
        employeeId: employeeId,
        action: action,
        objectId: objectId,
        dateFrom: dateFrom,
        dateTo: dateTo,
        limit: limit,
        offset: offset,
      );
      final entries = result['entries'] as List<Map<String, Object?>>;
      return jsonResponse({
        'entries': entries.map(_jsonSafe).toList(),
        'total': result['total'],
        'limit': limit,
        'offset': offset,
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Overview -------------------------------------------------------

  Future<Response> _overview(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('overview.view')) return _forbidden();

    try {
      final apiUsage = await database.apiSportsDailyUsageToday();
      final whitelistCounts = await database.footballLeagueManualStatusCounts();

      // ModelLab-Zahlen: bewusst dieselben Service-/DB-Methoden wie
      // `ModelLabRoutes./overview`, um keine zweite, potenziell abweichende
      // Berechnung zu pflegen.
      final audit = await LearningDatasetBuilder(
        database: database,
        config: modelLabConfig,
      ).auditEligibility();
      final leagues = await database.modelLabWhitelistedLeagues();
      final champions = await database.allModelVersions(status: 'champion');
      final challengers = await database.allModelVersions(status: 'challenger');
      final shadowCount = await database.countShadowPredictions();
      final lastRuns = await database.listLearningRuns(limit: 1);

      final jobStatus = await database.jobStatusBreakdown();
      final missingLeagueLogos = await database.countWhitelistedLeaguesMissingLogo();
      final footballToday = await database.footballDailyOverviewStats(
        day: _berlinNow(),
      );
      final todayStats = await database.controlCenterTodayStats();

      return jsonResponse({
        'apiUsage': apiUsage.map((row) => _jsonSafe(_apiUsageRowWithLimit(row))).toList(),
        'footballToday': footballToday,
        'today': todayStats,
        'whitelist': {
          'auto': whitelistCounts['auto'] ?? 0,
          'whitelist': whitelistCounts['whitelist'] ?? 0,
          'blacklist': whitelistCounts['blacklist'] ?? 0,
        },
        'modelLab': {
          'whitelistLeagues': leagues.length,
          'activeChampions': champions.length,
          'activeChallengers': challengers.length,
          'shadowPredictions': shadowCount,
          'learningEligibleMatches': audit.eligible,
          'lastLearningRun': lastRuns.isEmpty ? null : _jsonSafe(lastRuns.first),
        },
        'pendingJobs': _jsonSafe(jobStatus),
        'warnings': {
          'missingLeagueLogos': missingLeagueLogos,
        },
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- API Usage --------------------------------------------------------

  // Section 25 (AN2, "Höchste Priorität"): reichert jede Zeile um das
  // konfigurierte Tageslimit an (API_<NAME>_DAILY_LIMIT), damit das
  // Frontend Prozent/Verbleibend/Warnschwellen berechnen kann, statt selbst
  // zu raten. Kein Limit konfiguriert = null, niemals ein erfundener Wert.
  Future<Response> _apiUsage(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('apiUsage.view')) return _forbidden();

    try {
      final today = await database.apiSportsDailyUsageToday();
      final history = await database.apiSportsDailyUsageHistory(days: 14);
      return jsonResponse({
        'today': today.map((row) => _jsonSafe(_apiUsageRowWithLimit(row))).toList(),
        'history': history.map((row) => _jsonSafe(_apiUsageRowWithLimit(row))).toList(),
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Jobs ---------------------------------------------------------------

  Future<Response> _jobs(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('jobs.view')) return _forbidden();

    try {
      final dailyPipeline = await database.recentFootballDailyPipelineJobs(limit: 10);
      final settlement = await database.recentFootballMatchSettlementJobs(limit: 10);
      final learningRuns = await database.listLearningRuns(limit: 10);
      return jsonResponse({
        'dailyPipeline': dailyPipeline.map(_jsonSafe).toList(),
        'settlement': settlement.map(_jsonSafe).toList(),
        'learningRuns': learningRuns.map(_jsonSafe).toList(),
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- App Control ----------------------------------------------------------

  Future<Response> _appControlStatus(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('appControl.view')) return _forbidden();

    try {
      final status = await database.appControlStatus();
      return jsonResponse(_jsonSafe(status));
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // Section 39/81/82: App-Status ist eine Danger-Zone-Aktion (kann die App
  // für alle Nutzer abschalten), deshalb eigenes Recht (`appControl.manage`,
  // nicht in den Default-Rechten von SUPPORT/CONTENT/MARKETING) und ein
  // Pflicht-Grund wie bei den Football-Match-Flags.
  Future<Response> _updateAppControlStatus(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('appControl.manage')) return _forbidden();

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }

      final status = body['status']?.toString().trim().toUpperCase() ?? '';
      final reason = body['reason']?.toString().trim() ?? '';
      final message = body['message']?.toString().trim();
      final hasMaintenanceUntilKey = body.containsKey('maintenanceUntil');
      final maintenanceUntilRaw = body['maintenanceUntil']?.toString().trim();

      const validStatuses = {'ACTIVE', 'MAINTENANCE', 'DISABLED'};
      if (!validStatuses.contains(status)) {
        return jsonResponse({
          'error': 'status muss ACTIVE, MAINTENANCE oder DISABLED sein.',
        }, statusCode: 400);
      }
      if (reason.isEmpty) {
        return jsonResponse({'error': 'reason ist erforderlich.'}, statusCode: 400);
      }
      DateTime? maintenanceUntil;
      if (hasMaintenanceUntilKey && maintenanceUntilRaw != null && maintenanceUntilRaw.isNotEmpty) {
        maintenanceUntil = DateTime.tryParse(maintenanceUntilRaw);
        if (maintenanceUntil == null) {
          return jsonResponse({'error': 'maintenanceUntil ist kein gültiges Datum.'}, statusCode: 400);
        }
      }

      final previous = await database.appControlStatus();
      final updated = await database.setAppControlStatus(
        status: status,
        message: (message?.isEmpty ?? true) ? null : message,
        updatedBy: actor.login,
        maintenanceUntil: hasMaintenanceUntilKey
            ? maintenanceUntil
            : PhoenixDatabase.unsetSentinel,
      );

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'app_control',
        objectType: 'app_status',
        objectId: '1',
        action: 'app_control.status_change',
        previousValue: previous,
        newValue: updated,
        reason: reason,
        ip: _clientIp(request),
      );

      return jsonResponse({'status': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Module Control (Section 40) ------------------------------------------

  Future<Response> _listModules(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('appControl.view')) return _forbidden();

    try {
      final modules = await database.listModuleControls();
      return jsonResponse({'modules': modules.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _updateModule(Request request, String moduleKey) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('appControl.manage')) return _forbidden();

    try {
      final body = jsonDecode(await request.readAsString());
      final enabled = body is Map ? body['enabled'] as bool? : null;
      if (enabled == null) {
        return jsonResponse({'error': 'enabled (bool) ist erforderlich.'}, statusCode: 400);
      }
      final updated = await database.updateModuleControl(
        moduleKey: moduleKey,
        enabled: enabled,
        updatedBy: actor.login,
      );
      if (updated == null) {
        return jsonResponse({'error': 'Modul nicht gefunden.'}, statusCode: 404);
      }
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'app_control',
        objectType: 'module',
        objectId: moduleKey,
        action: 'module.toggle',
        newValue: updated,
        ip: _clientIp(request),
      );
      return jsonResponse({'module': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Devices (Phase 4, installation-based - kein Nutzerkonto-System) ----

  Future<Response> _listDevices(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('devices.view')) return _forbidden();

    try {
      final devices = await database.listPushDevices();
      return jsonResponse({'devices': devices.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _deviceDetail(Request request, String installationId) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('devices.view')) return _forbidden();

    try {
      final device = await database.pushDeviceDetail(installationId);
      if (device == null) {
        return jsonResponse({'error': 'Gerät nicht gefunden.'}, statusCode: 404);
      }
      final tickets = await database.supportTicketsForInstallation(installationId);
      return jsonResponse({
        'device': _jsonSafe(device),
        'tickets': tickets.map(_jsonSafe).toList(),
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Support Tickets (Phase 4, installation-based) -----------------------

  Future<Response> _assignableEmployees(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('support.view')) return _forbidden();

    try {
      final employees = await database.listActiveAdminEmployeesMinimal();
      return jsonResponse({'employees': employees.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _listSupportTickets(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('support.view')) return _forbidden();

    final query = request.url.queryParameters;
    try {
      final tickets = await database.listSupportTickets(
        status: query['status'],
        category: query['category'],
        assignedEmployeeId: int.tryParse(query['assignedEmployeeId'] ?? ''),
      );
      return jsonResponse({'tickets': tickets.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _supportTicketDetail(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('support.view')) return _forbidden();

    final ticketId = int.parse(id);
    try {
      final ticket = await database.supportTicket(ticketId);
      if (ticket == null) {
        return jsonResponse({'error': 'Ticket nicht gefunden.'}, statusCode: 404);
      }
      final messages = await database.supportTicketMessages(ticketId);
      return jsonResponse({
        'ticket': _jsonSafe(ticket),
        'messages': messages.map(_jsonSafe).toList(),
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _updateSupportTicket(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('support.manage')) return _forbidden();

    final ticketId = int.parse(id);
    const validStatuses = {'NEU', 'IN_BEARBEITUNG', 'WARTET_AUF_NUTZER', 'GELOEST', 'GESCHLOSSEN'};
    const validPriorities = {'niedrig', 'normal', 'hoch', 'dringend'};
    const validCategories = {'frage', 'bug', 'premium', 'match', 'sonstiges'};

    try {
      final before = await database.supportTicket(ticketId);
      if (before == null) {
        return jsonResponse({'error': 'Ticket nicht gefunden.'}, statusCode: 404);
      }

      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final status = body['status']?.toString();
      final priority = body['priority']?.toString();
      final category = body['category']?.toString();
      final hasAssignedKey = body.containsKey('assignedEmployeeId');
      final assignedEmployeeId = body['assignedEmployeeId'] == null
          ? null
          : int.tryParse(body['assignedEmployeeId'].toString());

      if (status != null && !validStatuses.contains(status)) {
        return jsonResponse({'error': 'Ungültiger status.'}, statusCode: 400);
      }
      if (priority != null && !validPriorities.contains(priority)) {
        return jsonResponse({'error': 'Ungültige priority.'}, statusCode: 400);
      }
      if (category != null && !validCategories.contains(category)) {
        return jsonResponse({'error': 'Ungültige category.'}, statusCode: 400);
      }

      final updated = await database.updateSupportTicket(
        id: ticketId,
        status: status,
        priority: priority,
        category: category,
        assignedEmployeeId: assignedEmployeeId,
        clearAssignedEmployee: hasAssignedKey && body['assignedEmployeeId'] == null,
      );

      final diff = diffEmployeeFields(before: before, after: updated!);
      if (diff.previousValue.isNotEmpty) {
        await database.insertAdminAuditLog(
          employeeId: actor.id,
          employeeLogin: actor.login,
          area: 'support',
          objectType: 'ticket',
          objectId: id,
          action: 'ticket.update',
          previousValue: diff.previousValue,
          newValue: diff.newValue,
          ip: _clientIp(request),
        );
      }

      return jsonResponse({'ticket': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _replySupportTicket(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('support.manage')) return _forbidden();

    final ticketId = int.parse(id);
    try {
      final ticket = await database.supportTicket(ticketId);
      if (ticket == null) {
        return jsonResponse({'error': 'Ticket nicht gefunden.'}, statusCode: 404);
      }

      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final message = body['message']?.toString().trim() ?? '';
      final internalNote = body['internalNote'] == true;
      if (message.isEmpty) {
        return jsonResponse({'error': 'message ist erforderlich.'}, statusCode: 400);
      }

      final saved = await database.addSupportTicketMessage(
        ticketId: ticketId,
        authorType: 'employee',
        employeeId: actor.id,
        message: message,
        internalNote: internalNote,
      );
      // Eine sichtbare Mitarbeiterantwort setzt das Ticket auf "wartet auf
      // Nutzer" (Section 22/23), eine interne Notiz ändert den Status nicht.
      if (!internalNote) {
        await database.updateSupportTicket(id: ticketId, status: 'WARTET_AUF_NUTZER');
      }

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'support',
        objectType: 'ticket',
        objectId: id,
        action: internalNote ? 'ticket.internal_note' : 'ticket.reply',
        ip: _clientIp(request),
      );

      return jsonResponse({'message': _jsonSafe(saved)}, statusCode: 201);
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- News CMS (Phase 5, manuell verfasst) --------------------------------

  Future<Response> _listEditorialArticles(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('news.view')) return _forbidden();

    final query = request.url.queryParameters;
    try {
      final articles = await database.listEditorialArticles(
        status: query['status'],
        category: query['category'],
      );
      return jsonResponse({'articles': articles.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _createEditorialArticle(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('news.manage')) return _forbidden();

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final title = body['title']?.toString().trim() ?? '';
      if (title.isEmpty) {
        return jsonResponse({'error': 'title ist erforderlich.'}, statusCode: 400);
      }
      final scheduledAt = body['scheduledAt'] == null
          ? null
          : DateTime.tryParse(body['scheduledAt'].toString());

      final created = await database.createEditorialArticle(
        title: title,
        summary: body['summary']?.toString() ?? '',
        body: body['body']?.toString() ?? '',
        category: body['category']?.toString().trim().isNotEmpty == true
            ? body['category'].toString().trim()
            : 'allgemein',
        imageUrl: body['imageUrl']?.toString(),
        authorEmployeeId: actor.id,
        homepageFeature: body['homepageFeature'] == true,
        breaking: body['breaking'] == true,
        sendPush: body['sendPush'] == true,
        scheduledAt: scheduledAt,
      );

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'news',
        objectType: 'article',
        objectId: created['id'].toString(),
        action: 'article.create',
        newValue: created,
        ip: _clientIp(request),
      );

      return jsonResponse({'article': _jsonSafe(created)}, statusCode: 201);
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 400);
    }
  }

  Future<Response> _editorialArticleDetail(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('news.view')) return _forbidden();

    try {
      final article = await database.editorialArticle(int.parse(id));
      if (article == null) {
        return jsonResponse({'error': 'Artikel nicht gefunden.'}, statusCode: 404);
      }
      return jsonResponse({'article': _jsonSafe(article)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _updateEditorialArticle(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('news.manage')) return _forbidden();

    const validStatuses = {'DRAFT', 'SCHEDULED', 'PUBLISHED', 'HIDDEN', 'ARCHIVED'};
    final articleId = int.parse(id);

    try {
      final before = await database.editorialArticle(articleId);
      if (before == null) {
        return jsonResponse({'error': 'Artikel nicht gefunden.'}, statusCode: 404);
      }

      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final status = body['status']?.toString();
      if (status != null && !validStatuses.contains(status)) {
        return jsonResponse({'error': 'Ungültiger status.'}, statusCode: 400);
      }

      final hasImageKey = body.containsKey('imageUrl');
      final hasScheduledKey = body.containsKey('scheduledAt');
      final sendPush = body['sendPush'] as bool?;

      final willPublishNow = status == 'PUBLISHED' && before['published_at'] == null;
      final shouldSendPush = willPublishNow &&
          (sendPush ?? before['send_push'] == true) &&
          before['push_sent_at'] == null;

      final updated = await database.updateEditorialArticle(
        id: articleId,
        title: body['title']?.toString(),
        summary: body['summary']?.toString(),
        body: body['body']?.toString(),
        category: body['category']?.toString(),
        imageUrl: hasImageKey ? body['imageUrl']?.toString() : PhoenixDatabase.unsetSentinel,
        status: status,
        homepageFeature: body['homepageFeature'] as bool?,
        breaking: body['breaking'] as bool?,
        sendPush: sendPush,
        scheduledAt: hasScheduledKey
            ? (body['scheduledAt'] == null ? null : DateTime.tryParse(body['scheduledAt'].toString()))
            : PhoenixDatabase.unsetSentinel,
        publishedAt: willPublishNow ? DateTime.now().toUtc() : null,
        pushSent: shouldSendPush,
      );
      if (updated == null) {
        return jsonResponse({'error': 'Artikel nicht gefunden.'}, statusCode: 404);
      }

      if (shouldSendPush) {
        unawaited(_broadcastNewsArticlePush(updated));
      }

      final diff = diffEmployeeFields(before: before, after: updated);
      if (diff.previousValue.isNotEmpty) {
        await database.insertAdminAuditLog(
          employeeId: actor.id,
          employeeLogin: actor.login,
          area: 'news',
          objectType: 'article',
          objectId: id,
          action: 'article.update',
          previousValue: diff.previousValue,
          newValue: diff.newValue,
          ip: _clientIp(request),
        );
      }

      return jsonResponse({'article': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<void> _broadcastNewsArticlePush(Map<String, Object?> article) async {
    final targets = await database.newsEnabledPushTargets();
    for (final target in targets) {
      try {
        await push.send(
          token: target['pushToken']!,
          title: 'PHÖNIX News',
          body: article['title'].toString(),
          androidChannelId: 'phoenix_news_v1',
          data: {'type': 'phoenix_editorial', 'articleId': article['id'].toString()},
        );
      } catch (error) {
        stderr.writeln('[PHOENIX EDITORIAL PUSH] ${target['installationId']}: $error');
      }
    }
  }

  // -- FAQ / Knowledge Base (Phase 5) --------------------------------------

  Future<Response> _listFaqArticles(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('faq.view')) return _forbidden();

    final query = request.url.queryParameters;
    try {
      final articles = await database.listFaqArticles(
        status: query['status'],
        category: query['category'],
      );
      return jsonResponse({'articles': articles.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _createFaqArticle(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('faq.manage')) return _forbidden();

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final title = body['title']?.toString().trim() ?? '';
      if (title.isEmpty) {
        return jsonResponse({'error': 'title ist erforderlich.'}, statusCode: 400);
      }
      final created = await database.createFaqArticle(
        title: title,
        body: body['body']?.toString() ?? '',
        category: body['category']?.toString().trim().isNotEmpty == true
            ? body['category'].toString().trim()
            : 'allgemein',
        position: int.tryParse(body['position']?.toString() ?? '') ?? 0,
        authorEmployeeId: actor.id,
      );
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'faq',
        objectType: 'article',
        objectId: created['id'].toString(),
        action: 'article.create',
        newValue: created,
        ip: _clientIp(request),
      );
      return jsonResponse({'article': _jsonSafe(created)}, statusCode: 201);
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 400);
    }
  }

  Future<Response> _updateFaqArticle(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('faq.manage')) return _forbidden();

    const validStatuses = {'DRAFT', 'PUBLISHED', 'ARCHIVED'};
    final articleId = int.parse(id);

    try {
      final before = await database.faqArticle(articleId);
      if (before == null) {
        return jsonResponse({'error': 'Artikel nicht gefunden.'}, statusCode: 404);
      }
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final status = body['status']?.toString();
      if (status != null && !validStatuses.contains(status)) {
        return jsonResponse({'error': 'Ungültiger status.'}, statusCode: 400);
      }

      final updated = await database.updateFaqArticle(
        id: articleId,
        title: body['title']?.toString(),
        body: body['body']?.toString(),
        category: body['category']?.toString(),
        position: int.tryParse(body['position']?.toString() ?? ''),
        status: status,
      );
      if (updated == null) {
        return jsonResponse({'error': 'Artikel nicht gefunden.'}, statusCode: 404);
      }

      final diff = diffEmployeeFields(before: before, after: updated);
      if (diff.previousValue.isNotEmpty) {
        await database.insertAdminAuditLog(
          employeeId: actor.id,
          employeeLogin: actor.login,
          area: 'faq',
          objectType: 'article',
          objectId: id,
          action: 'article.update',
          previousValue: diff.previousValue,
          newValue: diff.newValue,
          ip: _clientIp(request),
        );
      }
      return jsonResponse({'article': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Advertising (Phase 5) ------------------------------------------------

  Future<Response> _listAdCampaigns(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('advertising.view')) return _forbidden();

    final query = request.url.queryParameters;
    try {
      final campaigns = await database.listAdCampaigns(
        slot: query['slot'],
        active: query['active'] == null ? null : query['active'] == 'true',
      );
      return jsonResponse({'campaigns': campaigns.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _createAdCampaign(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('advertising.manage')) return _forbidden();

    const validSlots = {'home_banner', 'match_detail_infeed', 'news_infeed'};
    const validAudiences = {'ALL', 'FREE', 'PREMIUM'};

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final name = body['name']?.toString().trim() ?? '';
      final slot = body['slot']?.toString().trim() ?? '';
      final imageUrl = body['imageUrl']?.toString().trim() ?? '';
      final linkUrl = body['linkUrl']?.toString().trim() ?? '';
      if (name.isEmpty || imageUrl.isEmpty || linkUrl.isEmpty) {
        return jsonResponse({
          'error': 'name, imageUrl und linkUrl sind erforderlich.',
        }, statusCode: 400);
      }
      if (!validSlots.contains(slot)) {
        return jsonResponse({'error': 'Ungültiger slot.'}, statusCode: 400);
      }
      final targetAudience = body['targetAudience']?.toString() ?? 'ALL';
      if (!validAudiences.contains(targetAudience)) {
        return jsonResponse({'error': 'Ungültige targetAudience.'}, statusCode: 400);
      }

      final created = await database.createAdCampaign(
        name: name,
        slot: slot,
        imageUrl: imageUrl,
        linkUrl: linkUrl,
        active: body['active'] == null ? true : body['active'] == true,
        startDate: body['startDate'] == null ? null : DateTime.tryParse(body['startDate'].toString()),
        endDate: body['endDate'] == null ? null : DateTime.tryParse(body['endDate'].toString()),
        targetCountry: body['targetCountry']?.toString(),
        targetAudience: targetAudience,
        createdByEmployeeId: actor.id,
        budgetAmount: body['budgetAmount'] == null ? null : double.tryParse(body['budgetAmount'].toString()),
        frequencyCapPerDay: body['frequencyCapPerDay'] == null ? null : int.tryParse(body['frequencyCapPerDay'].toString()),
      );
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'advertising',
        objectType: 'campaign',
        objectId: created['id'].toString(),
        action: 'campaign.create',
        newValue: created,
        ip: _clientIp(request),
      );
      return jsonResponse({'campaign': _jsonSafe(created)}, statusCode: 201);
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 400);
    }
  }

  Future<Response> _adCampaignDetail(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('advertising.view')) return _forbidden();

    try {
      final campaign = await database.adCampaign(int.parse(id));
      if (campaign == null) {
        return jsonResponse({'error': 'Kampagne nicht gefunden.'}, statusCode: 404);
      }
      return jsonResponse({'campaign': _jsonSafe(campaign)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _updateAdCampaign(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('advertising.manage')) return _forbidden();

    final campaignId = int.parse(id);
    try {
      final before = await database.adCampaign(campaignId);
      if (before == null) {
        return jsonResponse({'error': 'Kampagne nicht gefunden.'}, statusCode: 404);
      }
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final hasStartKey = body.containsKey('startDate');
      final hasEndKey = body.containsKey('endDate');
      final hasCountryKey = body.containsKey('targetCountry');
      final hasBudgetKey = body.containsKey('budgetAmount');
      final hasFrequencyCapKey = body.containsKey('frequencyCapPerDay');

      final updated = await database.updateAdCampaign(
        id: campaignId,
        name: body['name']?.toString(),
        imageUrl: body['imageUrl']?.toString(),
        linkUrl: body['linkUrl']?.toString(),
        active: body['active'] as bool?,
        startDate: hasStartKey
            ? (body['startDate'] == null ? null : DateTime.tryParse(body['startDate'].toString()))
            : PhoenixDatabase.unsetSentinel,
        endDate: hasEndKey
            ? (body['endDate'] == null ? null : DateTime.tryParse(body['endDate'].toString()))
            : PhoenixDatabase.unsetSentinel,
        targetCountry: hasCountryKey ? body['targetCountry']?.toString() : PhoenixDatabase.unsetSentinel,
        targetAudience: body['targetAudience']?.toString(),
        budgetAmount: hasBudgetKey
            ? (body['budgetAmount'] == null ? null : double.tryParse(body['budgetAmount'].toString()))
            : PhoenixDatabase.unsetSentinel,
        frequencyCapPerDay: hasFrequencyCapKey
            ? (body['frequencyCapPerDay'] == null ? null : int.tryParse(body['frequencyCapPerDay'].toString()))
            : PhoenixDatabase.unsetSentinel,
      );
      if (updated == null) {
        return jsonResponse({'error': 'Kampagne nicht gefunden.'}, statusCode: 404);
      }

      final diff = diffEmployeeFields(before: before, after: updated);
      if (diff.previousValue.isNotEmpty) {
        await database.insertAdminAuditLog(
          employeeId: actor.id,
          employeeLogin: actor.login,
          area: 'advertising',
          objectType: 'campaign',
          objectId: id,
          action: 'campaign.update',
          previousValue: diff.previousValue,
          newValue: diff.newValue,
          ip: _clientIp(request),
        );
      }
      return jsonResponse({'campaign': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Push Center (Phase 5, Broadcast) -------------------------------------

  Future<Response> _listPushBroadcasts(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('push.manage')) return _forbidden();

    try {
      final broadcasts = await database.listPushBroadcasts();
      return jsonResponse({'broadcasts': broadcasts.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // Section 49: ein versendeter Push ist nicht rückgängig zu machen - deshalb
  // synchron gesendet (kein Entwurf/Vorschau-Zwischenschritt für "jetzt
  // senden"), damit die Response die tatsächlichen sent/failed-Zahlen trägt.
  Future<Response> _sendPushBroadcast(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('push.manage')) return _forbidden();

    if (!push.isConfigured) {
      return jsonResponse({
        'error': 'Push ist serverseitig nicht konfiguriert (FIREBASE_PROJECT_ID/FIREBASE_SERVICE_ACCOUNT_JSON fehlen).',
      }, statusCode: 503);
    }

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final title = body['title']?.toString().trim() ?? '';
      final message = body['body']?.toString().trim() ?? '';
      final targetType = body['targetType']?.toString() ?? 'all';
      final targetValue = body['targetValue']?.toString();
      final deepLinkRaw = body['deepLink']?.toString().trim();
      final deepLink = (deepLinkRaw == null || deepLinkRaw.isEmpty) ? null : deepLinkRaw;
      if (title.isEmpty || message.isEmpty) {
        return jsonResponse({'error': 'title und body sind erforderlich.'}, statusCode: 400);
      }
      if (!const {'all', 'league'}.contains(targetType)) {
        return jsonResponse({'error': 'targetType muss all oder league sein.'}, statusCode: 400);
      }
      if (targetType == 'league' && (targetValue == null || targetValue.isEmpty)) {
        return jsonResponse({'error': 'targetValue (Liga-ID) ist erforderlich.'}, statusCode: 400);
      }

      // Section 19 (AN2): "Zeitplanung" - ein zukünftiger Zeitpunkt
      // speichert den Broadcast nur, PushScheduleService versendet ihn
      // tatsächlich, sobald der Zeitpunkt erreicht ist.
      final scheduledAtRaw = body['scheduledAt']?.toString().trim();
      DateTime? scheduledAt;
      if (scheduledAtRaw != null && scheduledAtRaw.isNotEmpty) {
        scheduledAt = DateTime.tryParse(scheduledAtRaw);
        if (scheduledAt == null) {
          return jsonResponse({'error': 'scheduledAt ist kein gültiges Datum.'}, statusCode: 400);
        }
      }
      final isScheduled = scheduledAt != null && scheduledAt.isAfter(DateTime.now().toUtc());

      final broadcastId = await database.createPushBroadcast(
        title: title,
        body: message,
        targetType: targetType,
        targetValue: targetValue,
        sentByEmployeeId: actor.id,
        deepLinkUrl: deepLink,
        scheduledAt: isScheduled ? scheduledAt : null,
      );

      if (isScheduled) {
        await database.insertAdminAuditLog(
          employeeId: actor.id,
          employeeLogin: actor.login,
          area: 'push',
          objectType: 'broadcast',
          objectId: broadcastId.toString(),
          action: 'broadcast.schedule',
          newValue: {
            'title': title,
            'targetType': targetType,
            'targetValue': targetValue,
            'scheduledAt': scheduledAt.toIso8601String(),
          },
          ip: _clientIp(request),
        );
        return jsonResponse({
          'id': broadcastId,
          'scheduled': true,
          'scheduledAt': scheduledAt.toIso8601String(),
        }, statusCode: 201);
      }

      final targets = await database.broadcastPushTargets(
        targetType: targetType,
        targetValue: targetValue,
      );
      var sent = 0;
      var failed = 0;
      for (final target in targets) {
        try {
          await push.send(
            token: target['pushToken']!,
            title: title,
            body: message,
            androidChannelId: 'phoenix_news_v1',
            data: {
              'type': 'phoenix_broadcast',
              'broadcastId': broadcastId.toString(),
              if (deepLink != null) 'deepLink': deepLink,
            },
          );
          sent++;
        } catch (error) {
          failed++;
          stderr.writeln('[PHOENIX PUSH BROADCAST] ${target['installationId']}: $error');
        }
      }
      await database.updatePushBroadcastCounts(id: broadcastId, sentCount: sent, failedCount: failed);

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'push',
        objectType: 'broadcast',
        objectId: broadcastId.toString(),
        action: 'broadcast.send',
        newValue: {'title': title, 'targetType': targetType, 'targetValue': targetValue, 'sent': sent, 'failed': failed},
        ip: _clientIp(request),
      );

      return jsonResponse({
        'id': broadcastId,
        'targetCount': targets.length,
        'sent': sent,
        'failed': failed,
      }, statusCode: 201);
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // Section 19 (AN2): "Zielgruppen-Vorschau" - wie viele Geräte eine
  // Zielgruppe VOR dem Versand tatsächlich hat, ohne etwas zu senden.
  Future<Response> _pushTargetCount(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('push.manage')) return _forbidden();

    final targetType = request.url.queryParameters['targetType'] ?? 'all';
    final targetValue = request.url.queryParameters['targetValue'];
    if (!const {'all', 'league'}.contains(targetType)) {
      return jsonResponse({'error': 'targetType muss all oder league sein.'}, statusCode: 400);
    }
    if (targetType == 'league' && (targetValue == null || targetValue.isEmpty)) {
      return jsonResponse({'error': 'targetValue (Liga-ID) ist erforderlich.'}, statusCode: 400);
    }
    try {
      final targets = await database.broadcastPushTargets(
        targetType: targetType,
        targetValue: targetValue,
      );
      return jsonResponse({'count': targets.length});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // Section 19 (AN2): "Test-Push an Testgerät" - sendet direkt an EIN
  // bekanntes Gerät, ohne als Broadcast in der Historie zu erscheinen (ist
  // keine Kampagne, sondern ein Vorab-Check).
  Future<Response> _sendTestPush(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('push.manage')) return _forbidden();

    if (!push.isConfigured) {
      return jsonResponse({
        'error': 'Push ist serverseitig nicht konfiguriert (FIREBASE_PROJECT_ID/FIREBASE_SERVICE_ACCOUNT_JSON fehlen).',
      }, statusCode: 503);
    }

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final installationId = body['installationId']?.toString().trim() ?? '';
      final title = body['title']?.toString().trim() ?? '';
      final message = body['body']?.toString().trim() ?? '';
      if (installationId.isEmpty || title.isEmpty || message.isEmpty) {
        return jsonResponse({
          'error': 'installationId, title und body sind erforderlich.',
        }, statusCode: 400);
      }

      final token = await database.pushDeviceToken(installationId);
      if (token == null) {
        return jsonResponse({
          'error': 'Kein aktives Gerät mit dieser Installation-ID gefunden.',
        }, statusCode: 404);
      }

      final response = await push.send(
        token: token,
        title: title,
        body: message,
        androidChannelId: 'phoenix_news_v1',
        data: const {'type': 'phoenix_test'},
      );
      final ok = response.statusCode < 300;

      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'push',
        objectType: 'test',
        objectId: installationId,
        action: 'push.test',
        newValue: {'title': title, 'ok': ok},
        ip: _clientIp(request),
      );

      return jsonResponse({'sent': ok, 'providerStatus': response.statusCode});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Premium Feature Matrix (Phase 5) --------------------------------------

  Future<Response> _listPremiumFeaturesAdmin(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('premium.view')) return _forbidden();

    try {
      final features = await database.listPremiumFeatures();
      return jsonResponse({'features': features.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _updatePremiumFeature(Request request, String featureKey) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('premium.manage')) return _forbidden();

    const validTiers = {'FREE', 'PREMIUM', 'DISABLED'};
    try {
      final body = jsonDecode(await request.readAsString());
      final tier = body is Map ? body['tier']?.toString() ?? '' : '';
      if (!validTiers.contains(tier)) {
        return jsonResponse({'error': 'tier muss FREE, PREMIUM oder DISABLED sein.'}, statusCode: 400);
      }
      final updated = await database.updatePremiumFeatureTier(
        featureKey: featureKey,
        tier: tier,
        updatedBy: actor.login,
      );
      if (updated == null) {
        return jsonResponse({'error': 'Feature nicht gefunden.'}, statusCode: 404);
      }
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'premium',
        objectType: 'feature',
        objectId: featureKey,
        action: 'feature.tier_change',
        newValue: updated,
        ip: _clientIp(request),
      );
      return jsonResponse({'feature': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Feature Flags (Phase 6, deckt Section 42-44 ab) -----------------------

  Future<Response> _listFeatureFlags(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('featureFlags.view')) return _forbidden();

    try {
      final flags = await database.listFeatureFlags();
      return jsonResponse({'flags': flags.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _createFeatureFlag(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('featureFlags.manage')) return _forbidden();

    const validAudiences = {'ALL', 'FREE', 'PREMIUM', 'BETA', 'CUSTOM_SEGMENT'};
    const validStages = {'STAGING', 'PRODUCTION'};

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final flagKey = body['flagKey']?.toString().trim() ?? '';
      final label = body['label']?.toString().trim() ?? '';
      if (flagKey.isEmpty || label.isEmpty) {
        return jsonResponse({'error': 'flagKey und label sind erforderlich.'}, statusCode: 400);
      }
      final audience = body['audience']?.toString() ?? 'ALL';
      final stage = body['stage']?.toString() ?? 'STAGING';
      if (!validAudiences.contains(audience) || !validStages.contains(stage)) {
        return jsonResponse({'error': 'Ungültige audience oder stage.'}, statusCode: 400);
      }

      final created = await database.createFeatureFlag(
        flagKey: flagKey,
        label: label,
        description: body['description']?.toString() ?? '',
        enabled: body['enabled'] == true,
        rolloutPercentage: int.tryParse(body['rolloutPercentage']?.toString() ?? '') ?? 0,
        audience: audience,
        stage: stage,
        updatedBy: actor.login,
      );
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'featureFlags',
        objectType: 'flag',
        objectId: flagKey,
        action: 'flag.create',
        newValue: created,
        ip: _clientIp(request),
      );
      return jsonResponse({'flag': _jsonSafe(created)}, statusCode: 201);
    } catch (error) {
      final message = error.toString();
      if (message.toLowerCase().contains('duplicate key')) {
        return jsonResponse({'error': 'flagKey bereits vergeben.'}, statusCode: 409);
      }
      return jsonResponse({'error': message}, statusCode: 400);
    }
  }

  Future<Response> _updateFeatureFlag(Request request, String flagKey) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('featureFlags.manage')) return _forbidden();

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final updated = await database.updateFeatureFlag(
        flagKey: flagKey,
        enabled: body['enabled'] as bool?,
        rolloutPercentage: body['rolloutPercentage'] == null
            ? null
            : int.tryParse(body['rolloutPercentage'].toString()),
        audience: body['audience']?.toString(),
        stage: body['stage']?.toString(),
        updatedBy: actor.login,
      );
      if (updated == null) {
        return jsonResponse({'error': 'Feature Flag nicht gefunden.'}, statusCode: 404);
      }
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'featureFlags',
        objectType: 'flag',
        objectId: flagKey,
        action: 'flag.update',
        newValue: updated,
        ip: _clientIp(request),
      );
      return jsonResponse({'flag': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Release Center (Phase 6) ----------------------------------------------

  Future<Response> _getReleaseConfig(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('release.view')) return _forbidden();

    try {
      final config = await database.appReleaseConfig();
      return jsonResponse({'release': _jsonSafe(config)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _updateReleaseConfig(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('release.manage')) return _forbidden();

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final updated = await database.updateAppReleaseConfig(
        currentVersion: body['currentVersion']?.toString(),
        minimumSupportedVersion: body['minimumSupportedVersion']?.toString(),
        forcedUpdate: body['forcedUpdate'] as bool?,
        changelog: body['changelog']?.toString(),
        minimumOsAndroid: body['minimumOsAndroid']?.toString(),
        minimumOsIos: body['minimumOsIos']?.toString(),
        updatedBy: actor.login,
      );
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'release',
        objectType: 'config',
        objectId: '1',
        action: 'release.update',
        newValue: updated,
        ip: _clientIp(request),
      );
      return jsonResponse({'release': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Incidents (Phase 6) ----------------------------------------------------

  Future<Response> _listIncidents(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('incidents.view')) return _forbidden();

    try {
      final incidents = await database.listIncidents(status: request.url.queryParameters['status']);
      return jsonResponse({'incidents': incidents.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _createIncident(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('incidents.manage')) return _forbidden();

    const validSeverities = {'minor', 'major', 'critical'};
    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final title = body['title']?.toString().trim() ?? '';
      if (title.isEmpty) {
        return jsonResponse({'error': 'title ist erforderlich.'}, statusCode: 400);
      }
      final severity = body['severity']?.toString() ?? 'minor';
      if (!validSeverities.contains(severity)) {
        return jsonResponse({'error': 'Ungültige severity.'}, statusCode: 400);
      }
      final created = await database.createIncident(
        title: title,
        severity: severity,
        affectedSystems: body['affectedSystems']?.toString() ?? '',
        responsibleEmployeeId: int.tryParse(body['responsibleEmployeeId']?.toString() ?? ''),
        impactDescription: body['impactDescription']?.toString() ?? '',
        relatedJobsNote: body['relatedJobsNote']?.toString() ?? '',
        communicationNote: body['communicationNote']?.toString() ?? '',
      );
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'incidents',
        objectType: 'incident',
        objectId: created['id'].toString(),
        action: 'incident.create',
        newValue: created,
        ip: _clientIp(request),
      );
      return jsonResponse({'incident': _jsonSafe(created)}, statusCode: 201);
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 400);
    }
  }

  Future<Response> _incidentDetail(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('incidents.view')) return _forbidden();

    try {
      final incident = await database.incident(int.parse(id));
      if (incident == null) {
        return jsonResponse({'error': 'Incident nicht gefunden.'}, statusCode: 404);
      }
      return jsonResponse({'incident': _jsonSafe(incident)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _updateIncident(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('incidents.manage')) return _forbidden();

    const validStatuses = {'OPEN', 'MONITORING', 'RESOLVED'};
    final incidentId = int.parse(id);
    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final status = body['status']?.toString();
      if (status != null && !validStatuses.contains(status)) {
        return jsonResponse({'error': 'Ungültiger status.'}, statusCode: 400);
      }
      final updated = await database.updateIncident(
        id: incidentId,
        status: status,
        severity: body['severity']?.toString(),
        actionsTaken: body['actionsTaken']?.toString(),
        postmortem: body['postmortem']?.toString(),
        responsibleEmployeeId: int.tryParse(body['responsibleEmployeeId']?.toString() ?? ''),
        impactDescription: body['impactDescription']?.toString(),
        relatedJobsNote: body['relatedJobsNote']?.toString(),
        communicationNote: body['communicationNote']?.toString(),
        closeNow: status == 'RESOLVED',
      );
      if (updated == null) {
        return jsonResponse({'error': 'Incident nicht gefunden.'}, statusCode: 404);
      }
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'incidents',
        objectType: 'incident',
        objectId: id,
        action: 'incident.update',
        newValue: updated,
        ip: _clientIp(request),
      );
      return jsonResponse({'incident': _jsonSafe(updated)});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // Section 27 (AN2): "Timeline" - chronologische Einzeleinträge zu einem
  // Incident, zusätzlich zu Beginn/Ende/Maßnahmen/Postmortem.
  Future<Response> _listIncidentTimeline(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('incidents.view')) return _forbidden();

    try {
      final events = await database.listIncidentTimelineEvents(int.parse(id));
      return jsonResponse({'events': events.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _addIncidentTimelineEvent(Request request, String id) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('incidents.manage')) return _forbidden();

    try {
      final body = jsonDecode(await request.readAsString());
      if (body is! Map<String, dynamic>) {
        return jsonResponse({'error': 'Ungültiger JSON-Body.'}, statusCode: 400);
      }
      final note = body['note']?.toString().trim() ?? '';
      if (note.isEmpty) {
        return jsonResponse({'error': 'note ist erforderlich.'}, statusCode: 400);
      }
      final occurredAtRaw = body['occurredAt']?.toString();
      final event = await database.addIncidentTimelineEvent(
        incidentId: int.parse(id),
        note: note,
        occurredAt: (occurredAtRaw == null || occurredAtRaw.isEmpty) ? null : DateTime.tryParse(occurredAtRaw),
        createdByEmployeeId: actor.id,
      );
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'incidents',
        objectType: 'incident',
        objectId: id,
        action: 'incident.timeline_event',
        newValue: event,
        ip: _clientIp(request),
      );
      return jsonResponse({'event': _jsonSafe(event)}, statusCode: 201);
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 400);
    }
  }

  // -- Security (Phase 6) ------------------------------------------------------

  Future<Response> _listSessions(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('security.view')) return _forbidden();

    try {
      final sessions = await database.listActiveAdminSessions();
      return jsonResponse({'sessions': sessions.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // Section 32 (AN2): "Login-Verlauf" - auch abgelaufene/beendete Sessions,
  // nicht nur die aktuell aktiven.
  Future<Response> _sessionsHistory(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('security.view')) return _forbidden();

    try {
      final sessions = await database.listAdminSessionsHistory(limit: 100);
      return jsonResponse({'sessions': sessions.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _revokeSession(Request request, String token) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final actor = auth.employee!;
    if (!actor.hasPermission('security.manage')) return _forbidden();

    try {
      final revoked = await database.revokeAdminSessionByToken(token);
      if (!revoked) {
        return jsonResponse({'error': 'Session nicht gefunden oder bereits beendet.'}, statusCode: 404);
      }
      await database.insertAdminAuditLog(
        employeeId: actor.id,
        employeeLogin: actor.login,
        area: 'security',
        objectType: 'session',
        objectId: token,
        action: 'session.revoke',
        ip: _clientIp(request),
      );
      return jsonResponse({'status': 'revoked'});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _listFailedLogins(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('security.view')) return _forbidden();

    try {
      final attempts = await database.recentFailedLogins();
      return jsonResponse({'attempts': attempts.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- System Health (Phase 6) --------------------------------------------------

  Future<Response> _systemHealth(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('systemHealth.view')) return _forbidden();

    try {
      final apiUsage = await database.apiSportsDailyUsageToday();
      final pendingPipelineJobs = await database.countPendingFootballDailyPipelineJobs();
      final pendingSettlementJobs = await database.countPendingFootballMatchSettlementJobs();
      final appStatus = await database.appControlStatus();
      final dbStats = await database.databaseStats();
      final openTickets = await database.listSupportTickets(status: 'NEU');
      final openIncidents = await database.listIncidents(status: 'OPEN');

      // Section 28 (AN2): "Größenverlauf" - bei jedem Aufruf dieser Route
      // (Database- und System-Health-Seite) einen echten Snapshot
      // speichern. Darf einen bereits geladenen Health-Report niemals zum
      // Scheitern bringen, deshalb separat abgesichert.
      try {
        await database.recordDatabaseSizeSnapshot();
      } catch (_) {}
      final sizeHistory = await database.databaseSizeHistory(limit: 30);

      // Section 28 (AN2): "echte Ampel mit Ursachen" - EIN Gesamtstatus aus
      // denselben echten Signalen, die auch die einzelnen Kacheln zeigen,
      // mit einer Begründungsliste statt nur einer Farbe ohne Kontext.
      final ampelReasons = <String>[];
      var ampelStatus = 'green';
      void escalate(String status, String reason) {
        if (status == 'red' || (status == 'gold' && ampelStatus != 'red')) {
          ampelStatus = status;
        }
        ampelReasons.add(reason);
      }

      if (openIncidents.isNotEmpty) {
        escalate('red', '${openIncidents.length} offene(r) Incident(s)');
      }
      if (appStatus['status'] != 'ACTIVE') {
        escalate('gold', 'App-Status ist "${appStatus['status']}", nicht ACTIVE');
      }
      if (pendingPipelineJobs > 0) {
        escalate('gold', '$pendingPipelineJobs offene Daily-Pipeline-Läufe');
      }
      if (pendingSettlementJobs > 0) {
        escalate('gold', '$pendingSettlementJobs offene Settlement-Läufe');
      }
      for (final row in apiUsage) {
        final requests = ((row['requests'] as num?) ?? 0).toInt();
        final apiName = row['api_name']?.toString() ?? 'API';
        final limit = config.apiSportsDailyLimitFor(apiName);
        if (limit == null || limit <= 0) continue;
        final percent = (requests / limit) * 100;
        if (percent >= 95) {
          escalate('red', '$apiName: API-Budget bei ${percent.toStringAsFixed(0)}%');
        } else if (percent >= 85) {
          escalate('gold', '$apiName: API-Budget bei ${percent.toStringAsFixed(0)}%');
        }
      }
      final dbLimit = config.databaseSizeLimitMb;
      if (dbLimit != null && dbLimit > 0) {
        final sizeMb = ((dbStats['sizeBytes'] as num?) ?? 0) / (1024 * 1024);
        final dbPercent = (sizeMb / dbLimit) * 100;
        if (dbPercent >= 95) {
          escalate('red', 'Datenbankgröße bei ${dbPercent.toStringAsFixed(0)}% des konfigurierten Limits');
        } else if (dbPercent >= 85) {
          escalate('gold', 'Datenbankgröße bei ${dbPercent.toStringAsFixed(0)}% des konfigurierten Limits');
        }
      }

      return jsonResponse({
        'ampel': {
          'status': ampelStatus,
          'reasons': ampelReasons,
          'checkedAt': DateTime.now().toUtc().toIso8601String(),
        },
        'apiUsage': apiUsage.map((row) => _jsonSafe(_apiUsageRowWithLimit(row))).toList(),
        'pendingJobs': {
          'footballDailyPipeline': pendingPipelineJobs,
          'footballMatchSettlement': pendingSettlementJobs,
        },
        'appStatus': _jsonSafe(appStatus),
        'database': {
          ...(_jsonSafe(dbStats) as Map<String, Object?>),
          'sizeLimitMb': config.databaseSizeLimitMb,
          'sizeHistory': sizeHistory.map(_jsonSafe).toList(),
        },
        'openTicketCount': openTickets.length,
        'openIncidentCount': openIncidents.length,
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Rechte / Permissions catalog (Phase 6) ---------------------------------

  // Jede eingeloggte Person darf die RBAC-Struktur selbst einsehen (keine
  // sensiblen Daten, nur die Rollen-Standardmatrix) - kein eigenes Recht.
  Future<Response> _permissionsCatalog(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;

    return jsonResponse({
      'allPermissions': kAllPermissions.toList()..sort(),
      'roleDefaults': {
        for (final entry in kRoleDefaultPermissions.entries)
          entry.key: entry.value.toList()..sort(),
      },
      'roles': kValidRoles.toList()..sort(),
    });
  }

  // -- System Audit (Phase 6, Section 74-76 - bewusst reduzierter Umfang: ---
  // ein On-Demand-Report über echte, bereits vorhandene Kennzahlen statt
  // eines monatlich geplanten Jobs mit stabilen AUDIT-XXX-Fehlercodes. Keine
  // Kennzahl wird erfunden - jede Zeile stammt aus einer echten Abfrage.

  Future<Response> _systemAudit(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('systemHealth.view')) return _forbidden();

    try {
      final apiUsage = await database.apiSportsDailyUsageToday();
      final whitelistCounts = await database.footballLeagueManualStatusCounts();
      final champions = await database.allModelVersions(status: 'champion');
      final challengers = await database.allModelVersions(status: 'challenger');
      final pendingPipelineJobs = await database.countPendingFootballDailyPipelineJobs();
      final pendingSettlementJobs = await database.countPendingFootballMatchSettlementJobs();
      final openTickets = await database.listSupportTickets(status: 'NEU');
      final openIncidents = await database.listIncidents(status: 'OPEN');
      final appStatus = await database.appControlStatus();
      final dbStats = await database.databaseStats();

      final warnings = <String>[];
      final critical = <String>[];

      // Section 25 (AN2): früher wurde die rohe Anfragenzahl direkt gegen
      // 85/95 verglichen, als wäre sie bereits ein Prozentwert - ohne
      // bekanntes Tageslimit war das eine erfundene Schwelle. Jetzt: echter
      // Prozentsatz gegen das konfigurierte Limit, nur wenn eines gesetzt ist.
      for (final row in apiUsage) {
        final requests = ((row['requests'] as num?) ?? 0).toInt();
        final apiName = row['api_name']?.toString() ?? 'API';
        final limit = config.apiSportsDailyLimitFor(apiName);
        if (limit == null || limit <= 0) continue;
        final percent = (requests / limit) * 100;
        if (percent >= 95) {
          critical.add('$apiName: API-Budget bei ${percent.toStringAsFixed(0)}% ($requests von $limit).');
        } else if (percent >= 85) {
          warnings.add('$apiName: API-Budget bei ${percent.toStringAsFixed(0)}% ($requests von $limit).');
        }
      }
      if (pendingPipelineJobs > 0) warnings.add('$pendingPipelineJobs offene Daily-Pipeline-Läufe.');
      if (pendingSettlementJobs > 0) warnings.add('$pendingSettlementJobs offene Settlement-Läufe.');
      if (openTickets.isNotEmpty) warnings.add('${openTickets.length} neue, unbearbeitete Support-Tickets.');
      if (openIncidents.isNotEmpty) critical.add('${openIncidents.length} offene(r) Incident(s).');
      if (appStatus['status'] != 'ACTIVE') {
        warnings.add('App-Status ist "${appStatus['status']}", nicht ACTIVE.');
      }

      final sections = <String, List<String>>{
        'SETTLEMENT': [
          'Offene Daily-Pipeline-Läufe: $pendingPipelineJobs',
          'Offene Settlement-Läufe: $pendingSettlementJobs',
        ],
        'MODEL LAB': [
          'Aktive Champions: ${champions.length}',
          'Aktive Challenger: ${challengers.length}',
          'Model Promotion aktiviert: ${modelLabConfig.promotionEnabled}',
          'Generative AI Runtime: OFF (Section 56/97, hartkodiert deaktiviert)',
        ],
        'API': [for (final row in apiUsage) '${row['api_name']}: ${row['requests']} Requests heute'],
        'WHITELIST': [
          'Auto: ${whitelistCounts['auto'] ?? 0}',
          'Whitelist: ${whitelistCounts['whitelist'] ?? 0}',
          'Blacklist: ${whitelistCounts['blacklist'] ?? 0}',
        ],
        'SUPPORT / INCIDENTS': [
          'Neue Support-Tickets: ${openTickets.length}',
          'Offene Incidents: ${openIncidents.length}',
        ],
        'DATENBANK': [
          'Größe: ${((dbStats['sizeBytes'] as num?) ?? 0) ~/ (1024 * 1024)} MB',
        ],
      };

      final buffer = StringBuffer()
        ..writeln('PHÖNIX SYSTEM AUDIT')
        ..writeln('Datum: ${DateTime.now().toUtc().toIso8601String()}')
        ..writeln('Critical: ${critical.length}')
        ..writeln('Warnings: ${warnings.length}')
        ..writeln();
      for (final entry in sections.entries) {
        buffer.writeln(entry.key);
        for (final line in entry.value) {
          buffer.writeln('- $line');
        }
        buffer.writeln();
      }
      if (critical.isNotEmpty) {
        buffer.writeln('CRITICAL');
        for (final line in critical) {
          buffer.writeln('- $line');
        }
        buffer.writeln();
      }
      if (warnings.isNotEmpty) {
        buffer.writeln('WARNINGS');
        for (final line in warnings) {
          buffer.writeln('- $line');
        }
      }

      final reportText = buffer.toString();
      await database.saveSystemAuditRun(
        criticalCount: critical.length,
        warningCount: warnings.length,
        reportText: reportText,
      );

      return jsonResponse({
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'criticalCount': critical.length,
        'warningCount': warnings.length,
        'critical': critical,
        'warnings': warnings,
        'sections': sections,
        'reportText': reportText,
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  Future<Response> _systemAuditHistory(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('systemHealth.view')) return _forbidden();

    try {
      final runs = await database.listSystemAuditRuns();
      return jsonResponse({'runs': runs.map(_jsonSafe).toList()});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Search -----------------------------------------------------------

  Future<Response> _search(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    final employee = auth.employee!;
    if (!employee.hasPermission('search.view')) return _forbidden();

    final query = (request.url.queryParameters['q'] ?? '').trim();
    if (query.length < 2) {
      return jsonResponse({'query': query, 'count': 0, 'results': <Object?>[]});
    }

    try {
      final results = <Map<String, Object?>>[];

      for (final row in await database.searchFootballLeaguesByText(query, limit: 8)) {
        results.add({
          'type': 'footballLeague',
          'id': row['league_id'],
          'label': row['league_name'],
          'url': '/football/leagues/${row['league_id']}',
        });
      }
      for (final row in await database.searchFootballTeamsByText(query, limit: 8)) {
        results.add({
          'type': 'footballTeam',
          'id': row['team_id'],
          'label': row['team_name'],
          'url': '/football/teams/${row['team_id']}',
        });
      }
      for (final row in await database.searchFootballMatchesByText(query, limit: 8)) {
        results.add({
          'type': 'footballMatch',
          'id': row['id'],
          'label': '${row['home_team_name']} – ${row['away_team_name']} · ${row['league_name']}',
          'url': '/football/matches/${row['id']}',
        });
      }
      for (final row in await database.searchModelVersionsByText(query, limit: 8)) {
        results.add({
          'type': 'modelVersion',
          'id': row['id'],
          'label': '${row['readable_version']} (${_modelStatusLabel(row['status'])})',
          'url': '/model-lab/models/${row['id']}',
        });
      }
      for (final row in await database.searchLearningRunsByText(query, limit: 8)) {
        results.add({
          'type': 'learningRun',
          'id': row['id'],
          'label': 'Learning-Lauf #${row['id']} (${_runStatusLabel(row['status'])})',
          'url': '/model-lab/learning-runs/${row['id']}',
        });
      }
      for (final row in await database.searchNewsArticlesByText(query, limit: 8)) {
        results.add({
          'type': 'newsArticle',
          'id': row['id'],
          'label': row['title_de'],
          'url': '/news/${row['id']}',
        });
      }
      if (employee.hasPermission('employees.view')) {
        for (final row in await database.searchAdminEmployeesByText(query, limit: 8)) {
          results.add({
            'type': 'employee',
            'id': row['id'],
            'label': '${row['name']} (${row['login']})',
            'url': '/administration/employees/${row['id']}',
          });
        }
      }

      return jsonResponse({'query': query, 'count': results.length, 'results': results});
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- Helpers ------------------------------------------------------------

  Response _forbidden() =>
      jsonResponse({'error': 'Keine Berechtigung für diese Aktion.'}, statusCode: 403);

  Response _invalidCredentials() => jsonResponse(
        {'error': 'Login oder Passwort ist ungültig.'},
        statusCode: 401,
      );

  String _modelStatusLabel(Object? value) {
    switch (value?.toString()) {
      case 'champion':
        return 'Aktives Champion-Modell';
      case 'challenger':
        return 'Herausforderer-Modell';
      case 'retired':
        return 'Archiviert';
      default:
        return value?.toString() ?? 'Unbekannt';
    }
  }

  String _runStatusLabel(Object? value) {
    switch (value?.toString()) {
      case 'completed':
        return 'Fertig';
      case 'running':
        return 'Läuft';
      case 'failed':
        return 'Fehlgeschlagen';
      case 'pending':
        return 'Wartet';
      default:
        return value?.toString() ?? 'Unbekannt';
    }
  }

  String? _bearerToken(Request request) {
    final header = request.headers['authorization'] ?? '';
    if (!header.startsWith('Bearer ')) return null;
    final token = header.substring('Bearer '.length).trim();
    return token.isEmpty ? null : token;
  }

  String? _clientIp(Request request) {
    final forwardedFor = request.headers['x-forwarded-for'];
    if (forwardedFor != null && forwardedFor.trim().isNotEmpty) {
      return forwardedFor.split(',').first.trim();
    }
    final connectionInfo = request.context['shelf.io.connection_info'];
    if (connectionInfo is HttpConnectionInfo) {
      return connectionInfo.remoteAddress.address;
    }
    return null;
  }

  ({Map<String, Object?> overrides, String? error}) _extractPermissionOverrides(
    Object? raw,
  ) {
    if (raw == null) return (overrides: <String, Object?>{}, error: null);
    if (raw is! Map) {
      return (overrides: <String, Object?>{}, error: 'permissionOverrides muss ein Objekt sein.');
    }
    final overrides = <String, Object?>{};
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      if (!kAllPermissions.contains(key)) {
        return (
          overrides: <String, Object?>{},
          error: 'Unbekannter permissionOverrides-Key: $key',
        );
      }
      if (entry.value is! bool) {
        return (
          overrides: <String, Object?>{},
          error: 'permissionOverrides.$key muss ein Boolean sein.',
        );
      }
      overrides[key] = entry.value;
    }
    return (overrides: overrides, error: null);
  }

  Object? _jsonSafe(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), _jsonSafe(item)));
    }
    if (value is Iterable) return value.map(_jsonSafe).toList();
    return value.toString();
  }

  // Section 25 (AN2): gemeinsame Anreicherung um das konfigurierte
  // Tageslimit, überall wo api_sports_daily_usage-Zeilen ausgegeben werden
  // (Overview, System Health, API Usage) - eine einzige Quelle, damit sich
  // die drei Stellen nie widersprechen können.
  Map<String, Object?> _apiUsageRowWithLimit(Map<String, Object?> row) {
    final apiName = row['api_name']?.toString() ?? '';
    return {
      ...row,
      'daily_limit': config.apiSportsDailyLimitFor(apiName),
    };
  }

  // Identische Logik zu RoutesRegistrar._berlinNow() in routes.dart (dort
  // privat, deshalb hier dupliziert statt geteilt) - wichtig, damit
  // "heute" im Overview exakt denselben Berliner Kalendertag meint wie
  // /api/football/analyses/today, das die App verwendet.
  DateTime _berlinNow() {
    final utc = DateTime.now().toUtc();
    final marchSwitch = _lastSundayUtc(utc.year, DateTime.march);
    final octoberSwitch = _lastSundayUtc(utc.year, DateTime.october);
    final summerTime =
        !utc.isBefore(marchSwitch) && utc.isBefore(octoberSwitch);
    return utc.add(Duration(hours: summerTime ? 2 : 1));
  }

  DateTime _lastSundayUtc(int year, int month) {
    final lastDay = DateTime.utc(year, month + 1, 0);
    final sunday = lastDay.subtract(Duration(days: lastDay.weekday % 7));
    return DateTime.utc(year, month, sunday.day, 1);
  }
}
