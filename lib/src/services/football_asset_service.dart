import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import '../database/database.dart';

class FootballAssetService {
  FootballAssetService({required this.database, http.Client? client}) : _client = client ?? http.Client();
  final PhoenixDatabase database;
  final http.Client _client;
  static const allowedTypes = {'team','league','player','coach','venue'};
  static const maximumBytes = 3145728;

  Future<Response> serve({required String type, required String id, String? sourceUrl}) async {
    final t=type.trim().toLowerCase(); final i=id.trim();
    if(!allowedTypes.contains(t)||i.isEmpty) return Response.badRequest(body:'Ungültige Bild-ID.');
    final cached=await database.footballAsset(entityType:t,entityId:i);
    final cachedBytes=cached?['image_bytes'];
    if(cachedBytes is Uint8List && cachedBytes.isNotEmpty){
      return _response(cachedBytes,cached?['mime_type']?.toString()??'image/png');
    }
    final source=sourceUrl?.trim()??'';
    final uri=Uri.tryParse(source);
    if(source.isEmpty||uri==null||uri.scheme!='https'||!_allowedHost(uri.host)) return Response.badRequest(body:'Bildquelle ist nicht freigegeben.');
    final response=await _client.get(uri,headers:const {'accept':'image/*'}).timeout(const Duration(seconds:20));
    if(response.statusCode<200||response.statusCode>=300) return Response(response.statusCode,body:'Bildquelle nicht erreichbar.');
    final bytes=response.bodyBytes; final mime=_mime(response.headers['content-type'],uri.path);
    if(bytes.isEmpty||bytes.length>maximumBytes||!mime.startsWith('image/')) return Response.badRequest(body:'Ungültige oder zu große Bilddatei.');
    await database.saveFootballAsset(entityType:t,entityId:i,sourceUrl:source,mimeType:mime,imageBytes:bytes);
    return _response(bytes,mime);
  }
  Response _response(Uint8List bytes,String mime)=>Response.ok(bytes,headers:{'content-type':mime,'cache-control':'public, max-age=2592000, immutable','content-length':'${bytes.length}'});
  bool _allowedHost(String host){final h=host.toLowerCase();return h=='media.api-sports.io'||h.endsWith('.api-sports.io')||h=='api-sports.io';}
  String _mime(String? header,String path){final h=header?.split(';').first.trim().toLowerCase();if(h!=null&&h.startsWith('image/'))return h;final p=path.toLowerCase();if(p.endsWith('.jpg')||p.endsWith('.jpeg'))return'image/jpeg';if(p.endsWith('.webp'))return'image/webp';if(p.endsWith('.svg'))return'image/svg+xml';return'image/png';}
  void close()=>_client.close();
}
