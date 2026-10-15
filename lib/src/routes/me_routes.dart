import 'package:shelf/shelf.dart';

import '../models/api_profile.dart';
import '../repositories/user_repository.dart';
import '../services/apple_rest_service.dart';
import '../utils/api_exception.dart';
import '../utils/http_json.dart';
import '../utils/validator.dart';

class MeRoutes {
  MeRoutes({
    required UserRepository userRepository,
    required AppleRestService appleRestService,
  })  : _userRepository = userRepository,
        _appleRest = appleRestService;

  final UserRepository _userRepository;
  final AppleRestService _appleRest;

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
      final displayName = validateDisplayName(body['displayName']?.toString(), required: true)!;

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

  Future<Response> deleteAccount(Request request) async {
    try {
      final bearer = bearerToken(request);
      if (bearer == null || bearer.isEmpty) {
        throw ApiException('Unauthorized.', statusCode: 401);
      }

      final appleRefreshToken = _userRepository.deleteAccount(bearer);
      // Exigé par Apple pour toute app proposant Sign in with Apple. Meilleur
      // effort : le compte est déjà supprimé, un échec côté Apple ne doit pas
      // se transformer en erreur pour l'utilisateur.
      if (appleRefreshToken != null) {
        await _appleRest.revokeRefreshToken(appleRefreshToken);
      }
      return jsonResponse({'success': true});
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    } catch (e) {
      return errorResponse('Unexpected account deletion error: $e', statusCode: 500);
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