import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;

import '../lib/src/app.dart';
import '../lib/src/config.dart';
import '../lib/src/utils/logger.dart';

Future<void> main(List<String> args) async {
  final config = AppConfig.fromEnvironment();
  setupLogger(verbose: !config.isProduction);

  logInfo('Starting GymTrack backend', extra: {'env': config.env, 'port': config.port});

  final backend = GymTrackBackend(config);

  final server = await shelf_io.serve(
    backend.handler,
    '0.0.0.0',
    config.port,
  );

  server.autoCompress = true;

  logInfo('Server ready', extra: {
    'address': server.address.host,
    'port': server.port,
    'health': 'http://${server.address.host}:${server.port}/health',
  });

  Future<void> shutdown() async {
    logInfo('Shutting down...');
    await backend.close();
    await server.close(force: true);
  }

  ProcessSignal.sigint.watch().listen((_) async {
    await shutdown();
    exit(0);
  });

  // SIGTERM for Docker / Kubernetes graceful stop
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await shutdown();
      exit(0);
    });
  }
}
