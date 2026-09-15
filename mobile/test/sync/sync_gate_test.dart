import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/device_registration.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/sync/device_sync_controller.dart';
import 'package:nti_pos/data/sync/device_sync_runner.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/retry_gate.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:nti_pos/data/sync/sync_meta_store.dart';
import 'package:nti_pos/data/sync/sync_scheduler.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

class _FakeTimer implements Timer {
  _FakeTimer(this.delay, this._onFire);
  final Duration delay;
  final void Function() _onFire;
  bool _active = true;

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;

  void fire() {
    if (!_active) return;
    _active = false;
    _onFire();
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

DeviceRegistration _binding() => DeviceRegistration(
  baseUrl: 'https://api.test/api/v2',
  token: 'tok',
  expiresAt: DateTime.utc(2030),
  device: {'id': 'device-1'},
  tenant: {'id': 'tenant-1', 'name': 'Warung'},
  outlet: {'id': 'outlet-1', 'name': 'Kemang'},
  register: {
    'id': 'register-1',
    'outlet_id': 'outlet-1',
    'name': 'Kasir 1',
    'table_service': true,
  },
);

/// A server told the device to wait, and fifteen thousand devices at 08:00.
///
/// Both review findings are about requests leaving earlier than allowed: a
/// `Retry-After` shortened by a nudge or skipped by the manual button or the
/// push behind a refused changes call, and a startup spread bypassed by
/// `/devices/me` or by the first connectivity report.
void main() {
  late DateTime now;
  DateTime clock() => now;

  setUp(() => now = DateTime.utc(2026, 9, 14, 8));

  group('RetryGate in the client', () {
    test(
      'a 429 blocks every later request until its Retry-After passes',
      () async {
        var requests = 0;
        var limited = true;
        final client = SyncClient(
          baseUrl: 'https://api.test/api/v2',
          token: 'tok',
          gate: RetryGate(clock: clock),
          client: MockClient((_) async {
            requests++;
            return limited
                ? http.Response('{}', 429, headers: {'retry-after': '120'})
                : http.Response('{"ok":true}', 200);
          }),
        );
        addTearDown(client.close);

        await expectLater(
          client.get('/sync/changes'),
          throwsA(isA<SyncException>()),
        );
        limited = false;

        now = now.add(const Duration(seconds: 119));
        await expectLater(
          client.post('/sync/push', '{}'),
          throwsA(
            isA<SyncException>()
                .having((e) => e.failure, 'failure', SyncFailure.rateLimited)
                .having(
                  (e) => e.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 1),
                ),
          ),
        );
        expect(requests, 1, reason: 'nothing may leave while blocked');

        now = now.add(const Duration(seconds: 2));
        expect(await client.get('/sync/changes'), {'ok': true});
        expect(requests, 2);
      },
    );

    test('a 429 naming no wait still blocks; a 503 naming one blocks; a bare '
        '500 does not', () async {
      final gate = RetryGate(clock: clock);
      var status = 429;
      Map<String, String> headers = {};
      final client = SyncClient(
        baseUrl: 'https://api.test/api/v2',
        token: 'tok',
        gate: gate,
        client: MockClient(
          (_) async => http.Response('{}', status, headers: headers),
        ),
      );
      addTearDown(client.close);

      await expectLater(client.get('/x'), throwsA(isA<SyncException>()));
      expect(gate.remaining, RetryGate.defaultWait);

      now = now.add(const Duration(minutes: 1));
      status = 503;
      headers = {'retry-after': '5'};
      await expectLater(client.get('/x'), throwsA(isA<SyncException>()));
      expect(gate.remaining, const Duration(seconds: 5));

      now = now.add(const Duration(seconds: 6));
      status = 500;
      headers = {};
      await expectLater(client.get('/x'), throwsA(isA<SyncException>()));
      expect(gate.isBlocked, isFalse);
    });
  });

  group('runner', () {
    late Database db;

    setUp(() async {
      db = await openInMemoryAppDb();
      await AppDatabase.instance.useTestDb(db);
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('a 429 on /sync/changes ends the run: no pull, no push', () async {
      final shift = await ShiftRepository.instance.open(
        employeeId: 'e1',
        employeeName: 'Siti',
        openingCash: 0,
        posId: 'register-1',
        posName: 'Kasir 1',
      );
      await OrderRepository.instance.create(
        type: OrderType.takeaway,
        items: const [
          OrderItemDraft(
            productId: 'p1',
            productName: 'Es Teh',
            unitPrice: 5000,
            quantity: 1,
          ),
        ],
        subtotal: 5000,
        discount: 0,
        tax: 0,
        total: 5000,
        amountPaid: 5000,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'e1',
        cashierName: 'Siti',
        posSessionId: shift.id,
      );

      final paths = <String>[];
      final client = SyncClient(
        baseUrl: 'https://api.test/api/v2',
        token: 'tok',
        gate: RetryGate(clock: clock),
        client: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response('{}', 429, headers: {'retry-after': '120'});
        }),
      );
      addTearDown(client.close);
      final runner = DeviceSyncRunner(binding: _binding(), client: client);

      final outcome = await runner.syncNow();

      expect(paths, ['/api/v2/sync/changes']);
      expect(outcome!.failure, SyncFailure.rateLimited);
      expect(outcome.retryAfter, const Duration(seconds: 120));
      expect(await OutboxStore.instance.count(), 2);
      final attempts = await db.query(OutboxStore.table, columns: ['attempts']);
      expect(attempts.map((r) => r['attempts']), everyElement(0));
    });
  });

  group('scheduler', () {
    late List<_FakeTimer> timers;
    late int runs;
    late RetryGate gate;

    SyncScheduler scheduler() => SyncScheduler(
      run: ({required bool full}) async {
        runs++;
        return const SyncOutcome(nextPoll: Duration(seconds: 60));
      },
      gate: gate,
      clock: clock,
      timer: (delay, onFire) {
        final t = _FakeTimer(delay, onFire);
        timers.add(t);
        return t;
      },
    );

    setUp(() {
      timers = [];
      runs = 0;
      gate = RetryGate(clock: clock);
    });

    test('a nudge cannot shorten Retry-After', () async {
      final s = scheduler()..start();
      timers.single.fire();
      await _settle();
      gate.arm(const Duration(seconds: 120));

      // Well past the 30s nudge bound: without the gate this books 5s. The
      // poll booked before the 429 falls inside the block, so it is replaced
      // by a booking at the unblock.
      now = now.add(const Duration(minutes: 1));
      s.nudge();
      expect(timers.last.delay, const Duration(seconds: 60));
      expect(timers.last.delay, gate.remaining);

      // Even a timer fired early sends nothing.
      timers.last.fire();
      await _settle();
      expect(runs, 1);

      now = now.add(const Duration(seconds: 61));
      timers.last.fire();
      await _settle();
      expect(runs, 2);
    });

    test(
      '"Sync now" sends nothing while blocked and books the unblock',
      () async {
        final s = scheduler()..start(initialDelay: const Duration(seconds: 10));
        gate.arm(const Duration(seconds: 90));

        final outcome = await s.syncNow();

        expect(runs, 0);
        expect(outcome!.failure, SyncFailure.rateLimited);
        expect(outcome.retryAfter, const Duration(seconds: 90));
        expect(timers.last.delay, const Duration(seconds: 90));
        expect(timers.last.isActive, isTrue);
      },
    );

    test(
      'a timer that fires while blocked re-books instead of running',
      () async {
        scheduler().start(initialDelay: const Duration(seconds: 10));
        gate.arm(const Duration(seconds: 50));
        timers.single.fire();
        await _settle();
        expect(runs, 0);
        expect(timers.last.delay, const Duration(seconds: 50));
      },
    );

    test('no nudge fires a request inside the startup spread', () async {
      final s = scheduler()..start(initialDelay: const Duration(minutes: 4));

      for (final at in [1, 30, 200]) {
        now = DateTime.utc(2026, 9, 14, 8).add(Duration(seconds: at));
        s.nudge();
      }
      expect(timers, hasLength(1));
      expect(timers.single.delay, const Duration(minutes: 4));
      expect(timers.single.isActive, isTrue);

      // After the spread's run, nudges work normally again.
      now = DateTime.utc(2026, 9, 14, 8, 4);
      timers.single.fire();
      await _settle();
      expect(runs, 1);
      now = now.add(const Duration(seconds: 40));
      s.nudge();
      expect(timers.last.delay, const Duration(seconds: 5));
    });
  });

  test('the connectivity report on attach is not a reconnection', () async {
    final changes = StreamController<List<ConnectivityResult>>();
    final seen = <bool>[];
    final sub = connectivityRegained(changes.stream).listen(seen.add);
    addTearDown(sub.cancel);

    changes.add([ConnectivityResult.wifi]); // announced on attach
    await _settle();
    expect(seen, isEmpty);

    changes.add([ConnectivityResult.none]);
    changes.add([ConnectivityResult.mobile]);
    changes.add([ConnectivityResult.mobile]);
    await _settle();
    expect(seen, [true]);
    await changes.close();
  });

  group('device revision', () {
    late Database db;

    setUp(() async {
      db = await openInMemoryAppDb();
      await AppDatabase.instance.useTestDb(db);
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test(
      '/devices/me is asked once per unconfirmed revision, never on a timer',
      () async {
        var revision = 7;
        var checks = 0;
        var checkSucceeds = true;
        final timers = <_FakeTimer>[];

        final client = SyncClient(
          baseUrl: 'https://api.test/api/v2',
          token: 'tok',
          client: MockClient((request) async {
            if (request.url.path.endsWith('/sync/changes')) {
              return http.Response(
                jsonEncode({
                  'cursors': <String, int>{},
                  'device_revision': revision,
                  'server_time_ms': 1757800000000,
                  'next_poll_ms': 60000,
                }),
                200,
              );
            }
            return http.Response('{"error":{"code":"not_found"}}', 404);
          }),
        );
        final controller = DeviceSyncController(
          runner: DeviceSyncRunner(binding: _binding(), client: client),
          onDeviceRevisionChanged: () async {
            checks++;
            return checkSucceeds;
          },
          schedulerFactory: (run, gate) => SyncScheduler(
            run: run,
            gate: gate,
            timer: (delay, onFire) {
              final t = _FakeTimer(delay, onFire);
              timers.add(t);
              return t;
            },
          ),
        );
        addTearDown(controller.dispose);

        // A run touches real SQLite, which microtask turns do not wait for.
        // It is finished when it has booked the next poll.
        Future<void> poll() async {
          final before = timers.length;
          timers.last.fire();
          for (var i = 0; i < 400 && timers.length == before; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(timers.length, before + 1, reason: 'the run did not finish');
        }

        controller.start();
        await poll();
        expect(
          checks,
          1,
          reason: 'first sight of a revision is confirmed once',
        );
        expect(await SyncMetaStore.instance.deviceRevision(), 7);

        await poll();
        expect(checks, 1, reason: 'an unchanged revision asks nothing');

        revision = 8;
        checkSucceeds = false;
        await poll();
        expect(checks, 2);
        expect(await SyncMetaStore.instance.deviceRevision(), 7);

        checkSucceeds = true;
        await poll();
        expect(checks, 3, reason: 'a failed check is asked again next poll');
        expect(await SyncMetaStore.instance.deviceRevision(), 8);
      },
    );
  });
}
