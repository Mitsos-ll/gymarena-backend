/// Calculs du suivi coach (progression, assiduité) à partir de l'historique
/// d'un athlète. Aucune lecture en base : les routes chargent les données,
/// tout le calcul est ici et se teste seul.
///
/// Le volume suit la formule de la saisie côté app (charge × reps, somme des
/// côtés pour un exercice unilatéral) pour que le coach lise le même
/// pourcentage que son athlète. Seule différence assumée : le réglage local
/// « séries secondaires comptées à 50 % » ne remonte pas au serveur.
library;

/// Totaux d'un exercice, ou d'une séance entière, sur une séance.
class TrainingTotals {
  const TrainingTotals({
    this.volumeKg = 0,
    this.durationSeconds = 0,
    this.distanceM = 0,
  });

  static const zero = TrainingTotals();

  final double volumeKg;
  final int durationSeconds;
  final double distanceM;

  /// Saisi en durée ou en distance (cardio, gainage) plutôt qu'en charge.
  bool get isTimed => durationSeconds > 0 || distanceM > 0;

  TrainingTotals operator +(TrainingTotals other) => TrainingTotals(
        volumeKg: volumeKg + other.volumeKg,
        durationSeconds: durationSeconds + other.durationSeconds,
        distanceM: distanceM + other.distanceM,
      );
}

enum ProgressTrend { up, down, flat }

/// Écart avec la fois précédente. Les pourcentages sont arrondis à l'unité,
/// comme à l'affichage : c'est l'arrondi qui décide de la tendance, pour
/// qu'un « +0 % » ne s'affiche jamais en vert.
class ProgressDelta {
  const ProgressDelta({
    required this.trend,
    this.volumePct,
    this.durationPct,
    this.distancePct,
  });

  final ProgressTrend trend;
  final int? volumePct;
  final int? durationPct;
  final int? distancePct;

  Map<String, dynamic> toJson({String? previousDate}) => {
        'trend': trend.name,
        if (volumePct != null) 'volumePct': volumePct,
        if (durationPct != null) 'durationPct': durationPct,
        if (distancePct != null) 'distancePct': distancePct,
        if (previousDate != null) 'previousDate': previousDate,
      };
}

/// Variation en % de [current] par rapport à [previous], `null` sans
/// référence exploitable (même règle que `progressionPct` côté app : un
/// `null` s'affiche « – », jamais « 0 % »).
double? progressionPct(double current, double previous) {
  if (!current.isFinite || !previous.isFinite || previous <= 0) return null;
  return (current - previous) / previous * 100;
}

ProgressTrend _trendOf(int pct) =>
    pct > 0 ? ProgressTrend.up : (pct < 0 ? ProgressTrend.down : ProgressTrend.flat);

ProgressDelta? _compareVolume(TrainingTotals current, TrainingTotals previous) {
  final pct = progressionPct(current.volumeKg, previous.volumeKg)?.round();
  if (pct == null) return null;
  return ProgressDelta(trend: _trendOf(pct), volumePct: pct);
}

/// Durée puis distance, en « ou » : en progrès si l'une des deux progresse,
/// en baisse si toutes celles mesurées des deux côtés baissent, neutre sinon.
ProgressDelta? _compareTimed(TrainingTotals current, TrainingTotals previous) {
  final durationPct = current.durationSeconds > 0 && previous.durationSeconds > 0
      ? progressionPct(current.durationSeconds.toDouble(), previous.durationSeconds.toDouble())!
          .round()
      : null;
  final distancePct = current.distanceM > 0 && previous.distanceM > 0
      ? progressionPct(current.distanceM, previous.distanceM)!.round()
      : null;
  final measured = [
    if (durationPct != null) durationPct,
    if (distancePct != null) distancePct,
  ];
  if (measured.isEmpty) return null;

  final ProgressTrend trend;
  if (measured.any((p) => p > 0)) {
    trend = ProgressTrend.up;
  } else if (measured.every((p) => p < 0)) {
    trend = ProgressTrend.down;
  } else {
    trend = ProgressTrend.flat;
  }
  return ProgressDelta(trend: trend, durationPct: durationPct, distancePct: distancePct);
}

/// Écart d'un exercice avec la dernière fois où l'athlète l'a fait.
/// Exercice en durée/distance → [_compareTimed], sinon volume.
ProgressDelta? compareExercise(TrainingTotals current, TrainingTotals previous) =>
    current.isTimed ? _compareTimed(current, previous) : _compareVolume(current, previous);

/// Écart d'une séance avec la précédente de la même origine. Une séance
/// sans aucune charge (course, Hyrox…) se compare en durée/distance.
ProgressDelta? compareSession(TrainingTotals current, TrainingTotals previous) =>
    current.volumeKg > 0 ? _compareVolume(current, previous) : _compareTimed(current, previous);

/// Assiduité sur des semaines complètes (lundi → dimanche).
class Attendance {
  const Attendance({
    required this.pct,
    required this.done,
    required this.expected,
    required this.weeks,
  });

  final int pct;
  final int done;
  final int expected;
  final int weeks;

  Map<String, dynamic> toJson() => {
        'pct': pct,
        'done': done,
        'expected': expected,
        'weeks': weeks,
      };
}

/// Jour calendaire de [d], à minuit UTC : toute l'arithmétique de dates passe
/// par là pour ne jamais dépendre d'un changement d'heure.
DateTime calendarDay(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// Date (jour seul) d'une `workout_date` serveur, `YYYY-MM-DD` éventuellement
/// suivi d'une heure.
DateTime? parseWorkoutDay(String? raw) {
  if (raw == null || raw.length < 10) return null;
  final day = DateTime.tryParse(raw.substring(0, 10));
  return day == null ? null : calendarDay(day);
}

/// Séances faites sur les [weeks] dernières semaines complètes, chaque
/// semaine plafonnée à [targetPerWeek] : une semaine à 5 séances ne rattrape
/// pas une semaine à 1, c'est la régularité qui est mesurée.
///
/// Une semaine commencée avant [followedSince] (date où l'athlète a rejoint
/// le coach) n'est pas comptée, pour ne pas pénaliser un nouvel athlète.
/// `null` tant qu'aucune semaine complète n'est écoulée.
Attendance? attendance({
  required Iterable<DateTime> workoutDays,
  required DateTime today,
  required int targetPerWeek,
  required DateTime followedSince,
  int weeks = 4,
}) {
  final day = calendarDay(today);
  final currentWeekStart = day.subtract(Duration(days: day.weekday - 1));
  final since = calendarDay(followedSince);
  final days = workoutDays.map(calendarDay).toList();

  var done = 0;
  var eligibleWeeks = 0;
  for (var i = 1; i <= weeks; i++) {
    final start = currentWeekStart.subtract(Duration(days: 7 * i));
    if (start.isBefore(since)) continue;
    final end = start.add(const Duration(days: 7));
    final count = days.where((d) => !d.isBefore(start) && d.isBefore(end)).length;
    done += count < targetPerWeek ? count : targetPerWeek;
    eligibleWeeks++;
  }
  if (eligibleWeeks == 0) return null;

  final expected = eligibleWeeks * targetPerWeek;
  return Attendance(
    pct: (done * 100 / expected).round(),
    done: done,
    expected: expected,
    weeks: eligibleWeeks,
  );
}

/// Fenêtre glissante de [lengthDays] jours finissant à [today] inclus,
/// décalée de [offsetWindows] fenêtres vers le passé.
bool _inWindow(DateTime day, DateTime today, int lengthDays, int offsetWindows) {
  final end = calendarDay(today).subtract(Duration(days: lengthDays * offsetWindows));
  final start = end.subtract(Duration(days: lengthDays - 1));
  return !day.isBefore(start) && !day.isAfter(end);
}

/// Nombre de séances des 28 derniers jours.
int sessionsInLast28Days(Iterable<DateTime> workoutDays, DateTime today) =>
    workoutDays.where((d) => _inWindow(calendarDay(d), today, 28, 0)).length;

/// Volume des 28 derniers jours comparé aux 28 jours d'avant, en % arrondi.
int? volumeTrendPct(Iterable<({DateTime day, double volumeKg})> workouts, DateTime today) {
  var current = 0.0;
  var previous = 0.0;
  for (final w in workouts) {
    final day = calendarDay(w.day);
    if (_inWindow(day, today, 28, 0)) current += w.volumeKg;
    if (_inWindow(day, today, 28, 1)) previous += w.volumeKg;
  }
  return progressionPct(current, previous)?.round();
}
