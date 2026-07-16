import 'dart:convert';

import 'package:shelf/shelf.dart';

Response jsonResponse(
  Object? body, {
  int statusCode = 200,
  Map<String, String>? headers,
}) {
  return Response(
    statusCode,
    body: jsonEncode(body),
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      ...?headers,
    },
  );
}
