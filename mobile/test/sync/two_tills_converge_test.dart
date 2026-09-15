import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/device_registration.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/stock_repository.dart';
import 'package:nti_pos/data/sync/device_sync_runner.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _outlet = '11111111-1111-4111-8111-111111111111';
const _product = '33333333-3333-4333-8333-333333333333';

/// A server with the stock ledger's semantics: deltas applied in arrival
/// order, a projection sequence per change, exact retries answered with what
/// was first recorded, and outlet feeds paged by sequence.
class _LedgerServer {
  int qty = 0;
  int stockSeq = 0;
  int movementSeq = 0;
  final movements = <String, Map<String, dynamic>>{};

  /// When set, the next push is applied but its response never arrives.
  bool loseNextResponse = false;

  void opening(int quantity) {
    qty = quantity;
    stockSeq++;
    movementSeq++;
    movements['55555555-5555-4555-8555-555555555555'] = {
      'id': '55555555-5555-4555-8555-555555555555',
      'outlet_id': _outlet,
      'product_id': _product,
      'product_name': 'Es Teh',
      'reason': 'received',
      'delta_qty': quantity,
      'counted_qty': null,
      'balance_after': quantity,
      'occurred_at_ms': 1757800000000,
      'employee_name': 'Owner',
      'note': null,
      'source': 'backoffice',
      'stock_seq': stockSeq,
      'sync_seq': movementSeq,
      'deleted_at_ms': null,
    };
  }

  http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

  http.Client get client => MockClient((request) async {
    switch (request.url.path) {
      case '/api/v2/sync/manifest':
        return _json({
          'schema_version': 1,
          'entities': [
            {
              'name': 'outlet_stock',
              'scope': 'outlet',
              'key': ['outlet_id', 'product_id'],
              'depends_on': <String>[],
              'pull': true,
              'push': false,
              'apply': 'upsert',
            },
            {
              'name': 'stock_movements',
              'scope': 'outlet',
              'key': ['id'],
              'depends_on': <String>[],
              'pull': true,
              'push': true,
              'apply': 'upsert',
            },
          ],
        });
      case '/api/v2/sync/pull':
        final entity = request.url.queryParameters['entity']!;
        final after = int.parse(request.url.queryParameters['after_seq']!);
        if (entity == 'outlet_stock') {
          return _json({
            'entity': entity,
            'rows': [
              if (stockSeq > after)
                {
                  'outlet_id': _outlet,
                  'product_id': _product,
                  'qty_on_hand': qty,
                  'sync_seq': stockSeq,
                  'deleted_at_ms': null,
                },
            ],
            'next_seq': stockSeq > after ? stockSeq : after,
            'has_more': false,
            'schema_version': 1,
          });
        }
        final rows =
            movements.values
                .where((m) => (m['sync_seq'] as int) > after)
                .toList()
              ..sort(
                (a, b) =>
                    (a['sync_seq'] as int).compareTo(b['sync_seq'] as int),
              );
        return _json({
          'entity': entity,
          'rows': rows,
          'next_seq': movementSeq,
          'has_more': false,
          'schema_version': 1,
        });
      case '/api/v2/sync/push':
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final results = <Map<String, Object?>>[];
        final batches = body['batches'] as List;
        for (var b = 0; b < batches.length; b++) {
          final batch = batches[b] as Map<String, dynamic>;
          final rows = batch['rows'] as List;
          for (var r = 0; r < rows.length; r++) {
            final row = rows[r] as Map<String, dynamic>;
            final result = <String, Object?>{
              'batch_index': b,
              'row_index': r,
              'entity': batch['entity'],
              'id': row['id'],
              'revision': row['revision'],
              'status': 'accepted',
            };
            if (batch['entity'] == 'stock_movements') {
              result['stock_seq'] = _apply(row);
            }
            results.add(result);
          }
        }
        if (loseNextResponse) {
          loseNextResponse = false;
          return http.Response('{"error":{"code":"gateway"}}', 502);
        }
        return _json({'results': results, 'server_time_ms': 1757800000000});
    }
    return http.Response('{"error":{"code":"not_found"}}', 404);
  });

  int _apply(Map<String, dynamic> row) {
    final id = row['id'] as String;
    final seen = movements[id];
    if (seen != null) return seen['stock_seq'] as int;
    final delta = row['reason'] == 'count'
        ? (row['counted_qty'] as int) - qty
        : row['delta_qty'] as int;
    qty += delta;
    stockSeq++;
    movementSeq++;
    movements[id] = {
      'id': id,
      'outlet_id': _outlet,
      'product_id': row['product_id'],
      'product_name': row['product_name'],
      'reason': row['reason'],
      'delta_qty': delta,
      'counted_qty': row['counted_qty'],
      'balance_after': qty,
      'occurred_at_ms': row['occurred_at_ms'],
      'employee_name': row['employee_name'],
      'note': row['note'],
      'source': 'device',
      'stock_seq': stockSeq,
      'sync_seq': movementSeq,
      'deleted_at_ms': null,
    };
    return stockSeq;
  }
}

class _Till {
  _Till(this.name, this.path, this.registerId);
  final String name;
  final String path;
  final String registerId;

  TillBinding get binding =>
      TillBinding(outletId: _outlet, registerId: registerId);
}

/// The Fase 5 gate, on the client side: two tills in one outlet sell the same
/// item offline, push in either order — one losing its push response — and
/// both land on the outlet's true quantity, which is the server's.
void main() {
  late Directory dir;
  late _LedgerServer server;
  late _Till tillA;
  late _Till tillB;

  setUpAll(initFfi);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('two_tills_');
    server = _LedgerServer()..opening(20);
    tillA = _Till(
      'a',
      '${dir.path}/a.db',
      '66666666-6666-4666-8666-666666666666',
    );
    tillB = _Till(
      'b',
      '${dir.path}/b.db',
      '77777777-7777-4777-8777-777777777777',
    );
  });

  // The till whose store is open. sqflite hands back the SAME connection for a
  // path that is already open, so switching to the till already in use must
  // not reopen — closing the "previous" handle would close the current one.
  _Till? current;
  Database? open;

  tearDown(() async {
    TillBinding.configure(null);
    if (open != null && open!.isOpen) await open!.close();
    open = null;
    current = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> use(_Till till) async {
    TillBinding.configure(till.binding);
    if (identical(current, till) && open != null && open!.isOpen) return;
    if (open != null && open!.isOpen) await open!.close();
    open = await AppDatabase.openForTest(path: till.path, seed: false);
    await AppDatabase.instance.useTestDb(open!);
    current = till;
  }

  Future<void> prepare(_Till till) async {
    await use(till);
    final db = await AppDatabase.instance.db;
    await db.insert('categories', {'id': 'c1', 'name': 'Minuman'});
    await db.insert('products', {
      'id': _product,
      'name': 'Es Teh',
      'category_id': 'c1',
      'price': 5000,
    });
    await db.insert('shifts', {
      'id': 'shift-${till.name}',
      'employee_id': 'e-${till.name}',
      'employee_name': 'Kasir ${till.name}',
      'pos_id': till.registerId,
      'pos_name': 'Kasir ${till.name}',
      'outlet_id': _outlet,
      'opened_at': 1757800000000,
      'opening_cash': 0,
    });
  }

  Future<SyncOutcome?> sync(_Till till) async {
    await use(till);
    final client = SyncClient(
      baseUrl: 'https://api.test/api/v2',
      token: 'tok-${till.name}',
      client: server.client,
    );
    final runner = DeviceSyncRunner(
      binding: DeviceRegistration(
        baseUrl: 'https://api.test/api/v2',
        token: 'tok-${till.name}',
        expiresAt: DateTime.utc(2030),
        device: {'id': 'device-${till.name}'},
        tenant: {'id': 'tenant', 'name': 'Warung'},
        outlet: {'id': _outlet, 'name': 'Kemang'},
        register: {
          'id': till.registerId,
          'outlet_id': _outlet,
          'name': 'Kasir ${till.name}',
          'table_service': false,
        },
      ),
      client: client,
    );
    final outcome = await runner.syncNow(full: true);
    runner.close();
    return outcome;
  }

  Future<void> sellOffline(_Till till, int times) async {
    await use(till);
    for (var i = 0; i < times; i++) {
      await OrderRepository.instance.create(
        type: OrderType.takeaway,
        items: const [
          OrderItemDraft(
            productId: _product,
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
        cashierId: 'e-${till.name}',
        cashierName: 'Kasir ${till.name}',
        posSessionId: 'shift-${till.name}',
      );
    }
  }

  Future<int?> stockAt(_Till till) async {
    await use(till);
    return StockRepository.countAt(
      await AppDatabase.instance.db,
      outletId: _outlet,
      productId: _product,
    );
  }

  test('two offline tills converge on the outlet quantity', () async {
    await prepare(tillA);
    await prepare(tillB);
    await sync(tillA);
    await sync(tillB);
    expect(await stockAt(tillA), 20);
    expect(await stockAt(tillB), 20);

    // An hour offline: fifteen sales each, of the same item.
    await sellOffline(tillA, 15);
    await sellOffline(tillB, 15);
    expect(await stockAt(tillA), 5);
    expect(await stockAt(tillB), 5);

    // Till A reconnects first; the server applies its sales but the response
    // is lost on the way back.
    server.loseNextResponse = true;
    await sync(tillA);
    expect(server.qty, 5);
    expect(await stockAt(tillA), 5, reason: 'nothing it can trust arrived');

    // Till B syncs: it pulls A's sales, pushes its own.
    await sync(tillB);
    expect(server.qty, -10);
    expect(await stockAt(tillB), -10);

    // Till A syncs again: its pull settles its own sales, its retry is exact.
    await sync(tillA);
    expect(await stockAt(tillA), -10);
    await use(tillA);
    expect(
      await OutboxStore.instance.pending(entity: 'stock_movements'),
      isEmpty,
    );

    // Till B polls once more and still agrees.
    await sync(tillB);
    expect(await stockAt(tillB), -10);

    expect(server.qty, -10, reason: 'the centre sees the same number');
    expect(server.movements, hasLength(31), reason: 'retries created nothing');
  });

  test('a count taken on one till converges on both', () async {
    await prepare(tillA);
    await prepare(tillB);
    await sync(tillA);
    await sync(tillB);

    await sellOffline(tillB, 2);
    await use(tillA);
    await StockRepository.instance.count(
      outletId: _outlet,
      productId: _product,
      countedQty: 12,
      employeeId: 'e-a',
      employeeName: 'Kasir a',
    );

    // B's sales arrive first; A's count is then taken against 18, not 20.
    await sync(tillB);
    await sync(tillA);
    await sync(tillB);

    expect(server.qty, 12);
    expect(await stockAt(tillA), 12);
    expect(await stockAt(tillB), 12);
  });
}
