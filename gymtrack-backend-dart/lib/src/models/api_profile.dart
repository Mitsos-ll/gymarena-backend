enum UserSex { male, female, other, unspecified }

class ApiProfile {
  ApiProfile({
    required this.userId,
    required this.displayName,
    required this.createdAt,
    required this.updatedAt,
    this.weightKg,
    this.heightCm,
    required this.sex,
    required this.onboardingCompleted,
  });

  final String userId;
  final String displayName;
  final double? weightKg;
  final double? heightCm;
  final UserSex sex;
  final bool onboardingCompleted;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() {
    return {
      'userId': userId,
      'displayName': displayName,
      'weightKg': weightKg,
      'heightCm': heightCm,
      'sex': sex.name,
      'onboardingCompleted': onboardingCompleted,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  static UserSex sexFromDb(String? value) {
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

  static String sexToDb(UserSex sex) => sex.name;
}
