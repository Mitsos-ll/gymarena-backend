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

  Future<Response> get(String path) async {
    return backend.handler(Request('GET', Uri.parse('http://localhost$path')));
  }

  group('GET /.well-known/assetlinks.json', () {
    test('déclare le package Android et l\'empreinte SHA-256 de signature', () async {
      final res = await get('/.well-known/assetlinks.json');
      expect(res.statusCode, 200);

      final body = jsonDecode(await res.readAsString()) as List;
      final target = body.first['target'] as Map;
      expect(target['package_name'], 'com.gymarena.app');
      expect(
        (target['sha256_cert_fingerprints'] as List).single,
        '9F:3B:AB:73:E0:E3:7A:5A:05:08:B0:1A:D3:8F:54:89:DE:72:D5:C6:0A:67:77:96:49:D7:71:84:7F:B9:E2:3B',
      );
    });
  });
}
