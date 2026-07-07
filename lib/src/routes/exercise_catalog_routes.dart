import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../repositories/exercise_catalog_repository.dart';
import '../services/gif_cache_service.dart';
import '../utils/http_json.dart';

class ExerciseCatalogRoutes {
  ExerciseCatalogRoutes({
    required this.repository,
    required this.gifCache,
    required this.adminSecret,
  });

  final ExerciseCatalogRepository repository;
  final GifCacheService gifCache;
  final String adminSecret;

  Response getAll(Request request) {
    final params = request.requestedUri.queryParameters;
    final entries = repository.getAll(
      muscle: params['muscle'],
      equipment: params['equipment'],
      difficulty: params['difficulty'],
    );
    return jsonResponse({
      'success': true,
      'total': entries.length,
      'data': entries.map((e) => e.toJson()).toList(),
    });
  }

  Response getBySlug(Request request, String slug) {
    final entry = repository.getBySlug(slug);
    if (entry == null) {
      return jsonResponse({'success': false, 'message': 'Exercise not found.'}, statusCode: 404);
    }
    return jsonResponse({'success': true, 'data': entry.toJson()});
  }

  Response search(Request request) {
    final query = request.requestedUri.queryParameters['q'] ?? '';
    if (query.trim().isEmpty) {
      return jsonResponse({'success': true, 'data': []});
    }
    final entries = repository.search(query);
    return jsonResponse({'success': true, 'data': entries.map((e) => e.toJson()).toList()});
  }

  Response serveGif(Request request, String filename) {
    // filename attendu: exercise_<slug>.gif — pas d'accès arbitraire au disque.
    if (!RegExp(r'^exercise_[a-z0-9_]+\.gif$').hasMatch(filename)) {
      return jsonResponse({'success': false, 'message': 'Invalid filename.'}, statusCode: 400);
    }
    final file = File('${gifCache.cacheDir.path}/$filename');
    if (!file.existsSync()) {
      return jsonResponse({'success': false, 'message': 'GIF not found.'}, statusCode: 404);
    }
    return Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': 'image/gif',
        'Cache-Control': 'public, max-age=604800',
      },
    );
  }

  /// Import en masse des métadonnées de catalogue déjà récupérées auprès de
  /// WorkoutX ailleurs (ex: sync locale) — aucun appel WorkoutX ici, juste
  /// des upserts SQLite. Les GIFs eux-mêmes doivent être déposés séparément
  /// dans gifCache.cacheDir (ex: via `fly ssh sftp`).
  Future<Response> importCatalog(Request request) async {
    final auth = request.headers['authorization'] ?? '';
    if (auth != 'Bearer $adminSecret') {
      return jsonResponse({'success': false, 'message': 'Unauthorized.'}, statusCode: 401);
    }

    final raw = await request.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return jsonResponse({'success': false, 'message': 'Body must be a JSON array.'}, statusCode: 400);
    }

    var imported = 0;
    final errors = <String>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      try {
        repository.upsert(
          slug: item['slug'] as String,
          workoutXId: item['workoutXId'] as String,
          name: item['name'] as String,
          targetMuscles: (item['targetMuscles'] as List).map((e) => e.toString()).toList(),
          secondaryMuscles: (item['secondaryMuscles'] as List).map((e) => e.toString()).toList(),
          equipment: item['equipment'] as String?,
          difficulty: item['difficulty'] as String?,
          instructions: (item['instructions'] as List).map((e) => e.toString()).toList(),
          gifPath: item['gifPath'] as String?,
          cachedAt: item['cachedAt'] as String?,
        );
        imported++;
      } catch (e) {
        errors.add('${item['slug']}: $e');
      }
    }

    return jsonResponse({
      'success': true,
      'imported': imported,
      'failed': errors.length,
      'errors': errors,
    });
  }
}
