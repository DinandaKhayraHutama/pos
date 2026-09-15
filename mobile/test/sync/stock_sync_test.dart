import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/stock_movement.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/stock_repository.dart';
import 'package:nti_pos/data/sync/outbox_push.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/stock_movement_push.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _outlet = '11111111-1111-4111-8111-111111111111';
const _register = '22222222-2222-4222-8222-222222222222';
const _product = '33333333-3333-4333-8333-333333333333';

/// The key set of the StockMovement push schema (additionalProperties: false).
const _movementKeys = {
  'id',
  'revision',
  'product_id',
  'product_name',
  'reason',
  'delta_qty',
  'counted_qty',
  'basis_seq',
  'occurred_at_ms',
  'employee_id',
  'employee_name',
  'note',
};

/// An activated till's stock: the server snapshot plus this till's movements
/// the snapshot does not include yet.
void main() {
  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    TillBinding.configure(
      const TillBinding(outletId: _outlet, registerId: _register),
    );
    await db.insert('categories', {'id': 'c1', 'name': 'Minuman'});
    await db.insert('products', {
      'id': _product,
      'name': 'Es Teh',
      'category_id': 'c1',
      'price': 5000,
    });
    await db.insert('shifts', {
      'id': 's1',
      'employee_id': 'e1',
      'employee_name': 'Siti',
      'pos_id': _register,
      'pos_name': 'Kasir 1',
      'outlet_id': _outlet,
      'opened_at': 1757800000000,
      'opening_cash': 0,
    });
  });

  tearDown(() async {
    TillBinding.configure(null);
    if (db.isOpen) await db.close();
  });

  Future<int?> stock() =>
      StockRepository.countAt(db, outletId: _outlet, productId: _product);

  Future<void> snapshot(int qty, int seq) => db.transaction(
    (txn) => StockRepository.applyServerSnapshotWithin(
      txn,
      outletId: _outlet,
      productId: _product,
      qty: qty,
      seq: seq,
    ),
  );

  Future<void> sell(int qty) => OrderRepository.instance.create(
    type: OrderType.takeaway,
    items: [
      OrderItemDraft(
        productId: _product,
        productName: 'Es Teh',
        unitPrice: 5000,
        quantity: qty,
      ),
    ],
    subtotal: 5000 * qty,
    discount: 0,
    tax: 0,
    total: 5000 * qty,
    amountPaid: 5000 * qty,
    paymentMethod: PaymentMethod.cash,
    cashierId: 'e1',
    cashierName: 'Siti',
    posSessionId: 's1',
  );

  Future<List<OutboxEntry>> queuedMovements() =>
      OutboxStore.instance.pending(entity: StockMovementPush.entity);

  Future<String> onlyMovementId() async =>
      (await db.query('stock_movements')).single['id'] as String;

  test(
    'an untracked product moves nothing until the server tracks it',
    () async {
      await sell(1);
      expect(await stock(), isNull);
      expect(await db.query('stock_movements'), isEmpty);
      expect(await queuedMovements(), isEmpty);

      await snapshot(20, 1);
      expect(await stock(), 20);
    },
  );

  test(
    'a sale is a queued movement, and a shortfall is recorded, not floored',
    () async {
      await snapshot(1, 1);
      await sell(3);

      expect(await stock(), -2);
      final entry = (await queuedMovements()).single;
      final payload = jsonDecode(entry.payload!) as Map<String, dynamic>;
      expect(payload.keys.toSet(), _movementKeys);
      expect(payload['reason'], 'sale');
      expect(payload['delta_qty'], -3);
      expect(payload['product_id'], _product);
      expect(payload['counted_qty'], isNull);
      expect(payload['employee_id'], isNull, reason: 'e1 is not a UUID');
      expect(payload.containsKey('outlet_id'), isFalse);
    },
  );

  test(
    'what the till shows is the snapshot plus what it does not include',
    () async {
      await snapshot(20, 5);
      await sell(2);
      expect(await stock(), 18);

      // Another till sold one; this till's two are not in that snapshot yet.
      await snapshot(19, 6);
      expect(await stock(), 17);

      // The server applied this till's sale at projection sequence 8.
      await StockRepository.instance.markApplied(await onlyMovementId(), 8);
      expect(await stock(), 17, reason: 'snapshot 6 still lacks it');

      // Snapshot 8 includes it: counted once, not twice.
      await snapshot(17, 8);
      expect(await stock(), 17);

      await snapshot(16, 9);
      expect(await stock(), 16);

      // An older snapshot arriving late changes nothing.
      await snapshot(30, 7);
      expect(await stock(), 16);
    },
  );

  test(
    'a movement pulled from elsewhere is history, not a pending delta',
    () async {
      await snapshot(10, 3);
      await db.transaction(
        (txn) => StockRepository.applyServerMovementWithin(txn, {
          'id': '44444444-4444-4444-8444-444444444444',
          'outlet_id': _outlet,
          'product_id': _product,
          'product_name': 'Es Teh',
          'reason': 'transferIn',
          'delta_qty': 4,
          'counted_qty': null,
          'balance_after': 10,
          'occurred_at_ms': 1757800000000,
          'employee_name': 'Owner',
          'note': null,
          'source': 'backoffice',
          'stock_seq': 3,
          'sync_seq': 1,
          'deleted_at_ms': null,
        }),
      );
      expect(await stock(), 10);
      final history = await StockRepository.instance.history(
        outletId: _outlet,
        productId: _product,
      );
      expect(history.single.reason, StockReason.transferIn);
      expect(await queuedMovements(), isEmpty);
    },
  );

  test(
    'this till\'s own movement pulled back is settled by the pull',
    () async {
      await snapshot(10, 3);
      await sell(1);
      final id = await onlyMovementId();

      // The push response was lost, but the snapshot and the movement feed
      // already say the server applied it at sequence 4.
      await snapshot(9, 4);
      expect(await stock(), 8, reason: 'not yet known to be inside snapshot 4');
      await db.transaction(
        (txn) => StockRepository.applyServerMovementWithin(txn, {
          'id': id,
          'outlet_id': _outlet,
          'product_id': _product,
          'product_name': 'Es Teh',
          'reason': 'sale',
          'delta_qty': -1,
          'counted_qty': null,
          'balance_after': 9,
          'occurred_at_ms': 1757800000000,
          'employee_name': 'Siti',
          'note': null,
          'source': 'device',
          'stock_seq': 4,
          'sync_seq': 2,
          'deleted_at_ms': null,
        }),
      );
      expect(await stock(), 9);
    },
  );

  test(
    'a count sends what was counted and the snapshot it was counted against',
    () async {
      await snapshot(10, 4);
      final balance = await StockRepository.instance.count(
        outletId: _outlet,
        productId: _product,
        countedQty: 7,
        employeeId: 'e1',
        employeeName: 'Siti',
      );
      expect(balance, 7);
      expect(await stock(), 7);

      final payload =
          jsonDecode((await queuedMovements()).single.payload!)
              as Map<String, dynamic>;
      expect(payload['reason'], 'count');
      expect(payload['counted_qty'], 7);
      expect(payload['basis_seq'], 4);
      expect(payload['delta_qty'], -3);
    },
  );

  test(
    'an acceptance without stock_seq keeps the movement; with it, settles',
    () async {
      await snapshot(5, 1);
      await sell(1);
      final id = await onlyMovementId();

      var withSeq = false;
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
                if (withSeq && batch['entity'] == 'stock_movements')
                  'stock_seq': 2,
              });
            }
          }
          return http.Response(jsonEncode({'results': results}), 200);
        }),
      );
      addTearDown(client.close);

      await OutboxPush(client).run();
      expect(await queuedMovements(), hasLength(1));
      expect((await db.query('stock_movements')).single['server_seq'], isNull);

      withSeq = true;
      await OutboxPush(client).run();
      expect(await queuedMovements(), isEmpty);
      final row = (await db.query(
        'stock_movements',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(row['server_seq'], 2);
      expect(await stock(), 4);
    },
  );

  test('a movement for another branch is never sent', () async {
    await db.insert('outlet_stock', {
      'outlet_id': 'another-outlet',
      'product_id': _product,
      'stock': 5,
    });
    await db.transaction(
      (txn) => StockRepository.writeMovementWithin(
        txn,
        outletId: 'another-outlet',
        productId: _product,
        productName: 'Es Teh',
        delta: -1,
        balanceAfter: 4,
        reason: StockReason.waste,
        employeeId: 'e1',
        employeeName: 'Siti',
      ),
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
    expect(await queuedMovements(), isEmpty);
    final letters = await db.query('_dead_letter');
    expect(letters.single['code'], OutboxPush.registerMismatch);
  });

  test('the demo keeps its floor at zero and queues nothing', () async {
    TillBinding.configure(null);
    await db.insert('outlet_stock', {
      'outlet_id': _outlet,
      'product_id': _product,
      'stock': 2,
    });
    final balance = await StockRepository.instance.adjust(
      outletId: _outlet,
      productId: _product,
      delta: -5,
      reason: StockReason.waste,
      employeeId: 'e1',
      employeeName: 'Siti',
    );
    expect(balance, 0);
    expect(await queuedMovements(), isEmpty);
  });

  test(
    'a pending count sets the count; only later movements add to it',
    () async {
      await snapshot(20, 1);
      await StockRepository.instance.count(
        outletId: _outlet,
        productId: _product,
        countedQty: 12,
        employeeId: 'e1',
        employeeName: 'Siti',
      );
      // Another till's sales reach the server before this count does.
      await snapshot(18, 3);
      expect(await stock(), 12, reason: 'the count is what is on the shelf');

      await sell(1);
      expect(await stock(), 11);

      // The server applied the count (as 12 - 18 = -6) at sequence 4, and the
      // sale at 5; a snapshot at 5 includes both.
      final ids = [
        for (final r in await db.query('stock_movements', orderBy: 'rowid'))
          r['id'] as String,
      ];
      await StockRepository.instance.markApplied(ids[0], 4);
      await StockRepository.instance.markApplied(ids[1], 5);
      expect(await stock(), 11);
      await snapshot(11, 5);
      expect(await stock(), 11);
    },
  );
}
