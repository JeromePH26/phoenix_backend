import 'dart:convert';

import 'permissions.dart';

/// PHÖNIX CONTROL CENTER: In-Memory-Repräsentation einer Zeile aus
/// `admin_employees`. Enthält bewusst niemals `password_hash` - siehe
/// [Employee.fromRow], das die Spalte, falls in der Row vorhanden, verwirft.
class Employee {
  Employee({
    required this.id,
    required this.name,
    required this.login,
    required this.email,
    required this.role,
    required this.permissionOverrides,
    required this.department,
    required this.status,
    required this.createdAt,
    required this.lastLoginAt,
  });

  final int id;
  final String name;
  final String login;
  final String email;
  final String role;
  final Map<String, Object?> permissionOverrides;
  final String? department;
  final String status;
  final DateTime createdAt;
  final DateTime? lastLoginAt;

  bool get isActive => status == 'active';
  bool get isOwner => role == 'OWNER';

  bool hasPermission(String permission) => hasPermissionForRole(
        role: role,
        permission: permission,
        overrides: permissionOverrides,
      );

  factory Employee.fromRow(Map<String, Object?> row) {
    return Employee(
      id: row['id'] as int,
      name: row['name']?.toString() ?? '',
      login: row['login']?.toString() ?? '',
      email: row['email']?.toString() ?? '',
      role: row['role']?.toString() ?? '',
      permissionOverrides: _jsonMap(row['permission_overrides']),
      department: row['department']?.toString(),
      status: row['status']?.toString() ?? 'active',
      createdAt: _asDateTime(row['created_at']) ?? DateTime.now().toUtc(),
      lastLoginAt: _asDateTime(row['last_login_at']),
    );
  }

  /// Öffentliche JSON-Darstellung für API-Antworten - niemals
  /// `password_hash`, siehe Section "Quality bar" der Aufgabenstellung.
  Map<String, Object?> toPublicJson() => {
        'id': id,
        'name': name,
        'login': login,
        'email': email,
        'role': role,
        'permissionOverrides': permissionOverrides,
        'department': department,
        'status': status,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'lastLoginAt': lastLoginAt?.toUtc().toIso8601String(),
      };

  static DateTime? _asDateTime(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }

  static Map<String, Object?> _jsonMap(Object? value) {
    if (value is Map) return Map<String, Object?>.from(value);
    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    }
    return <String, Object?>{};
  }
}
