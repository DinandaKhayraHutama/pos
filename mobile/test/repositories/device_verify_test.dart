import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/device/device_activation_repository.dart';
import 'package:nti_pos/data/sync/retry_gate.dart';

class _MemoryCredentials implements DeviceCredentialStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
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
}
