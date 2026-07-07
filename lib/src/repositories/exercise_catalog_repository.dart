import 'dart:convert';

import '../db/app_database.dart';

class ExerciseCatalogEntry {
  ExerciseCatalogEntry({
    required this.slug,
    required this.workoutXId,
    required this.name,
    required this.targetMuscles,
    required this.secondaryMuscles,
    required this.equipment,
    required this.difficulty,
    required this.instructions,
    required this.gifPath,
    required this.cachedAt,
    required this.active,
  });

  final String slug;
  final String workoutXId;
  final String name;
  final List<String> targetMuscles;
  final List<String> secondaryMuscles;
  final String? equipment;
  final String? difficulty;
  final List<String> instructions;
  final String? gifPath;
  final String? cachedAt;
  final bool active;

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'name': name,
        'targetMuscles': targetMuscles,
        'secondaryMuscles': secondaryMuscles,
        'equipment': equipment,
        'difficulty': difficulty,
        'instructions': instructions,
        'gifUrl': gifPath == null ? null : '/exercise-gifs/$gifPath',
      };

  static ExerciseCatalogEntry fromRow(Map<String, dynamic> row) {
    List<String> parseList(dynamic raw) =>
        (jsonDecode(raw as String) as List).map((e) => e.toString()).toList();
    return ExerciseCatalogEntry(
      slug: row['slug'] as String,
      workoutXId: row['workoutx_id'] as String,
      name: row['name'] as String,
      targetMuscles: parseList(row['target_muscles']),
      secondaryMuscles: parseList(row['secondary_muscles']),
      equipment: row['equipment'] as String?,
      difficulty: row['difficulty'] as String?,
      instructions: parseList(row['instructions']),
      gifPath: row['gif_path'] as String?,
      cachedAt: row['cached_at'] as String?,
      active: (row['active'] as int) == 1,
    );
  }
}

class ExerciseCatalogRepository {
  ExerciseCatalogRepository({required AppDatabase database}) : _database = database;

  final AppDatabase _database;

  List<ExerciseCatalogEntry> getAll({
    String? muscle,
    String? equipment,
    String? difficulty,
  }) {
    final where = <String>['active = 1'];
    final args = <Object?>[];
    if (muscle != null) {
      where.add("(target_muscles LIKE ? OR secondary_muscles LIKE ?)");
      args.add('%"$muscle"%');
      args.add('%"$muscle"%');
    }
    if (equipment != null) {
      where.add('equipment = ?');
      args.add(equipment);
    }
    if (difficulty != null) {
      where.add('difficulty = ?');
      args.add(difficulty);
    }

    final rows = _database.raw.select(
      'SELECT * FROM exercise_catalog WHERE ${where.join(' AND ')} ORDER BY name;',
      args,
    );
    return rows.map((r) => ExerciseCatalogEntry.fromRow(r)).toList();
  }

  ExerciseCatalogEntry? getBySlug(String slug) {
    final rows = _database.raw.select(
      'SELECT * FROM exercise_catalog WHERE slug = ? LIMIT 1;',
      [slug],
    );
    if (rows.isEmpty) return null;
    return ExerciseCatalogEntry.fromRow(rows.first);
  }

  List<ExerciseCatalogEntry> search(String query) {
    final rows = _database.raw.select(
      'SELECT * FROM exercise_catalog WHERE active = 1 AND name LIKE ? ORDER BY name;',
      ['%$query%'],
    );
    return rows.map((r) => ExerciseCatalogEntry.fromRow(r)).toList();
  }

  void upsert({
    required String slug,
    required String workoutXId,
    required String name,
    required List<String> targetMuscles,
    required List<String> secondaryMuscles,
    String? equipment,
    String? difficulty,
    required List<String> instructions,
    String? gifPath,
    String? cachedAt,
  }) {
    final now = dbNow();
    _database.raw.execute('''
      INSERT INTO exercise_catalog (
        slug, workoutx_id, name, target_muscles, secondary_muscles,
        equipment, difficulty, instructions, gif_path, cached_at,
        active, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT(slug) DO UPDATE SET
        workoutx_id = excluded.workoutx_id,
        name = excluded.name,
        target_muscles = excluded.target_muscles,
        secondary_muscles = excluded.secondary_muscles,
        equipment = excluded.equipment,
        difficulty = excluded.difficulty,
        instructions = excluded.instructions,
        gif_path = excluded.gif_path,
        cached_at = excluded.cached_at,
        updated_at = excluded.updated_at;
    ''', [
      slug,
      workoutXId,
      name,
      jsonEncode(targetMuscles),
      jsonEncode(secondaryMuscles),
      equipment,
      difficulty,
      jsonEncode(instructions),
      gifPath,
      cachedAt,
      now,
      now,
    ]);
  }

  int count() {
    final rows = _database.raw.select('SELECT COUNT(*) AS c FROM exercise_catalog;');
    return rows.first['c'] as int;
  }
}
