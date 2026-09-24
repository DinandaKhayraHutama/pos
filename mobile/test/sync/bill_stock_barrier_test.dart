import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/models/bill.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/bill_repository.dart';
import 'package:nti_pos/data/repositories/stock_repository.dart';
import 'package:nti_pos/data/sync/outbox_push.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _outlet = '11111111-1111-4111-8111-111111111111';
const _register = '22222222-2222-4222-8222-222222222222';
const _session = '33333333-3333-4333-8333-333333333333';
const _nasi = '44444444-4444-4444-8444-444444444444';

/// A stock count (opname) keeps its place among everything that moves stock,
/// whatever row carries the movement (paritas F4).
///
/// The server turns a count into a delta against its own quantity when the
/// count ARRIVES. A dispatch made before the count must reach the server
/// before it, or the count absorbs it and the dispatch then takes the shelf
/// below what was counted; one made after must follow it. Since Fase 4 a
/// dispatch carries its movements inside its own row, so ordering the
/// stock_movements feed among itself is no longer enough.
void main() {
  late Database db;
  final requests = <List<({String entity, String kind})>>[];

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    TillBinding.configure(
      const TillBinding(outletId: _outlet, registerId: _register),
    );
    requests.clear();
    await db.insert('outlets', {'id': _outlet, 'name': 'Bintaro'});
    await db.insert('categories', {'id': 'cat', 'name': 'Makanan'});
    await db.insert('products', {
      'id': _nasi,
      'category_id': 'cat',
      'name': 'Nasi',
      'price': 25000,
      'emoji': '',
    });
    await db.insert('outlet_stock', {
      'outlet_id': _outlet,
      'product_id': _nasi,
      'stock': 10,
    });
    await db.insert('shifts', {
      'id': _session,
      'employee_id': 'e1',
      'employee_name': 'Siti',
      'opened_at': DateTime.now().millisecondsSinceEpoch,
      'opening_cash': 0,
      'pos_id': _register,
      'pos_name': 'Kasir 1',
      'outlet_id': _outlet,
    });
  });

  tearDown(() async {
    TillBinding.configure(null);
    if (db.isOpen) await db.close();
  });

  /// Accepts everything, answering a stock movement with the sequence it needs
  /// to be settled, and records what each request carried.
  SyncClient server() => SyncClient(
    baseUrl: 'https://pos.test/api/v2',
    token: 't',
    client: MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final seen = <({String entity, String kind})>[];
      final results = <Map<String, Object?>>[];
      final batches = body['batches'] as List;
      for (var b = 0; b < batches.length; b++) {
        final batch = batches[b] as Map<String, dynamic>;
        final entity = batch['entity'] as String;
        final rows = batch['rows'] as List;
        for (var r = 0; r < rows.length; r++) {
          final row = rows[r] as Map<String, dynamic>;
          seen.add((entity: entity, kind: (row['reason'] ?? '') as String));
          results.add({
            'batch_index': b,
            'row_index': r,
            'entity': entity,
            'id': row['id'],
            'revision': row['revision'],
            'status': 'accepted',
            if (entity == 'stock_movements') 'stock_seq': requests.length + 1,
          });
        }
      }
      requests.add(seen);
      return http.Response(
        jsonEncode({'results': results, 'server_time_ms': 1757800000000}),
        200,
      );
    }),
  );

  BillDraft draft({String? billId, required int qty}) => BillDraft(
    billId: billId,
    type: OrderType.dineIn.wire,
    pricing: const BillPricing(version: 1),
    lines: [
      BillLineDraft(
        productId: _nasi,
        productName: 'Nasi',
        unitPrice: 25000,
        quantity: qty,
      ),
    ],
    cashierId: 'e1',
    cashierName: 'Siti',
    outletId: _outlet,
    posId: _register,
    posName: 'Kasir 1',
    posSessionId: _session,
  );

  Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 3));

  List<String> stockRows(List<({String entity, String kind})> request) => [
    for (final row in request)
      if (row.entity == 'kitchen_dispatches' || row.entity == 'stock_movements')
        row.entity == 'stock_movements' ? row.kind : 'dispatch',
  ];

  test('dispatch, count, dispatch reach the server in the order they happened', () async {
    await BillRepository.instance.saveAndDispatch(draft(qty: 1));
    await tick();
    await StockRepository.instance.count(
      outletId: _outlet,
      productId: _nasi,
      countedQty: 7,
      employeeId: 'e1',
      employeeName: 'Siti',
    );
    await tick();
    await BillRepository.instance.saveAndDispatch(draft(qty: 2));

    final report = await OutboxPush(server()).run();

    expect(report.remaining, 0);
    final order = [for (final r in requests) stockRows(r)];
    expect(order, [
      ['dispatch'],
      ['count'],
      ['dispatch'],
    ]);
    // Rows that move no stock were never held back: both bills went first.
    expect(
      requests.first.where((r) => r.entity == 'bills'),
      hasLength(2),
    );
  });

  test('a count with nothing before it goes alone, and what follows waits', () async {
    await StockRepository.instance.count(
      outletId: _outlet,
      productId: _nasi,
      countedQty: 9,
      employeeId: 'e1',
      employeeName: 'Siti',
    );
    await tick();
    await BillRepository.instance.saveAndDispatch(draft(qty: 1));

    await OutboxPush(server()).run();

    expect([for (final r in requests) stockRows(r)], [
      ['count'],
      ['dispatch'],
    ]);
  });

  test('with no count pending nothing is held', () async {
    await BillRepository.instance.saveAndDispatch(draft(qty: 1));
    await BillRepository.instance.saveAndDispatch(draft(qty: 1));

    await OutboxPush(server()).run();

    expect(requests, hasLength(1));
    expect(stockRows(requests.single), ['dispatch', 'dispatch']);
    expect(await OutboxStore.instance.count(), 0);
  });
}
