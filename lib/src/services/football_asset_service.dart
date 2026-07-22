import 'dart:typed_data';

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

  static const maximumBytes = 3145728;

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

    // Bereits gespeicherte Bilder können weiterhin aus der Datenbank gelesen
    // werden. Das Speichern neuer Bilder ist vorübergehend deaktiviert, weil
    // PhoenixDatabase aktuell keine saveFootballAsset-Methode bereitstellt.
    final cached = await database.footballAsset(
      entityType: normalizedType,
      entityId: normalizedId,
    );
    final cachedBytes = cached?['image_bytes'];
    if (cachedBytes is Uint8List && cachedBytes.isNotEmpty) {
      return _response(
        cachedBytes,
        cached?['mime_type']?.toString() ?? 'image/png',
      );
    }

    final source = sourceUrl?.trim() ?? '';
    final uri = Uri.tryParse(source);
    if (source.isEmpty ||
        uri == null ||
        uri.scheme != 'https' ||
        !_allowedHost(uri.host)) {
      return Response.badRequest(body: 'Bildquelle ist nicht freigegeben.');
    }

    final response = await _client
        .get(uri, headers: const {'accept': 'image/*'})
        .timeout(const Duration(seconds: 20));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return Response(
        response.statusCode,
        body: 'Bildquelle nicht erreichbar.',
      );
    }

    final bytes = response.bodyBytes;
    final mime = _mime(response.headers['content-type'], uri.path);
    if (bytes.isEmpty ||
        bytes.length > maximumBytes ||
        !mime.startsWith('image/')) {
      return Response.badRequest(body: 'Ungültige oder zu große Bilddatei.');
    }

    // Kein Datenbank-Write: verhindert den aktuellen Compilerfehler.
    return _response(bytes, mime);
  }

  Response _response(Uint8List bytes, String mime) => Response.ok(
        bytes,
        headers: {
          'content-type': mime,
          'cache-control': 'public, max-age=2592000, immutable',
          'content-length': '${bytes.length}',
        },
      );

  bool _allowedHost(String host) {
    final value = host.toLowerCase();
    return value == 'media.api-sports.io' ||
        value.endsWith('.api-sports.io') ||
        value == 'api-sports.io';
  }

  String _mime(String? header, String path) {
    final value = header?.split(';').first.trim().toLowerCase();
    if (value != null && value.startsWith('image/')) return value;

    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.jpg') || lowerPath.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lowerPath.endsWith('.webp')) return 'image/webp';
    if (lowerPath.endsWith('.svg')) return 'image/svg+xml';
    return 'image/png';
  }

  void close() => _client.close();
}
