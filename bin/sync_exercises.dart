import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../lib/src/config.dart';
import '../lib/src/db/app_database.dart';
import '../lib/src/repositories/exercise_catalog_repository.dart';
import '../lib/src/services/gif_cache_service.dart';
import '../lib/src/services/workoutx_service.dart';
import '../lib/src/utils/logger.dart';

/// Synchronise le catalogue d'exercices par défaut avec WorkoutX : télécharge
/// les GIFs pour chaque (slug -> workoutx_id) de seed/exercise_gif_mapping.json
/// et les insère dans exercise_catalog. Idempotent : ne re-télécharge pas un
/// GIF déjà en cache. Respecte le rate-limit WorkoutX (30 req/60s) par une
/// pause entre les lots.
///
/// Usage: dart run bin/sync_exercises.dart
Future<void> main() async {
  final config = AppConfig.fromEnvironment();
  setupLogger(verbose: true);

  final mappingFile = File('seed/exercise_gif_mapping.json');
  final mapping = jsonDecode(await mappingFile.readAsString()) as Map<String, dynamic>;

  final database = AppDatabase.open(config.databasePath);
  final repository = ExerciseCatalogRepository(database: database);
  final workoutX = WorkoutXService(
    apiKey: config.workoutXApiKey,
    baseUrl: config.workoutXBaseUrl,
  );
  final gifCache = GifCacheService(
    cacheDir: Directory(p.join(p.dirname(config.databasePath), 'exercise_gifs')),
    workoutX: workoutX,
  )..ensureCacheDir();

  final entries = mapping.entries.toList();
  final total = entries.length;
  var synced = 0;
  var skipped = 0;
  final errors = <String>[];
  final stopwatch = Stopwatch()..start();

  // Chaque exercice coûte 2 requêtes WorkoutX (métadonnées + GIF) — la limite
  // constatée est 30 req/60s, donc on pause tous les 14 exercices (28 req).
  const batchSize = 14;
  const batchPause = Duration(seconds: 65);

  for (var i = 0; i < entries.length; i++) {
    final slug = entries[i].key;
    final workoutXId = entries[i].value as String;

    if (gifCache.getLocalGifFile(slug) != null) {
      skipped++;
      _printProgress(i + 1, total, synced, skipped, errors.length);
      continue;
    }

    try {
      final exercise = await workoutX.getExerciseById(workoutXId);
      final fileName = await gifCache.downloadAndCacheGif(slug, exercise.gifUrl);
      repository.upsert(
        slug: slug,
        workoutXId: exercise.id,
        name: exercise.name,
        targetMuscles: [exercise.target],
        secondaryMuscles: exercise.secondaryMuscles,
        equipment: exercise.equipment,
        difficulty: exercise.difficulty,
        instructions: exercise.instructions,
        gifPath: fileName,
        cachedAt: dbNow(),
      );
      synced++;
    } catch (e) {
      errors.add('$slug ($workoutXId): $e');
      logError('Sync failed for $slug', e, null);
    }

    _printProgress(i + 1, total, synced, skipped, errors.length);

    if ((i + 1) % batchSize == 0 && i + 1 < entries.length) {
      stdout.writeln('\nPause ${batchPause.inSeconds}s (rate-limit WorkoutX)...');
      await Future.delayed(batchPause);
    }
  }

  stopwatch.stop();
  stdout.writeln();
  stdout.writeln('✓ Sync terminé en ${_formatDuration(stopwatch.elapsed)}'
      ' — $synced téléchargés, $skipped déjà en cache, ${errors.length} échecs'
      ' (catalogue total: ${repository.count()})');

  if (errors.isNotEmpty) {
    stdout.writeln('\nÉchecs :');
    for (final e in errors) {
      stdout.writeln('  - $e');
    }
  }

  final logsDir = Directory('logs');
  if (!logsDir.existsSync()) logsDir.createSync(recursive: true);
  final reportFile = File(
    'logs/sync-${DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first}.json',
  );
  await reportFile.writeAsString(jsonEncode({
    'total': total,
    'synced': synced,
    'skipped': skipped,
    'failed': errors.length,
    'errors': errors,
    'durationSeconds': stopwatch.elapsed.inSeconds,
  }));

  workoutX.close();
  database.close();
}

void _printProgress(int done, int total, int synced, int skipped, int failed) {
  const width = 40;
  final ratio = done / total;
  final filled = (ratio * width).round();
  final bar = '${'█' * filled}${'░' * (width - filled)}';
  stdout.write(
    '\rSync en cours... [$bar] $done/$total (${(ratio * 100).toStringAsFixed(0)}%)'
    ' — ✓$synced ↷$skipped ✗$failed',
  );
}

String _formatDuration(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '${m}m ${s}s';
}
