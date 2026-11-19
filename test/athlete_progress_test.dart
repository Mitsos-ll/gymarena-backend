import 'package:test/test.dart';

import '../lib/src/services/athlete_progress.dart';

void main() {
  group('compareExercise — volume', () {
    test('hausse, baisse, égalité arrondie', () {
      expect(
        compareExercise(const TrainingTotals(volumeKg: 1100), const TrainingTotals(volumeKg: 1000))!.toJson(),
        {'trend': 'up', 'volumePct': 10},
      );
      expect(
        compareExercise(const TrainingTotals(volumeKg: 900), const TrainingTotals(volumeKg: 1000))!.trend,
        ProgressTrend.down,
      );
      // +0,4 % s'affiche « 0 % » : neutre, jamais vert.
      final flat = compareExercise(const TrainingTotals(volumeKg: 1004), const TrainingTotals(volumeKg: 1000))!;
      expect(flat.trend, ProgressTrend.flat);
      expect(flat.volumePct, 0);
    });

    test('pas de référence exploitable → null, jamais « 0 % »', () {
      expect(compareExercise(const TrainingTotals(volumeKg: 500), TrainingTotals.zero), isNull);
    });
  });

  group('compareExercise — durée puis distance, en « ou »', () {
    TrainingTotals timed(int seconds, double meters) =>
        TrainingTotals(durationSeconds: seconds, distanceM: meters);

    test("l'une progresse, l'autre baisse → en progrès", () {
      final delta = compareExercise(timed(1650, 4800), timed(1500, 5000))!;
      expect(delta.trend, ProgressTrend.up);
      expect(delta.durationPct, 10);
      expect(delta.distancePct, -4);
    });

    test('les deux baissent → en baisse', () {
      expect(compareExercise(timed(1400, 4500), timed(1500, 5000))!.trend, ProgressTrend.down);
    });

    test("l'une baisse, l'autre stable → neutre", () {
      expect(compareExercise(timed(1500, 4500), timed(1500, 5000))!.trend, ProgressTrend.flat);
    });

    test('planche : seule la durée est mesurée', () {
      final delta = compareExercise(timed(40, 0), timed(45, 0))!;
      expect(delta.toJson(), {'trend': 'down', 'durationPct': -11});
    });

    test('tenue chargée convertie (charge × reps + durée) : comparée en durée', () {
      final delta = compareExercise(
        const TrainingTotals(volumeKg: 1200, durationSeconds: 30),
        const TrainingTotals(volumeKg: 1600, durationSeconds: 25),
      )!;
      expect(delta.trend, ProgressTrend.up);
      expect(delta.volumePct, isNull);
    });

    test('rien de mesurable des deux côtés → null', () {
      expect(compareExercise(timed(30, 0), timed(0, 2000)), isNull);
    });
  });

  test('compareSession : volume, ou durée/distance pour une séance sans charge', () {
    expect(
      compareSession(
        const TrainingTotals(volumeKg: 5000, durationSeconds: 600),
        const TrainingTotals(volumeKg: 4000, durationSeconds: 900),
      )!.toJson(),
      {'trend': 'up', 'volumePct': 25},
    );
    expect(
      compareSession(
        const TrainingTotals(durationSeconds: 3000, distanceM: 10000),
        const TrainingTotals(durationSeconds: 3200, distanceM: 10000),
      )!.trend,
      ProgressTrend.flat,
    );
  });

  group('attendance', () {
    // Jeudi 19 novembre 2026, semaine en cours du lundi 16/11 : les quatre
    // semaines complètes sont celles des lundis 19/10, 26/10, 2/11 et 9/11.
    final today = DateTime(2026, 11, 19);
    final longAgo = DateTime(2026, 1, 1);

    test('plafond hebdo : une grosse semaine ne rattrape pas une semaine vide', () {
      final result = attendance(
        workoutDays: [
          for (final d in [26, 27, 28, 29, 30]) DateTime(2026, 10, d), // 5 séances
          DateTime(2026, 11, 3), DateTime(2026, 11, 5), DateTime(2026, 11, 7),
          DateTime(2026, 11, 10), DateTime(2026, 11, 12),
          // Semaine en cours : jamais comptée.
          DateTime(2026, 11, 17), DateTime(2026, 11, 18),
        ],
        today: today,
        targetPerWeek: 3,
        followedSince: longAgo,
      )!;
      // 3 (plafonné) + 3 + 2 + 0 sur 12.
      expect(result.toJson(), {'pct': 67, 'done': 8, 'expected': 12, 'weeks': 4});
    });

    test("ne compte que les semaines complètes depuis l'arrivée chez le coach", () {
      final result = attendance(
        workoutDays: [
          DateTime(2026, 10, 27),
          DateTime(2026, 11, 3),
          DateTime(2026, 11, 10),
          DateTime(2026, 11, 18),
        ],
        today: today,
        targetPerWeek: 2,
        // Arrivé le mercredi 28/10 : sa semaine, incomplète, ne compte pas.
        followedSince: DateTime(2026, 10, 28, 15, 30),
      )!;
      expect(result.weeks, 2);
      expect(result.done, 2);
      expect(result.pct, 50);
    });

    test("aucune semaine complète écoulée → null", () {
      expect(
        attendance(
          workoutDays: [DateTime(2026, 11, 17)],
          today: today,
          targetPerWeek: 3,
          followedSince: DateTime(2026, 11, 17),
        ),
        isNull,
      );
    });
  });

  test('séances et tendance du volume sur 28 jours glissants', () {
    final today = DateTime(2026, 11, 19);
    final history = [
      (day: DateTime(2026, 11, 19), volumeKg: 3000.0),
      (day: DateTime(2026, 10, 23), volumeKg: 3000.0), // 1er jour de la fenêtre
      (day: DateTime(2026, 10, 22), volumeKg: 5000.0), // fenêtre précédente
      (day: DateTime(2026, 9, 24), volumeKg: 9999.0), // hors des deux fenêtres
    ];
    expect(sessionsInLast28Days(history.map((h) => h.day), today), 2);
    expect(volumeTrendPct(history, today), 20);
    expect(volumeTrendPct(history.take(2), today), isNull);
  });

  test('parseWorkoutDay accepte une date seule ou suivie d’une heure', () {
    expect(parseWorkoutDay('2026-11-18'), DateTime.utc(2026, 11, 18));
    expect(parseWorkoutDay('2026-11-18T07:45:00.000'), DateTime.utc(2026, 11, 18));
    expect(parseWorkoutDay(null), isNull);
    expect(parseWorkoutDay('n/a'), isNull);
  });
}
