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

  group('GET /privacy', () {
    test('est publique (aucune authentification requise)', () async {
      final res = await get('/privacy');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/html'));
    });

    test('/privacy-policy sert la même page', () async {
      final a = await (await get('/privacy')).readAsString();
      final b = await (await get('/privacy-policy')).readAsString();
      expect(a, b);
    });

    // Le rejet Play Store « Data retention policy not specified » vient de
    // l'absence de ces éléments : on les verrouille par test.
    test('déclare la conservation et la suppression des données', () async {
      final body = (await (await get('/privacy')).readAsString()).toLowerCase();

      expect(body, contains('conservation des données'));
      expect(body, contains('data retention'));
      expect(body, contains('supprimer mon compte'));
      expect(body, contains('irréversible'));
      expect(body, contains('bcrypt'));
    });
  });
}
