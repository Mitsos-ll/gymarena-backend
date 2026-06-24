import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../models/api_profile.dart';
import '../repositories/user_repository.dart';
import '../services/google_token_service.dart';
import '../utils/api_exception.dart';
import '../utils/http_json.dart';

class AuthRoutes {
  AuthRoutes({
    required GoogleTokenService googleTokenService,
    required UserRepository userRepository,
  })  : _googleTokenService = googleTokenService,
        _userRepository = userRepository;

  final GoogleTokenService _googleTokenService;
  final UserRepository _userRepository;

  Router get router {
    final router = Router();
    router.post('/google', signInGoogle);
    router.post('/register', register);
    router.post('/login', login);
    router.post('/refresh', refresh);
    router.post('/logout', logout);
    return router;
  }

  Future<Response> signInGoogle(Request request) async {
    try {
      final body = await readJsonBody(request);
      final idToken = body['idToken']?.toString().trim() ?? '';
      if (idToken.isEmpty) {
        throw ApiException('idToken is required.', statusCode: 400);
      }

      final google = await _googleTokenService.verifyIdToken(idToken);
      final session = _userRepository.signInWithGoogle(google);
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    } catch (e) {
      return errorResponse('Unexpected sign-in error: $e', statusCode: 500);
    }
  }

  Future<Response> register(Request request) async {
    try {
      final body = await readJsonBody(request);
      final email = body['email']?.toString().trim() ?? '';
      final password = body['password']?.toString() ?? '';
      final displayName = body['displayName']?.toString().trim() ?? '';

      if (email.isEmpty) {
        throw ApiException('email is required.', statusCode: 400);
      }
      if (password.length < 8) {
        throw ApiException('password must be at least 8 characters.', statusCode: 400);
      }

      final session = _userRepository.registerWithGymTrack(
        email: email,
        password: password,
        displayName: displayName.isEmpty ? null : displayName,
      );
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    } catch (e) {
      return errorResponse('Unexpected register error: $e', statusCode: 500);
    }
  }

  Future<Response> login(Request request) async {
    try {
      final body = await readJsonBody(request);
      final email = body['email']?.toString().trim() ?? '';
      final password = body['password']?.toString() ?? '';

      if (email.isEmpty) {
        throw ApiException('email is required.', statusCode: 400);
      }
      if (password.isEmpty) {
        throw ApiException('password is required.', statusCode: 400);
      }

      final session = _userRepository.signInWithGymTrack(
        email: email,
        password: password,
      );
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    } catch (e) {
      return errorResponse('Unexpected login error: $e', statusCode: 500);
    }
  }

  Future<Response> refresh(Request request) async {
    try {
      final body = await readJsonBody(request);
      final refreshToken = body['refreshToken']?.toString().trim() ?? '';
      if (refreshToken.isEmpty) {
        throw ApiException('refreshToken is required.', statusCode: 400);
      }

      final session = _userRepository.refreshSession(refreshToken);
      return jsonResponse(session.toJson());
    } on ApiException catch (e) {
      return errorResponse(e.message, statusCode: e.statusCode);
    } catch (e) {
      return errorResponse('Unexpected refresh error: $e', statusCode: 500);
    }
  }

  Future<Response> logout(Request request) async {
    try {
      final bearer = bearerToken(request);
      if (bearer != null && bearer.isNotEmpty) {
        _userRepository.logoutByBearerToken(bearer);
      }
      return jsonResponse({'ok': true});
    } catch (e) {
      return errorResponse('Unexpected logout error: $e', statusCode: 500);
    }
  }
}
