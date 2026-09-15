import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/connected_storage.dart';
import 'package:nti_pos/data/device/device_registration.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/preferences/app_preferences.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/sync/dead_letter_store.dart';
import 'package:nti_pos/data/sync/outbox_push.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/session_push.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:nti_pos/providers/outlet_provider.dart';
import 'package:nti_pos/providers/pos_register_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _bound = TillBinding(outletId: 'outlet-1', registerId: 'reg-1');

/// An activated till is ONE register in ONE outlet.
///
/// The server takes the register from the device token and never from a
/// pushed row. Every case here is a way the till used to be able to record a
/// drawer or a sale under a different register than the one the server would
/// file it under — the review finding "R1 bound, R2 selectable".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    TillBinding.configure(_bound);
    for (final (id, name) in [
      ('outlet-1', 'Kemang'),
      ('outlet-2', 'Bintaro'),
    ]) {
      await db.insert('outlets', {'id': id, 'name': name, 'address': ''});
    }
    for (final (id, outlet) in [
      ('reg-1', 'outlet-1'),
      ('reg-2', 'outlet-1'),
      ('reg-3', 'outlet-2'),
    ]) {
      await db.insert('pos_registers', {
        'id': id,
        'outlet_id': outlet,
        'name': 'Kasir $id',
      });
    }
  });

  tearDown(() async {
    TillBinding.configure(null);
    AppPreferences.resetForTest();
    if (db.isOpen) await db.close();
  });

  Future<void> insertOpenShift(String id, String posId, {String emp = 'e1'}) =>
      db.insert('shifts', {
        'id': id,
        'employee_id': emp,
        'employee_name': 'Siti',
        'pos_id': posId,
        'pos_name': 'Kasir $posId',
        'opened_at': 1757800000000,
        'opening_cash': 0,
      });

  Future<void> sell({String? posId, String? outletId, String? sessionId}) =>
      OrderRepository.instance.create(
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
        posId: posId,
        outletId: outletId,
        posSessionId: sessionId,
      );

  Future<int> count(String table) async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $table'))!;

  group('writes', () {
    test(
      'a session opens on the bound register and carries the bound outlet',
      () async {
        final shift = await ShiftRepository.instance.open(
          employeeId: 'e1',
          employeeName: 'Siti',
          openingCash: 0,
          posId: 'reg-1',
          posName: 'Kasir 1',
        );
        expect(shift.outletId, 'outlet-1');
      },
    );

    test(
      'a session on another register or outlet is refused, nothing written',
      () async {
        for (final open in [
          () => ShiftRepository.instance.open(
            employeeId: 'e1',
            employeeName: 'Siti',
            openingCash: 0,
            posId: 'reg-2',
            posName: 'Kasir 2',
          ),
          () => ShiftRepository.instance.open(
            employeeId: 'e1',
            employeeName: 'Siti',
            openingCash: 0,
            posId: 'reg-1',
            posName: 'Kasir 1',
            outletId: 'outlet-2',
          ),
        ]) {
          await expectLater(open(), throwsA(isA<TillBindingException>()));
        }
        expect(await count('shifts'), 0);
        expect(await count(OutboxStore.table), 0);
      },
    );

    test(
      'a sale is filed under the bound till, filling what was omitted',
      () async {
        await insertOpenShift('s1', 'reg-1');
        await sell(sessionId: 's1');

        final order = (await db.query('orders')).single;
        expect(order['pos_id'], 'reg-1');
        expect(order['outlet_id'], 'outlet-1');
      },
    );

    test(
      'a sale naming another register, outlet or session is refused whole',
      () async {
        await insertOpenShift('s1', 'reg-1');
        await insertOpenShift('s2', 'reg-2', emp: 'e2');

        for (final attempt in [
          () => sell(posId: 'reg-2', sessionId: 's1'),
          () => sell(outletId: 'outlet-2', sessionId: 's1'),
          () => sell(sessionId: 's2'),
          () => sell(),
        ]) {
          await expectLater(attempt(), throwsA(isA<TillBindingException>()));
        }
        expect(await count('orders'), 0);
        expect(await count('order_items'), 0);
        expect(await count(OutboxStore.table), 0);
      },
    );
  });

  group('choices', () {
    ProviderContainer container(Map<String, Object> prefs) {
      AppPreferences.resetForTest();
      SharedPreferences.setMockInitialValues(prefs);
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('the register picker offers only the bound register', () async {
      final c = container({});
      c.listen(activeOutletProvider, (_, _) {});
      await c.read(activeOutletProvider.future);
      c.listen(registerSlotsProvider, (_, _) {});
      final slots = await c.read(registerSlotsProvider.future);
      expect(slots.map((s) => s.register.id), ['reg-1']);
    });

    test('the device stands in the bound outlet whatever was saved', () async {
      final c = container({'outlet_id': 'outlet-2'});
      c.listen(activeOutletProvider, (_, _) {});
      expect((await c.read(activeOutletProvider.future))!.id, 'outlet-1');

      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setOutletId('outlet-2');
      expect(c.read(settingsProvider).value!.outletId, isNot('outlet-2'));
    });

    test('a session on another register is never resumed', () async {
      await insertOpenShift('s2', 'reg-2');
      final c = container({
        'employee_id': 'e1',
        'logged_in': true,
        'pos_session_id': 's2',
      });
      final settings = await c.read(settingsProvider.future);
      expect(settings.posSessionId, isEmpty);

      await insertOpenShift('s1', 'reg-1');
      await c.read(settingsProvider.notifier).refreshPosContext();
      expect(c.read(settingsProvider).value!.posSessionId, 's1');
      expect(c.read(settingsProvider).value!.posRegisterId, 'reg-1');
    });
  });

  test('a queued row on another register is never sent, and kept', () async {
    await insertOpenShift('s-good', 'reg-1');
    await insertOpenShift('s-bad', 'reg-2', emp: 'e2');
    await OutboxStore.enqueueWithin(db, SessionPush.entity, 's-good');
    await OutboxStore.enqueueWithin(db, SessionPush.entity, 's-bad');

    final sentIds = <String>[];
    final client = SyncClient(
      baseUrl: 'https://api.test/api/v2',
      token: 'tok',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final results = <Map<String, Object?>>[];
        final batches = body['batches'] as List;
        for (var b = 0; b < batches.length; b++) {
          final rows = (batches[b] as Map)['rows'] as List;
          for (var r = 0; r < rows.length; r++) {
            final row = rows[r] as Map;
            sentIds.add(row['id'] as String);
            results.add({
              'batch_index': b,
              'row_index': r,
              'entity': (batches[b] as Map)['entity'],
              'id': row['id'],
              'revision': row['revision'],
              'status': 'accepted',
            });
          }
        }
        return http.Response(jsonEncode({'results': results}), 200);
      }),
    );
    addTearDown(client.close);

    await OutboxPush(client).run();

    expect(sentIds, ['s-good']);
    expect(await OutboxStore.instance.count(), 0);
    final letter = (await DeadLetterStore.instance.all()).single;
    expect(letter.entityId, 's-bad');
    expect(letter.code, OutboxPush.registerMismatch);
  });

  test(
    'seeding the binding never overwrites rows a feed already delivered',
    () async {
      // The pos_registers feed renamed the till and turned tables off after the
      // binding in secure storage was written.
      await db.update(
        'pos_registers',
        {'name': 'Kasir Depan', 'table_service': 0},
        where: 'id = ?',
        whereArgs: ['reg-1'],
      );
      await db.update(
        'outlets',
        {'name': 'Kemang Raya'},
        where: 'id = ?',
        whereArgs: ['outlet-1'],
      );

      await seedBindingRows(
        DeviceRegistration(
          baseUrl: 'https://api.test/api/v2',
          token: 'tok',
          expiresAt: DateTime.utc(2030),
          device: {'id': 'device-1'},
          tenant: {'id': 'tenant-1', 'name': 'Warung'},
          outlet: {'id': 'outlet-1', 'name': 'Kemang'},
          register: {
            'id': 'reg-1',
            'outlet_id': 'outlet-1',
            'name': 'Kasir 1',
            'table_service': true,
          },
        ),
      );

      final register = (await db.query(
        'pos_registers',
        where: 'id = ?',
        whereArgs: ['reg-1'],
      )).single;
      expect(register['name'], 'Kasir Depan');
      expect(register['table_service'], 0);
      final outlet = (await db.query(
        'outlets',
        where: 'id = ?',
        whereArgs: ['outlet-1'],
      )).single;
      expect(outlet['name'], 'Kemang Raya');
    },
  );

  test('seeding an empty store writes the bound outlet and register', () async {
    await db.delete('pos_registers');
    await db.delete('outlets');
    await seedBindingRows(
      DeviceRegistration(
        baseUrl: 'https://api.test/api/v2',
        token: 'tok',
        expiresAt: DateTime.utc(2030),
        device: {'id': 'device-1'},
        tenant: {'id': 'tenant-1', 'name': 'Warung'},
        outlet: {'id': 'outlet-1', 'name': 'Kemang', 'address': null},
        register: {
          'id': 'reg-1',
          'outlet_id': 'outlet-1',
          'name': 'Kasir 1',
          'table_service': false,
        },
      ),
    );
    expect((await db.query('outlets')).single['name'], 'Kemang');
    final register = (await db.query('pos_registers')).single;
    expect(register['name'], 'Kasir 1');
    expect(register['table_service'], 0);
  });
}
