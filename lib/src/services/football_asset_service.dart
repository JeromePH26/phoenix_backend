import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

import '../database/database.dart';

class FootballAssetService {
  FootballAssetService({
    required this.database,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final PhoenixDatabase database;
  final http.Client _client;

  static const allowedTypes = {
    'team',
    'league',
    'player',
    'coach',
    'venue',
  };

  static const maximumBytes = 3 * 1024 * 1024;

  Future<Response> serve({
    required String type,
    required String id,
    String? sourceUrl,
  }) async {
    final normalizedType = type.trim().toLowerCase();
    final normalizedId = id.trim();

    if (!allowedTypes.contains(normalizedType) || normalizedId.isEmpty) {
      return Response.badRequest(body: 'Ungültige Bild-ID.');
    }

    // Die Anzeige eines Wappens darf nicht ausfallen, nur weil die Cache-Tabelle
    // während eines Deployments noch nicht migriert wurde. In diesem seltenen
    // Fall liefern wir das geprüfte Original aus und versuchen beim nächsten
    // Abruf erneut, es persistent zu speichern.
    Map<String, Object?>? cached;
    try {
      cached = await database.footballAsset(
        type: normalizedType,
        id: normalizedId,
      );
    } catch (_) {
      cached = null;
    }
    if (cached != null) {
      final encoded = cached['content_base64']?.toString() ?? '';
      final mimeType = cached['mime_type']?.toString() ?? '';
      if (encoded.isNotEmpty && mimeType.startsWith('image/')) {
        return _imageResponse(base64Decode(encoded), mimeType);
      }
    }

    final source = sourceUrl?.trim() ?? '';
    final uri = Uri.tryParse(source);
    if (uri == null || uri.scheme != 'https' || !_isAllowedHost(uri.host)) {
      return Response.badRequest(body: 'Bildquelle ist nicht freigegeben.');
    }

    final upstream = await _client.get(uri, headers: const {
      'accept': 'image/*'
    }).timeout(const Duration(seconds: 20));

    if (upstream.statusCode < 200 || upstream.statusCode >= 300) {
      return Response(
        upstream.statusCode,
        body: 'Bildquelle nicht erreichbar.',
      );
    }

    final bytes = upstream.bodyBytes;
    final mimeType = _mimeType(upstream.headers['content-type'], uri.path);
    if (bytes.isEmpty ||
        bytes.length > maximumBytes ||
        !mimeType.startsWith('image/')) {
      return Response.badRequest(body: 'Ungültige oder zu große Bilddatei.');
    }

    try {
      await database.saveFootballAsset(
        type: normalizedType,
        id: normalizedId,
        sourceUrl: source,
        mimeType: mimeType,
        bytes: bytes,
      );
    } catch (_) {
      // Das Bild ist valide und kann angezeigt werden. Der persistente Cache
      // wird nach einer erfolgreichen Migration automatisch nachgefüllt.
    }
    return _imageResponse(bytes, mimeType);
  }

  Response _imageResponse(List<int> bytes, String mimeType) {
    return Response.ok(
      bytes,
      headers: {
        'content-type': mimeType,
        'cache-control': 'public, max-age=2592000, immutable',
        'content-length': '${bytes.length}',
      },
    );
  }

  bool _isAllowedHost(String host) {
    final normalizedHost = host.toLowerCase();
    return normalizedHost == 'media.api-sports.io' ||
        normalizedHost == 'api-sports.io' ||
        normalizedHost.endsWith('.api-sports.io');
  }

  String _mimeType(String? header, String path) {
    final headerMimeType = header?.split(';').first.trim().toLowerCase();
    if (headerMimeType != null && headerMimeType.startsWith('image/')) {
      return headerMimeType;
    }

    final normalizedPath = path.toLowerCase();
    if (normalizedPath.endsWith('.jpg') || normalizedPath.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (normalizedPath.endsWith('.webp')) return 'image/webp';
    if (normalizedPath.endsWith('.svg')) return 'image/svg+xml';
    return 'image/png';
  }

  void close() => _client.close();
}
