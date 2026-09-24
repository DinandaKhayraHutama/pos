import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _f4Tables = [
  'bill_lines',
  'kitchen_dispatches',
  'bills',
  'table_sessions',
  '_bill_board',
];

const _f4Columns = {
  '_outbox': ['last_queued_at'],
  'stock_movements': ['source_kind', 'source_id'],
  'orders': ['bill_id'],
  'order_items': ['bill_line_id'],
};

Set<String> _columns(List<Map<String, Object?>> info) => {
  for (final row in info) row['name']! as String,
};

/// The v33 upgrade (paritas F4) on a real file: a v32 till holding an unsent
/// sale, a refused row and its stock movement comes out with every saved-bill
/// table and column, and with every row it went in with — the sale still a
/// receipt that settles no bill.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v32 → v33 adds saved bills and keeps the queue and the ledger', () async {
    await initFfi();
    final dir = await Directory.systemTemp.createTemp('nti_pos_v32_');
    final path = '${dir.path}${Platform.pathSeparator}v32.db';
    addTearDown(() async {
      await deleteDatabase(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    // Built at v32 by taking the Fase 4 additions back off today's schema —
    // exactly the shape a v32 install has on disk.
    var db = await AppDatabase.openForTest(path: path, version: 32, seed: false);
    for (final table in _f4Tables) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
    for (final entry in _f4Columns.entries) {
      for (final column in entry.value) {
        await db.execute('ALTER TABLE ${entry.key} DROP COLUMN $column');
      }
    }

    await db.insert('orders', {
      'id': 'o1',
      'number': 'K1-000001',
      'created_at': 1758326400000,
      'type': 'dineIn',
      'subtotal': 25000,
      'discount': 0,
      'tax': 2500,
      'total': 27500,
      'amount_paid': 30000,
      'payment_method': 'cash',
      'status': 'preparing',
      'cashier_id': 'e1',
      'cashier_name': 'Siti',
    });
    await db.insert('order_items', {
      'id': 'i1',
      'order_id': 'o1',
      'product_id': 'p1',
      'product_name': 'Nasi Goreng',
      'unit_price': 25000,
      'quantity': 1,
    });
    await db.insert('stock_movements', {
      'id': 'm1',
      'outlet_id': 'out1',
      'product_id': 'p1',
      'product_name': 'Nasi Goreng',
      'delta': -1,
      'balance_after': 9,
      'reason': 'sale',
      'created_at': 1758326400000,
      'order_id': 'o1',
    });
    await db.insert('_outbox', {
      'entity': 'orders',
      'entity_id': 'o1',
      'queued_at': 1,
      'attempts': 2,
      'revision': 1,
      'payload': '{"id":"o1","revision":1}',
    });
    await db.insert('_dead_letter', {
      'entity': 'orders',
      'entity_id': 'o0',
      'revision': 1,
      'payload': '{"id":"o0"}',
      'code': 'schema_rejected',
      'rejected_at': 2,
    });
    await db.close();

    db = await AppDatabase.openForTest(path: path, seed: false);
    addTearDown(db.close);

    for (final table in _f4Tables) {
      expect(await db.query(table), isEmpty, reason: '$table exists, empty');
    }
    for (final entry in _f4Columns.entries) {
      expect(
        _columns(await db.rawQuery('PRAGMA table_info(${entry.key})')),
        containsAll(entry.value),
        reason: entry.key,
      );
    }

    // The unsent sale is still owed, byte for byte, and still a receipt of no
    // bill; its queue entry keeps its age and attempts.
    final queued = (await db.query('_outbox')).single;
    expect(queued['payload'], '{"id":"o1","revision":1}');
    expect(queued['attempts'], 2);
    expect(queued['last_queued_at'], isNull);
    expect((await db.query('_dead_letter')).single['code'], 'schema_rejected');
    final order = (await db.query('orders')).single;
    expect(order['bill_id'], isNull);
    expect(order['total'], 27500);
    expect((await db.query('order_items')).single['bill_line_id'], isNull);
    final movement = (await db.query('stock_movements')).single;
    expect(movement['order_id'], 'o1');
    expect(movement['source_id'], isNull);
  });

  test('a fresh install has the saved-bill schema', () async {
    final db = await openInMemoryAppDb();
    addTearDown(db.close);
    for (final table in _f4Tables) {
      expect(await db.query(table), isEmpty);
    }
    expect(
      _columns(await db.rawQuery('PRAGMA table_info(kitchen_dispatches)')),
      containsAll(['origin', 'payload']),
    );
  });
}
