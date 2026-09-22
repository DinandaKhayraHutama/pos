import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/device/device_activation_repository.dart';
import 'package:nti_pos/data/sync/retry_gate.dart';

class _MemoryCredentials implements DeviceCredentialStore {
  final values = <String, String>{};
  bool failDelete = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('secure storage unavailable');
    values.remove(key);
  }
}

Map<String, dynamic> _binding({String registerName = 'Till'}) => {
  'device': {'id': 'device', 'device_uuid': 'installation'},
  'tenant': {'id': 'tenant', 'name': 'Business'},
  'outlet': {'id': 'outlet', 'name': 'Branch', 'address': null},
  'pos_register': {
    'id': 'register',
    'outlet_id': 'outlet',
    'name': registerName,
    'table_service': true,
  },
};

/// `/devices/me`: what a refreshed binding does to the stored one, and that it
/// honours the device-wide `Retry-After`.
void main() {
  late _MemoryCredentials store;
  late http.Response Function() me;
  late int meRequests;
  late DeviceActivationRepository repository;

  setUp(() {
    store = _MemoryCredentials();
    meRequests = 0;
    me = () => http.Response(
      jsonEncode({'data': _binding(registerName: 'Till Depan')}),
      200,
    );
    repository = DeviceActivationRepository(
      baseUrl: 'https://pos.test/api/v2',
      store: store,
      client: MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'data': {
                ..._binding(),
                'token': 'tok',
                'token_expires_at_ms': DateTime.utc(
                  2030,
                ).millisecondsSinceEpoch,
              },
            }),
            200,
          );
        }
        meRequests++;
        return me();
      }),
    );
  });

  test(
    'a refreshed binding is stored, so the next launch starts from it',
    () async {
      final activated = await repository.activate(
        'ABCDEFGH2345',
        platform: 'web',
      );
      expect((await repository.load())!.register['name'], 'Till');

      final refreshed = await repository.verify(activated);

      expect(refreshed.register['name'], 'Till Depan');
      final reloaded = (await repository.load())!;
      expect(reloaded.register['name'], 'Till Depan');
      expect(reloaded.token, 'tok');
      expect(reloaded.expiresAt, activated.expiresAt);
    },
  );

  test('a blocked gate sends nothing; a 429 arms the gate', () async {
    final activated = await repository.activate(
      'ABCDEFGH2345',
      platform: 'web',
    );
    final gate = RetryGate()..arm(const Duration(seconds: 60));

    await expectLater(
      repository.verify(activated, gate: gate),
      throwsA(
        isA<DeviceActivationException>().having(
          (e) => e.failure,
          'failure',
          ActivationFailure.rateLimited,
        ),
      ),
    );
    expect(meRequests, 0);

    final fresh = RetryGate();
    me = () => http.Response('{}', 429, headers: {'retry-after': '90'});
    await expectLater(
      repository.verify(activated, gate: fresh),
      throwsA(isA<DeviceActivationException>()),
    );
    expect(meRequests, 1);
    expect(fresh.remaining, greaterThan(const Duration(seconds: 85)));
    // The stored binding is untouched by a refused check.
    expect((await repository.load())!.register['name'], 'Till');
  });

  // Revocation nearly always surfaces as a 401 on an ordinary sync, which
  // reaches the app through `onUnauthorized` and never calls `verify`. Leaving
  // the binding behind there meant every relaunch adopted it offline-first,
  // let the cashier in, and dropped back to the activation screen only when
  // the next sync 401'd — a loop that looked like the revoke had not taken.
  test(
    'forget drops the binding but keeps the installation identity',
    () async {
      await repository.activate('ABCDEFGH2345', platform: 'web');
      expect(await repository.load(), isNotNull);
      final installationKeys = store.values.keys
          .where((k) => k.endsWith('_installation'))
          .toList();
      expect(installationKeys, hasLength(1));
      final installation = store.values[installationKeys.single];

      await repository.forget();

      expect(
        await repository.load(),
        isNull,
        reason: 'the next launch must ask for a code',
      );
      // Re-activating has to land on the SAME devices row, or a recovery case
      // raised against this installation can never recognise it again.
      expect(store.values[installationKeys.single], installation);

      final reactivated = await repository.activate(
        'ABCDEFGH2345',
        platform: 'web',
      );
      expect(reactivated.device['device_uuid'], 'installation');
      expect(await repository.load(), isNotNull);
    },
  );

  test(
    'forget reports a storage failure instead of claiming durability',
    () async {
      await repository.activate('ABCDEFGH2345', platform: 'web');
      store.failDelete = true;

      await expectLater(
        repository.forget(),
        throwsA(
          isA<DeviceActivationException>().having(
            (e) => e.failure,
            'failure',
            ActivationFailure.storage,
          ),
        ),
      );

      store.failDelete = false;
      expect(await repository.load(), isNotNull);
    },
  );

  test('a 401 remains a revocation when its first delete fails', () async {
    final binding = await repository.activate('ABCDEFGH2345', platform: 'web');
    me = () => http.Response('{}', 401);
    store.failDelete = true;

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

    // BackendApp receives the revocation and performs the awaited durable
    // retry. Until storage recovers the saved value remains visible here.
    store.failDelete = false;
    expect(await repository.load(), isNotNull);
    await repository.forget();
    expect(await repository.load(), isNull);
  });
}
