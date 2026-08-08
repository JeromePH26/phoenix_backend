import 'dart:convert';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

class FirebasePushService {
  FirebasePushService({
    required this.projectId,
    required this.serviceAccountJson,
  });

  final String projectId;
  final String serviceAccountJson;
  AutoRefreshingAuthClient? _client;

  bool get isConfigured =>
      projectId.isNotEmpty && serviceAccountJson.isNotEmpty;

  Future<http.Response> send({
    required String token,
    required String title,
    required String body,
    required Map<String, String> data,
    required String androidChannelId,
  }) async {
    if (!isConfigured)
      throw StateError('Firebase Push ist nicht konfiguriert.');
    final client = await _authorizedClient();
    return client.post(
      Uri.parse(
          'https://fcm.googleapis.com/v1/projects/$projectId/messages:send'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'message': {
          'token': token,
          'notification': {'title': title, 'body': body},
          'data': data,
          'android': {
            'priority': 'high',
            'notification': {'channel_id': androidChannelId},
          },
          'apns': {
            'payload': {
              'aps': {'sound': 'default', 'content-available': 1},
            },
          },
        },
      }),
    );
  }

  Future<AutoRefreshingAuthClient> _authorizedClient() async {
    final current = _client;
    if (current != null) return current;
    final credentials = ServiceAccountCredentials.fromJson(
      jsonDecode(serviceAccountJson) as Map<String, dynamic>,
    );
    return _client = await clientViaServiceAccount(
      credentials,
      const ['https://www.googleapis.com/auth/firebase.messaging'],
    );
  }

  void close() => _client?.close();
}
