import 'dart:convert';
import 'dart:io';

import '../lib/src/config.dart';
import '../lib/src/db/app_database.dart';

/// Exporte la table exercise_catalog locale en JSON, prêt à être POSTé sur
/// /admin/exercises/import d'un autre environnement (ex: production) —
/// évite de re-consommer le quota WorkoutX pour transférer les données déjà
/// récupérées.
Future<void> main() async {
  final config = AppConfig.fromEnvironment();
  final database = AppDatabase.open(config.databasePath);

  final rows = database.raw.select('SELECT * FROM exercise_catalog ORDER BY slug;');
  final out = rows.map((r) {
    return {
      'slug': r['slug'],
      'workoutXId': r['workoutx_id'],
      'name': r['name'],
      'targetMuscles': jsonDecode(r['target_muscles'] as String),
      'secondaryMuscles': jsonDecode(r['secondary_muscles'] as String),
      'equipment': r['equipment'],
      'difficulty': r['difficulty'],
      'instructions': jsonDecode(r['instructions'] as String),
      'gifPath': r['gif_path'],
      'cachedAt': r['cached_at'],
    };
  }).toList();

  final file = File('logs/catalog_export.json');
  await file.writeAsString(jsonEncode(out));
  stdout.writeln('Exported ${out.length} rows to ${file.path}');

  database.close();
}
