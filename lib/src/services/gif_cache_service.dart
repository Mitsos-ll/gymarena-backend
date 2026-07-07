import 'dart:io';

import 'workoutx_service.dart';

/// Cache disque des GIFs WorkoutX — téléchargés une fois, servis en statique
/// ensuite (voir ExerciseCatalogRoutes.serveGif). Jamais re-téléchargé pour
/// une requête utilisateur : seul `bin/sync_exercises.dart` écrit ici.
class GifCacheService {
  GifCacheService({required this.cacheDir, required this.workoutX});

  final Directory cacheDir;
  final WorkoutXService workoutX;

  static const _maxBytes = 10 * 1024 * 1024;
  static const _maxRetries = 3;
  static const _timeout = Duration(seconds: 30);

  void ensureCacheDir() {
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }
  }

  String fileNameFor(String slug) => 'exercise_$slug.gif';

  File? getLocalGifFile(String slug) {
    final file = File('${cacheDir.path}/${fileNameFor(slug)}');
    return file.existsSync() ? file : null;
  }

  /// Télécharge et sauvegarde le GIF pour [slug] depuis [gifUrl].
  /// Retourne le nom de fichier local (relatif à [cacheDir]).
  Future<String> downloadAndCacheGif(String slug, String gifUrl) async {
    ensureCacheDir();

    Object? lastError;
    for (var attempt = 1; attempt <= _maxRetries; attempt++) {
      try {
        final bytes = await workoutX.downloadGifBytes(gifUrl).timeout(_timeout);
        if (bytes.length > _maxBytes) {
          throw StateError('GIF too large for $slug: ${bytes.length} bytes');
        }
        final fileName = fileNameFor(slug);
        final file = File('${cacheDir.path}/$fileName');
        await file.writeAsBytes(bytes);
        return fileName;
      } catch (e) {
        lastError = e;
        if (attempt < _maxRetries) {
          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }
    }
    throw StateError('Failed to download GIF for $slug after $_maxRetries attempts: $lastError');
  }
}
