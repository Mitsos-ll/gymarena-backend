import 'package:test/test.dart';

import '../lib/src/db/app_database.dart';
import '../lib/src/repositories/exercise_catalog_repository.dart';

void main() {
  late AppDatabase database;
  late ExerciseCatalogRepository repository;

  setUp(() {
    database = AppDatabase.open(':memory:');
    repository = ExerciseCatalogRepository(database: database);
  });

  tearDown(() => database.close());

  test('upsert then getBySlug returns the entry', () {
    repository.upsert(
      slug: 'bench_press',
      workoutXId: '0047',
      name: 'Barbell Bench Press',
      targetMuscles: ['Pectorals'],
      secondaryMuscles: ['Triceps', 'Shoulders'],
      equipment: 'Barbell',
      difficulty: 'intermediate',
      instructions: ['Lie on the bench.', 'Press the bar up.'],
      gifPath: 'exercise_bench_press.gif',
      cachedAt: dbNow(),
    );

    final entry = repository.getBySlug('bench_press');
    expect(entry, isNotNull);
    expect(entry!.name, 'Barbell Bench Press');
    expect(entry.targetMuscles, ['Pectorals']);
    expect(entry.secondaryMuscles, ['Triceps', 'Shoulders']);
    expect(entry.toJson()['gifUrl'], '/exercise-gifs/exercise_bench_press.gif');
  });

  test('upsert twice on the same slug updates instead of duplicating', () {
    repository.upsert(
      slug: 'squat',
      workoutXId: '0063',
      name: 'Barbell Squat',
      targetMuscles: ['Quadriceps'],
      secondaryMuscles: [],
      equipment: 'Barbell',
      difficulty: 'intermediate',
      instructions: [],
      gifPath: null,
      cachedAt: null,
    );
    repository.upsert(
      slug: 'squat',
      workoutXId: '0063',
      name: 'Barbell Squat',
      targetMuscles: ['Quadriceps'],
      secondaryMuscles: [],
      equipment: 'Barbell',
      difficulty: 'intermediate',
      instructions: [],
      gifPath: 'exercise_squat.gif',
      cachedAt: dbNow(),
    );

    expect(repository.count(), 1);
    expect(repository.getBySlug('squat')!.gifPath, 'exercise_squat.gif');
  });

  test('getAll filters by muscle and excludes inactive slugs from search', () {
    repository.upsert(
      slug: 'bench_press',
      workoutXId: '0047',
      name: 'Barbell Bench Press',
      targetMuscles: ['Pectorals'],
      secondaryMuscles: [],
      equipment: 'Barbell',
      difficulty: 'intermediate',
      instructions: [],
      gifPath: null,
      cachedAt: null,
    );
    repository.upsert(
      slug: 'squat',
      workoutXId: '0063',
      name: 'Barbell Squat',
      targetMuscles: ['Quadriceps'],
      secondaryMuscles: [],
      equipment: 'Barbell',
      difficulty: 'intermediate',
      instructions: [],
      gifPath: null,
      cachedAt: null,
    );

    final chestOnly = repository.getAll(muscle: 'Pectorals');
    expect(chestOnly.map((e) => e.slug), ['bench_press']);

    final searched = repository.search('squat');
    expect(searched.map((e) => e.slug), ['squat']);
  });
}
