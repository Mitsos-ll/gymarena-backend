import 'dart:convert';

import 'package:http/http.dart' as http;

class WorkoutXExercise {
  WorkoutXExercise({
    required this.id,
    required this.name,
    required this.bodyPart,
    required this.target,
    required this.secondaryMuscles,
    required this.equipment,
    required this.difficulty,
    required this.instructions,
    required this.gifUrl,
  });

  final String id;
  final String name;
  final String bodyPart;
  final String target;
  final List<String> secondaryMuscles;
  final String? equipment;
  final String? difficulty;
  final List<String> instructions;
  final String gifUrl;

  static WorkoutXExercise fromJson(Map<String, dynamic> json) {
    return WorkoutXExercise(
      id: json['id'] as String,
      name: json['name'] as String,
      bodyPart: json['bodyPart'] as String? ?? '',
      target: json['target'] as String? ?? '',
      secondaryMuscles: (json['secondaryMuscles'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
      equipment: json['equipment'] as String?,
      difficulty: json['difficulty'] as String?,
      instructions:
          (json['instructions'] as List? ?? []).map((e) => e.toString()).toList(),
      gifUrl: json['gifUrl'] as String,
    );
  }
}

/// Client pour l'API WorkoutX (https://api.workoutxapp.com/v1).
///
/// Rate-limit constaté : 30 requêtes / 60s. Quota mensuel séparé (plan payant).
/// Auth via header `X-WorkoutX-Key` (pas Bearer, pas x-api-key).
class WorkoutXService {
  WorkoutXService({required String apiKey, required String baseUrl})
      : _apiKey = apiKey,
        _baseUrl = baseUrl,
        _client = http.Client();

  final String _apiKey;
  final String _baseUrl;
  final http.Client _client;

  final Map<String, WorkoutXExercise> _cache = {};

  Map<String, String> get _headers => {'X-WorkoutX-Key': _apiKey};

  Future<WorkoutXExercise> getExerciseById(String id) async {
    final cached = _cache[id];
    if (cached != null) return cached;

    final uri = Uri.parse('$_baseUrl/exercises/$id');
    final response = await _client.get(uri, headers: _headers);

    if (response.statusCode != 200) {
      throw WorkoutXException(
        'GET /exercises/$id failed with ${response.statusCode}: ${response.body}',
      );
    }

    final exercise = WorkoutXExercise.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    _cache[id] = exercise;
    return exercise;
  }

  /// Télécharge le GIF binaire d'un exercice (même auth requise que l'API).
  Future<List<int>> downloadGifBytes(String gifUrl) async {
    final response = await _client.get(Uri.parse(gifUrl), headers: _headers);
    if (response.statusCode != 200) {
      throw WorkoutXException(
        'GET $gifUrl failed with ${response.statusCode}',
      );
    }
    return response.bodyBytes;
  }

  void close() {
    _client.close();
  }
}

class WorkoutXException implements Exception {
  WorkoutXException(this.message);
  final String message;

  @override
  String toString() => 'WorkoutXException: $message';
}
