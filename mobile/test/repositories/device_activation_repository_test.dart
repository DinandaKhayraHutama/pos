import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/device/device_activation_repository.dart';
import 'package:nti_pos/data/device/device_registration.dart';

class MemoryCredentials implements DeviceCredentialStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

final _expiresMs = DateTime.utc(2030).millisecondsSinceEpoch;

/// The binding inside a v2 `data` envelope.
Map<String, dynamic> bindingJson() => {
  'token': '0123456789abcdef',
  'token_expires_at_ms': _expiresMs,
  'device': {
    'id': 'device',
    'device_uuid': 'installation',
    'label': null,
    'platform': 'web',
  },
  'tenant': {'id': 'tenant', 'name': 'Business'},
  'outlet': {'id': 'outlet', 'name': 'Branch', 'address': null, 'phone': null},
  'pos_register': {
    'id': 'register',
    'outlet_id': 'outlet',
    'name': 'Till',
    'table_service': true,
  },
};

Map<String, dynamic> activateBody() => {'data': bindingJson()};

Map<String, dynamic> meBody() => {
  'data': Map.of(bindingJson())
    ..remove('token')
    ..remove('token_expires_at_ms'),
};

void main() {
  test(
    'normalizes codes and persists binding atomically with a stable installation ID',
    () async {
      final store = MemoryCredentials();
      final ids = <String>[];
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v2/devices/activate');
        final input = jsonDecode(request.body) as Map;
        expect(input['code'], 'ABCDEFGH2345');
        expect(
          input.keys,
          unorderedEquals(['code', 'device_uuid', 'platform']),
        );
        ids.add(input['device_uuid'] as String);
        expect(request.followRedirects, isFalse);
        return http.Response(jsonEncode(activateBody()), 200);
      });
      final repository = DeviceActivationRepository(
        baseUrl: 'https://pos.test/api/v2/',
        client: client,
        store: store,
      );
      final binding = await repository.activate(
        'abcd-efgh 2345',
        platform: 'web',
      );
      expect(binding.expiresAt.millisecondsSinceEpoch, _expiresMs);
      expect((await repository.load())!.token, binding.token);
      await repository.activate('ABCDEFGH2345', platform: 'web');
      expect(ids[0], ids[1]);
      expect(
        store.values.length,
        2,
      ); // installation ID plus one complete binding
    },
  );

  // 201 is what the v1 server answered. A v2 build pointed at it must not
  // believe it activated.
  for (final status in [201, 422, 429, 500, 302]) {
    test('handles HTTP $status without retrying a one-use POST', () async {
      var requests = 0;
      final store = MemoryCredentials();
      final repository = DeviceActivationRepository(
        baseUrl: 'https://pos.test/api/v2',
        store: store,
        client: MockClient((_) async {
          requests++;
          return http.Response(jsonEncode(activateBody()), status);
        }),
      );
      await expectLater(
        repository.activate('ABCDEFGH2345', platform: 'web'),
        throwsA(isA<DeviceActivationException>()),
      );
      expect(requests, 1);
      expect(await repository.load(), isNull);
    });
  }

  test('a 200 without the data envelope is not an activation', () async {
    final repository = DeviceActivationRepository(
      baseUrl: 'https://pos.test/api/v2',
      store: MemoryCredentials(),
      client: MockClient(
        (_) async => http.Response(jsonEncode(bindingJson()), 200),
      ),
    );
    await expectLater(
      repository.activate('ABCDEFGH2345', platform: 'web'),
      throwsA(
        isA<DeviceActivationException>().having(
          (e) => e.failure,
          'failure',
          ActivationFailure.network,
        ),
      ),
    );
  });

  test(
    'revocation removes credentials and sends the actual bearer token',
    () async {
      final store = MemoryCredentials();
      var revoked = false;
      final repository = DeviceActivationRepository(
        baseUrl: 'https://pos.test/api/v2',
        store: store,
        client: MockClient((request) async {
          if (request.method == 'POST') {
            return http.Response(jsonEncode(activateBody()), 200);
          }
          expect(request.url.path, '/api/v2/devices/me');
          expect(request.headers['Authorization'], 'Bearer 0123456789abcdef');
          expect(request.followRedirects, isFalse);
          return http.Response(
            revoked ? '{}' : jsonEncode(meBody()),
            revoked ? 401 : 200,
          );
        }),
      );
      final binding = await repository.activate(
        'ABCDEFGH2345',
        platform: 'web',
      );
      final refreshed = await repository.verify(binding);
      expect(refreshed.token, binding.token);
      expect(refreshed.expiresAt, binding.expiresAt);
      revoked = true;
      await expectLater(
        repository.verify(binding),
        throwsA(
          isA<DeviceActivationException>().having(
            (e) => e.failure,
            'failure',
            ActivationFailure.revoked,
          ),
        ),
      );
      expect(await repository.load(), isNull);
    },
  );

  test(
    'network failure preserves saved credentials and expiry removes them',
    () async {
      final store = MemoryCredentials();
      var now = DateTime.utc(2026);
      var offline = false;
      final repository = DeviceActivationRepository(
        baseUrl: 'https://pos.test/api/v2',
        store: store,
        clock: () => now,
        client: MockClient((_) async {
          if (offline) throw http.ClientException('offline');
          return http.Response(jsonEncode(activateBody()), 200);
        }),
      );
      final binding = await repository.activate(
        'ABCDEFGH2345',
        platform: 'web',
      );
      offline = true;
      await expectLater(
        repository.verify(binding),
        throwsA(isA<DeviceActivationException>()),
      );
      expect(await repository.load(), isNotNull);
      now = DateTime.utc(2030, 1, 2);
      expect(await repository.load(), isNull);
    },
  );

  test('stores expiry as epoch milliseconds and still reads a v1 binding', () {
    final binding = DeviceRegistration.fromJson({
      ...bindingJson(),
      'base_url': 'https://a.test/api/v2',
    });
    final stored = binding.toJson();
    expect(stored['token_expires_at_ms'], _expiresMs);
    expect(stored.containsKey('token_expires_at'), isFalse);

    final legacy = DeviceRegistration.fromJson({
      ...(Map.of(stored)..remove('token_expires_at_ms')),
      'token_expires_at': '2030-01-01T00:00:00Z',
    });
    expect(legacy.expiresAt.millisecondsSinceEpoch, _expiresMs);
  });

  test('separates servers and merchants, and rejects inconsistent binding', () {
    final a = DeviceRegistration.fromJson({
      ...bindingJson(),
      'base_url': 'https://a.test/api/v2',
    });
    final b = DeviceRegistration.fromJson({
      ...bindingJson(),
      'base_url': 'https://b.test/api/v2',
    });
    final c = DeviceRegistration.fromJson({
      ...a.toJson(),
      'tenant': {'id': 'other'},
    });
    expect(a.storageScope, isNot(b.storageScope));
    expect(a.storageScope, isNot(c.storageScope));
    expect(
      () => DeviceRegistration.fromJson({
        ...a.toJson(),
        'outlet': {'id': 'wrong'},
      }),
      throwsFormatException,
    );
  });

  test('rejects remote plaintext URLs and embedded credentials', () {
    for (final url in [
      'http://pos.test/api/v2',
      'https://user:password@pos.test/api/v2',
    ]) {
      expect(
        () => DeviceActivationRepository(baseUrl: url),
        throwsA(isA<DeviceActivationException>()),
      );
    }
  });
}
