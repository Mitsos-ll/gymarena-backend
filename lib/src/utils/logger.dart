import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

/// Initialise le logger global et branche les records sur stdout en JSON.
void setupLogger({bool verbose = false}) {
  Logger.root.level = verbose ? Level.ALL : Level.INFO;
  Logger.root.onRecord.listen(_writeRecord);
}

void _writeRecord(LogRecord record) {
  final entry = <String, dynamic>{
    'ts': record.time.toUtc().toIso8601String(),
    'level': record.level.name,
    'logger': record.loggerName,
    'msg': record.message,
  };
  // L'API logging place le 2e arg dans record.error — on l'étale si c'est une Map de contexte
  final err = record.error;
  if (err is Map<String, dynamic>) {
    entry.addAll(err);
  } else if (err != null) {
    entry['error'] = err.toString();
  }
  if (record.stackTrace != null) entry['stack'] = record.stackTrace.toString();
  stdout.writeln(jsonEncode(entry));
}

/// Logger de l'application principal.
final log = Logger('gymtrack');

/// Helpers raccourcis avec champ `extra` optionnel pour contexte métier.
void logInfo(String msg, {String? requestId, Map<String, dynamic>? extra}) =>
    log.info(
      msg,
      <String, dynamic>{
        if (requestId != null) 'req_id': requestId,
        ...?extra,
      },
    );

void logWarn(String msg, {String? requestId, Object? error}) =>
    log.warning(
      msg,
      <String, dynamic>{
        if (requestId != null) 'req_id': requestId,
        if (error != null) 'error': error.toString(),
      },
    );

void logError(String msg, Object error, StackTrace? stack, {String? requestId}) =>
    log.severe(
      msg,
      <String, dynamic>{
        if (requestId != null) 'req_id': requestId,
      },
      stack,
    );
