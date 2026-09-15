import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/sync/sync_client.dart';

/// The transport both sync directions share.
///
/// What is guarded: that no response shape can be read as success when it is
/// not one, and that no status code is ever given a meaning that deletes
/// queued work. The v1 client read a `[]` body and a 422 as `malformed`, and
/// `malformed` dropped the sale.
void main() {
  SyncClient clientFor(
    Future<http.Response> Function(http.Request request) respond, {
    List<http.Request>? seen,
  }) {
    final client = SyncClient(
      baseUrl: 'https://api.test/api/v2/',
      token: 'tok',
      client: MockClient((request) {
        seen?.add(request);
        return respond(request);
      }),
    );
    addTearDown(client.close);
    return client;
  }

  Matcher failsWith(SyncFailure failure) => throwsA(
    isA<SyncException>().having((e) => e.failure, 'failure', failure),
  );

  test('sends the bearer token and schema version, and never follows a '
      'redirect', () async {
    final seen = <http.Request>[];
    final client = clientFor(
      (_) async => http.Response('{"cursors":{}}', 200),
      seen: seen,
    );

    await client.get('/sync/changes');
    await client.post('/sync/push', '{"batches":[]}');

    for (final request in seen) {
      expect(request.headers['Authorization'], 'Bearer tok');
      expect(request.headers['X-Schema-Version'], '$kClientSchemaVersion');
      expect(request.followRedirects, isFalse);
    }
    expect(seen.first.url.toString(), 'https://api.test/api/v2/sync/changes');
    // A String body goes up verbatim, so a retry resends identical bytes.
    expect(seen.last.body, '{"batches":[]}');
  });

  for (final body in ['[]', '"ok"', 'null', '', '42', 'not json']) {
    test('a 2xx body of ${body.isEmpty ? 'nothing' : body} is malformed, '
        'never a success', () async {
      final client = clientFor((_) async => http.Response(body, 200));
      await expectLater(
        client.post('/sync/push', '{}'),
        failsWith(SyncFailure.malformed),
      );
    });
  }

  test('401 and 403 mean re-activate', () async {
    for (final status in [401, 403]) {
      final client = clientFor((_) async => http.Response('{}', status));
      await expectLater(
        client.get('/sync/changes'),
        failsWith(SyncFailure.unauthorized),
      );
    }
  });

  test('409 device_schema_outdated asks for an update; another 409 is '
      'retryable', () async {
    final outdated = clientFor(
      (_) async => http.Response(
        '{"error":{"code":"device_schema_outdated","message":"x"}}',
        409,
      ),
    );
    await expectLater(
      outdated.get('/sync/manifest'),
      failsWith(SyncFailure.schemaOutdated),
    );

    final other = clientFor(
      (_) async => http.Response('{"error":{"code":"conflict"}}', 409),
    );
    await expectLater(
      other.get('/sync/manifest'),
      failsWith(SyncFailure.server),
    );
  });

  test('422 is a retryable server failure, not a verdict on a row', () async {
    final client = clientFor((_) async => http.Response('{}', 422));
    await expectLater(
      client.post('/sync/push', '{}'),
      failsWith(SyncFailure.server),
    );
  });

  test('429 and 503 carry Retry-After', () async {
    final limited = clientFor(
      (_) async => http.Response('{}', 429, headers: {'retry-after': '17'}),
    );
    await expectLater(
      limited.get('/sync/changes'),
      throwsA(
        isA<SyncException>()
            .having((e) => e.failure, 'failure', SyncFailure.rateLimited)
            .having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 17),
            ),
      ),
    );

    final unavailable = clientFor(
      (_) async => http.Response('{}', 503, headers: {'retry-after': '5'}),
    );
    await expectLater(
      unavailable.get('/sync/changes'),
      throwsA(
        isA<SyncException>()
            .having((e) => e.failure, 'failure', SyncFailure.server)
            .having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 5),
            ),
      ),
    );
  });

  test('a redirect is a failure, not a second request', () async {
    var requests = 0;
    final client = clientFor((_) async {
      requests++;
      return http.Response('', 302, headers: {'location': 'https://evil.test'});
    });
    await expectLater(
      client.get('/sync/changes'),
      failsWith(SyncFailure.server),
    );
    expect(requests, 1);
  });

  test(
    'no response is a network failure that does not repeat the URL',
    () async {
      final client = clientFor(
        (_) async => throw http.ClientException(
          'failed',
          Uri.parse('https://api.test/api/v2/sync/changes?secret=1'),
        ),
      );
      await expectLater(
        client.get('/sync/changes'),
        throwsA(
          isA<SyncException>()
              .having((e) => e.failure, 'failure', SyncFailure.network)
              .having((e) => e.detail, 'detail', isNot(contains('secret'))),
        ),
      );
    },
  );
}
