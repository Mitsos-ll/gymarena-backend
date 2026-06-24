import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/app.dart';
import 'test_config.dart';

void main() {
  late GymTrackBackend backend;

  setUp(() {
    backend = GymTrackBackend(testConfig());
  });

  tearDown(() => backend.close());

  group('GET /health', () {
    test('returns 200 with ok:true', () async {
      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await backend.handler(request);

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['ok'], isTrue);
      expect(body['service'], 'gymtrack-backend');
      expect(body['env'], 'test');
    });

    test('response contains version and time', () async {
      final request = Request('GET', Uri.parse('http://localhost/health'));
      final response = await backend.handler(request);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['version'], isA<String>());
      expect(body['time'], isA<String>());
    });
  });
}
