class ApiException implements Exception {
  ApiException(this.message, {this.statusCode = 400});

  final String message;
  final int statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}
