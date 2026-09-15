import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/table_repository.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/repositories/modifier_repository.dart';
import 'package:nti_pos/data/repositories/promo_repository.dart';
import 'package:nti_pos/data/sync/outbox_push.dart';
import 'package:nti_pos/data/sync/dead_letter_store.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:nti_pos/data/sync/table_status_push.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _outlet = '11111111-1111-4111-8111-111111111111';
const _register = '22222222-2222-4222-8222-222222222222';
const _table = '44444444-4444-4444-8444-444444444444';

/// The key set of the TableStatusEvent push schema (additionalProperties: false).
const _eventKeys = {
  'id',
  'revision',
  'table_id',
  'status',
  'basis_seq',
  'client_seq',
  'occurred_at_ms',
  'employee_name',
};

/// An activated till's table status: the server's snapshot, unless this till
/// has a newer change of its own the snapshot does not reflect yet.
void main() {
  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    TillBinding.configure(
      const TillBinding(outletId: _outlet, registerId: _register),
    );
    await db.insert('tables', {
      'id': _table,
      'name': 'Meja 1',
      'capacity': 4,
      'floor': 'Lantai 1',
      'outlet_id': _outlet,
    });
  });

  tearDown(() async {
    TillBinding.configure(null);
    if (db.isOpen) await db.close();
  });

  Future<Map<String, Object?>> row([String id = _table]) async =>
      (await db.query('tables', where: 'id = ?', whereArgs: [id])).single;

  Future<String> status() async => (await row())['status'] as String;

  Future<bool> contested() async => (await row())['contested'] == 1;

  Future<void> snapshot(String value, int seq, {bool isContested = false}) =>
      db.transaction(
        (txn) => TableRepository.applyServerStatusWithin(
          txn,
          tableId: _table,
          status: value,
          seq: seq,
          contested: isContested,
        ),
      );

  Future<List<OutboxEntry>> queued() =>
      OutboxStore.instance.pending(entity: TableStatusPush.entity);

  Future<List<Map<String, Object?>>> events() =>
      db.query('table_status_events', orderBy: 'rowid');

  test(
    'a change is an event made against the snapshot the till holds',
    () async {
      await snapshot('available', 3);
      await TableRepository.instance.setStatus(
        _table,
        TableStatus.occupied,
        employeeName: 'Siti',
      );

      expect(await status(), 'occupied');
      final entry = (await queued()).single;
      final payload = jsonDecode(entry.payload!) as Map<String, dynamic>;
      expect(payload.keys.toSet(), _eventKeys);
      expect(payload['table_id'], _table);
      expect(payload['status'], 'occupied');
      expect(payload['basis_seq'], 3);
      expect(payload['employee_name'], 'Siti');
      expect(payload.containsKey('outlet_id'), isFalse);
    },
  );

  test(
    'what the till shows is its newest change the snapshot does not reflect',
    () async {
      await snapshot('available', 3);
      await TableRepository.instance.setStatus(_table, TableStatus.occupied);

      // Another till's change arrives; this till's own is still on its way.
      await snapshot('reserved', 4);
      expect(await status(), 'occupied');

      final id = (await events()).single['id'] as String;
      await TableRepository.instance.markApplied(id, 6, 'applied');
      expect(await status(), 'occupied', reason: 'snapshot 4 still lacks it');

      await snapshot('occupied', 6, isContested: true);
      expect(await status(), 'occupied');
      expect(await contested(), isTrue);

      // An older snapshot arriving late changes nothing.
      await snapshot('available', 5);
      expect(await status(), 'occupied');
      expect(await contested(), isTrue);
    },
  );

  test('a change that lost stops showing once the server says so', () async {
    await snapshot('available', 3);
    await TableRepository.instance.setStatus(_table, TableStatus.reserved);
    final id = (await events()).single['id'] as String;

    await snapshot('occupied', 5);
    expect(await status(), 'reserved', reason: 'still pending');

    await TableRepository.instance.markApplied(id, 6, 'superseded');
    expect(await status(), 'occupied');

    await snapshot('occupied', 6, isContested: true);
    expect(await status(), 'occupied');
    expect(await contested(), isTrue);
  });

  test(
    'an acceptance without status_seq and outcome keeps the event; with both, settles it',
    () async {
      await snapshot('available', 1);
      await TableRepository.instance.setStatus(_table, TableStatus.occupied);

      var complete = false;
      final client = SyncClient(
        baseUrl: 'https://api.test/api/v2',
        token: 'tok',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final results = <Map<String, Object?>>[];
          final batches = body['batches'] as List;
          for (var b = 0; b < batches.length; b++) {
            final batch = batches[b] as Map<String, dynamic>;
            final rows = batch['rows'] as List;
            for (var r = 0; r < rows.length; r++) {
              final row = rows[r] as Map<String, dynamic>;
              results.add({
                'batch_index': b,
                'row_index': r,
                'entity': batch['entity'],
                'id': row['id'],
                'revision': row['revision'],
                'status': 'accepted',
                if (complete) 'status_seq': 2,
                if (complete) 'outcome': 'applied',
              });
            }
          }
          return http.Response(jsonEncode({'results': results}), 200);
        }),
      );
      addTearDown(client.close);

      await OutboxPush(client).run();
      expect(await queued(), hasLength(1));
      expect((await events()).single['server_seq'], isNull);

      complete = true;
      await OutboxPush(client).run();
      expect(await queued(), isEmpty);
      final event = (await events()).single;
      expect(event['server_seq'], 2);
      expect(event['outcome'], 'applied');
      expect(await status(), 'occupied');
    },
  );

  test('changes go up oldest first, however often one was retried', () async {
    await snapshot('available', 1);
    for (final s in [
      TableStatus.occupied,
      TableStatus.available,
      TableStatus.reserved,
    ]) {
      await TableRepository.instance.setStatus(_table, s);
    }

    final first = (await queued()).first;
    await OutboxStore.instance.recordFailure(first.entity, first.entityId, 'x');
    await OutboxStore.instance.recordFailure(first.entity, first.entityId, 'x');

    final order = [
      for (final e in await queued())
        (jsonDecode(e.payload!) as Map<String, dynamic>)['status'],
    ];
    expect(order, ['occupied', 'available', 'reserved']);
  });

  test('a change at another branch is never sent', () async {
    const other = '55555555-5555-4555-8555-555555555555';
    await db.insert('tables', {
      'id': other,
      'name': 'Meja X',
      'capacity': 2,
      'outlet_id': 'another-outlet',
    });
    await expectLater(
      TableRepository.instance.setStatus(other, TableStatus.occupied),
      throwsA(isA<TillBindingException>()),
    );

    var requests = 0;
    final client = SyncClient(
      baseUrl: 'https://api.test/api/v2',
      token: 'tok',
      client: MockClient((_) async {
        requests++;
        return http.Response('{"results":[]}', 200);
      }),
    );
    addTearDown(client.close);

    await OutboxPush(client).run();
    expect(requests, 0);
    expect(await queued(), isEmpty);
    final letters = await db.query('_dead_letter');
    expect(letters, isEmpty);
  });

  test(
    'a table made up on this device changes locally and never goes up',
    () async {
      const local = 'table_1757800000000';
      await db.insert('tables', {
        'id': local,
        'name': 'Meja Lokal',
        'capacity': 2,
        'outlet_id': _outlet,
      });
      await TableRepository.instance.setStatus(local, TableStatus.occupied);
      expect((await row(local))['status'], 'occupied');
      expect(await queued(), isEmpty);
    },
  );

  test('the demo writes the status and queues nothing', () async {
    TillBinding.configure(null);
    await TableRepository.instance.setStatus(_table, TableStatus.reserved);
    expect(await status(), 'reserved');
    expect(await events(), isEmpty);
    expect(await queued(), isEmpty);
  });

  test('connected master data cannot be deleted from local editors', () async {
    await expectLater(
      TableRepository.instance.delete(_table),
      throwsStateError,
    );
    await expectLater(
      ModifierRepository.instance.deleteGroup('group'),
      throwsStateError,
    );
    await expectLater(
      PromoRepository.instance.delete('promo'),
      throwsStateError,
    );
    expect(await row(), isNotEmpty);
  });

  test('checkout and its table event commit or roll back together', () async {
    await snapshot('available', 1);
    final shift = await ShiftRepository.instance.open(
      employeeId: 'e1',
      employeeName: 'Siti',
      openingCash: 0,
      posId: _register,
      posName: 'Kasir 1',
    );
    Future<void> sell() => OrderRepository.instance.create(
      type: OrderType.dineIn,
      items: const [
        OrderItemDraft(
          productId: 'p1',
          productName: 'Teh',
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
      posId: _register,
      posSessionId: shift.id,
      tableId: _table,
      tableName: 'Meja 1',
    );
    await db.execute(
      "CREATE TRIGGER reject_test_event BEFORE INSERT ON table_status_events BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    );
    await expectLater(sell(), throwsA(anything));
    expect(await db.query('orders'), isEmpty);
    expect(await events(), isEmpty);
    expect(await queued(), isEmpty);
    expect(await status(), 'available');
    await db.execute('DROP TRIGGER reject_test_event');
    await sell();
    expect(await db.query('orders'), hasLength(1));
    expect(await queued(), hasLength(1));
    expect(await status(), 'occupied');
  });

  test(
    'rejection removes the optimistic overlay but preserves recovery',
    () async {
      await snapshot('available', 1);
      await TableRepository.instance.setStatus(_table, TableStatus.occupied);
      final sent = (await queued()).single;
      await DeadLetterStore.instance.moveFromOutbox(
        sent,
        code: 'schema_rejected',
      );
      expect(await status(), 'available');
      expect(await events(), hasLength(1));
      expect(await DeadLetterStore.instance.count(), 1);
      await DeadLetterStore.instance.requeueAll();
      expect(await status(), 'occupied');
      expect(await queued(), hasLength(1));
    },
  );

  test('local event order survives a clock correction', () async {
    await snapshot('available', 1);
    await TableRepository.instance.setStatus(_table, TableStatus.occupied);
    await db.update('table_status_events', {'created_at': 9000000000000});
    await TableRepository.instance.setStatus(_table, TableStatus.reserved);
    final pending = await events();
    final seqs = [for (final e in pending) e['client_seq'] as int];
    expect(seqs[1], greaterThan(seqs[0]));
    await snapshot('available', 2);
    expect(
      await status(),
      'reserved',
      reason: 'client sequence, not wall clock',
    );
  });

  test(
    'a store that starts empty numbers its changes above an earlier store',
    () async {
      // The server keeps every number a device ever sent. A reinstall that
      // keeps the installation id comes back as the same device with an empty
      // store, and restarting at 1 would be refused as a duplicate.
      final before = DateTime.now().millisecondsSinceEpoch;
      await snapshot('available', 1);
      await TableRepository.instance.setStatus(_table, TableStatus.occupied);
      await TableRepository.instance.setStatus(_table, TableStatus.available);

      final seqs = [for (final e in await events()) e['client_seq'] as int];
      expect(seqs.first, greaterThanOrEqualTo(before));
      expect(seqs.last, greaterThan(seqs.first));
    },
  );
}
