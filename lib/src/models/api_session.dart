import 'api_profile.dart';
import 'api_user.dart';

class ApiSession {
  ApiSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
    required this.profile,
  });

  final String accessToken;
  final String refreshToken;
  final ApiUser user;
  final ApiProfile? profile;

  Map<String, dynamic> toJson() {
    return {
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'user': user.toJson(),
      'profile': profile?.toJson(),
    };
  }
}
