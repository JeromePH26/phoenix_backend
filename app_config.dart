import 'dart:io';

import 'package:phoenix_backend/src/app.dart';

Future<void> main() async {
  final app = await PhoenixBackend.create();
  final server = await app.serve();

  stdout.writeln(
    'PHOENIX backend listening on ${server.address.host}:${server.port}',
  );
}
