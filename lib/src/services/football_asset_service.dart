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

    final source = sourceUrl?.trim() ?? '';
    final uri = Uri.tryParse(source);
    if (uri == null ||
        uri.scheme != 'https' ||
        !_isAllowedHost(uri.host)) {
      return Response.badRequest(body: 'Bildquelle ist nicht freigegeben.');
    }

    final upstream = await _client
        .get(uri, headers: const {'accept': 'image/*'})
        .timeout(const Duration(seconds: 20));

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

    // PhoenixDatabase besitzt aktuell keine Methoden zum Lesen oder Speichern
    // von Football-Assets. Das Bild wird deshalb direkt ausgeliefert.
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
    if (normalizedPath.endsWith('.jpg') ||
        normalizedPath.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (normalizedPath.endsWith('.webp')) return 'image/webp';
    if (normalizedPath.endsWith('.svg')) return 'image/svg+xml';
    return 'image/png';
  }

  void close() => _client.close();
}
