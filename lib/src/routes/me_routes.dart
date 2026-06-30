import 'package:shelf/shelf.dart';

import '../models/api_profile.dart';
import '../repositories/user_repository.dart';
import '../utils/api_exception.dart';
import '../utils/http_json.dart';

class MeRoutes {
  MeRoutes({required UserRepository userRepository})
      : _userRepository = userRepository;

  final UserRepository _userRepository;

  Future<Response> getMe(Request request) async {
    try {
      final bearer = bearerToken(request);
      if (bearer == null || bearer.isEmpty) {
        throw ApiException('Unauthorized.', statusCode: 401);
      }

      final session = _userRepository.getSessionByAccessToken(bearer);
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    } catch (e) {
      return errorResponse('Unexpected /me error: $e', statusCode: 500);
    }
  }

  Future<Response> upsertProfile(Request request) async {
    try {
      final bearer = bearerToken(request);
      if (bearer == null || bearer.isEmpty) {
        throw ApiException('Unauthorized.', statusCode: 401);
      }

      final body = await readJsonBody(request);
      final displayName = body['displayName']?.toString().trim() ?? '';
      if (displayName.isEmpty) {
        throw ApiException('displayName is required.', statusCode: 400);
      }

      final weightKg = _doubleOrNull(body['weightKg']);
      final heightCm = _doubleOrNull(body['heightCm']);
      final sex = _sexFromString(body['sex']?.toString());
      final fitnessGoal = body['fitnessGoal']?.toString();

      final session = _userRepository.upsertProfile(
        bearer,
        ApiProfileInput(
          displayName: displayName,
          weightKg: weightKg,
          heightCm: heightCm,
          sex: sex,
          fitnessGoal: fitnessGoal,
        ),
      );
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    } catch (e) {
      return errorResponse('Unexpected profile error: $e', statusCode: 500);
    }
  }

  Future<Response> updateFitnessGoal(Request request) async {
    try {
      final bearer = bearerToken(request);
      if (bearer == null || bearer.isEmpty) {
        throw ApiException('Unauthorized.', statusCode: 401);
      }

      final body = await readJsonBody(request);
      final fitnessGoal = body['fitnessGoal']?.toString();

      final session = _userRepository.updateFitnessGoal(bearer, fitnessGoal);
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    } catch (e) {
      return errorResponse('Unexpected fitness-goal error: $e', statusCode: 500);
    }
  }

  double? _doubleOrNull(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty) return null;
    return double.tryParse(text.replaceAll(',', '.'));
  }

  UserSex _sexFromString(String? value) {
    switch (value) {
      case 'male':
        return UserSex.male;
      case 'female':
        return UserSex.female;
      case 'other':
        return UserSex.other;
      default:
        return UserSex.unspecified;
    }
  }
}