import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;

import '../lib/src/app.dart';
import '../lib/src/config.dart';

Future<void> main(List<String> args) async {
  final config = AppConfig.fromEnvironment();
  final backend = GymTrackBackend(config);

  final server = await shelf_io.serve(
    backend.handler,
    '0.0.0.0',
    config.port,
  );

  stdout.writeln('GymTrack backend running on http://${server.address.host}:${server.port}');
  stdout.writeln('Health check: http://${server.address.host}:${server.port}/health');

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nShutting down...');
    await backend.close();
    await server.close(force: true);
    exit(0);
  });
}
