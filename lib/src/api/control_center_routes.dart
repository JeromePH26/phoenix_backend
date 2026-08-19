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
import '../http/json_response.dart';
import '../model_lab/learning_dataset_builder.dart';

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
  }) : guard = ControlCenterAuthGuard(database: database);

  final AppConfig config;
  final ModelLabConfig modelLabConfig;
  final PhoenixDatabase database;
  final ControlCenterAuthGuard guard;

  Router get router {
    final router = Router();

    router.post('/auth/login', _login);
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
    router.get('/devices', _listDevices);
    router.get('/devices/<installationId>', _deviceDetail);
    router.get('/support/assignable-employees', _assignableEmployees);
    router.get('/support/tickets', _listSupportTickets);
    router.get('/support/tickets/<id|[0-9]+>', _supportTicketDetail);
    router.patch('/support/tickets/<id|[0-9]+>', _updateSupportTicket);
    router.post('/support/tickets/<id|[0-9]+>/reply', _replySupportTicket);

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

      final row = await database.adminEmployeeByLogin(login);
      if (row == null) return _invalidCredentials();

      final passwordHash = row['password_hash']?.toString() ?? '';
      final employee = Employee.fromRow(row);
      final passwordOk =
          passwordHash.isNotEmpty && BCrypt.checkpw(password, passwordHash);
      if (!passwordOk || !employee.isActive) return _invalidCredentials();

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

  // -- Audit log ----------------------------------------------------------

  Future<Response> _auditLog(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('audit.view')) return _forbidden();

    final params = request.url.queryParameters;
    final area = params['area'];
    final employeeIdParam = params['employeeId'];
    final employeeId = employeeIdParam == null ? null : int.tryParse(employeeIdParam);
    final limit = int.tryParse(params['limit'] ?? '') ?? 100;

    try {
      final entries = await database.listAdminAuditLog(
        area: area,
        employeeId: employeeId,
        limit: limit,
      );
      return jsonResponse({
        'count': entries.length,
        'entries': entries.map(_jsonSafe).toList(),
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

      final pendingPipelineJobs = await database.countPendingFootballDailyPipelineJobs();
      final pendingSettlementJobs = await database.countPendingFootballMatchSettlementJobs();

      return jsonResponse({
        'apiUsage': apiUsage.map(_jsonSafe).toList(),
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
        'pendingJobs': {
          'footballDailyPipeline': pendingPipelineJobs,
          'footballMatchSettlement': pendingSettlementJobs,
        },
      });
    } catch (error) {
      return jsonResponse({'error': error.toString()}, statusCode: 500);
    }
  }

  // -- API Usage --------------------------------------------------------

  Future<Response> _apiUsage(Request request) async {
    final auth = await guard.authenticate(request);
    if (!auth.isAuthenticated) return auth.unauthorizedResponse!;
    if (!auth.employee!.hasPermission('apiUsage.view')) return _forbidden();

    try {
      final today = await database.apiSportsDailyUsageToday();
      final history = await database.apiSportsDailyUsageHistory(days: 14);
      return jsonResponse({
        'today': today.map(_jsonSafe).toList(),
        'history': history.map(_jsonSafe).toList(),
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

      const validStatuses = {'ACTIVE', 'MAINTENANCE', 'DISABLED'};
      if (!validStatuses.contains(status)) {
        return jsonResponse({
          'error': 'status muss ACTIVE, MAINTENANCE oder DISABLED sein.',
        }, statusCode: 400);
      }
      if (reason.isEmpty) {
        return jsonResponse({'error': 'reason ist erforderlich.'}, statusCode: 400);
      }

      final previous = await database.appControlStatus();
      final updated = await database.setAppControlStatus(
        status: status,
        message: (message?.isEmpty ?? true) ? null : message,
        updatedBy: actor.login,
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

      for (final row in await database.searchFootballLeaguesByText(query)) {
        results.add({
          'type': 'footballLeague',
          'id': row['league_id'],
          'label': row['league_name'],
          'url': '/football/leagues/${row['league_id']}',
        });
      }
      for (final row in await database.searchModelVersionsByText(query)) {
        results.add({
          'type': 'modelVersion',
          'id': row['id'],
          'label': '${row['readable_version']} (${row['status']})',
          'url': '/model-lab/models/${row['id']}',
        });
      }
      for (final row in await database.searchLearningRunsByText(query)) {
        results.add({
          'type': 'learningRun',
          'id': row['id'],
          'label': 'Learning Run #${row['id']} (${row['status']})',
          'url': '/model-lab/learning-runs/${row['id']}',
        });
      }
      for (final row in await database.searchNewsArticlesByText(query)) {
        results.add({
          'type': 'newsArticle',
          'id': row['id'],
          'label': row['title_de'],
          'url': '/news/${row['id']}',
        });
      }
      if (employee.hasPermission('employees.view')) {
        for (final row in await database.searchAdminEmployeesByText(query)) {
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
}
