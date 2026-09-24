import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _f3Tables = [
  'roles',
  'business_settings',
  'sales_types',
  'payment_methods',
  'payment_groups',
  'discounts',
  'outlet_settings',
  'product_sales_type_prices',
  'outlet_product_sales_type_prices',
];

const _f3OrderColumns = [
  'pricing_version',
  'pricing',
  'tax_included',
  'rounding_amount',
  'tz_offset_minutes',
  'sales_type_id',
  'sales_type_name',
  'payment_method_id',
  'payment_method_name',
  'payment_reference',
  'served_by_id',
  'served_by_name',
  'discount_id',
  'discount_name',
  'discount_authorized_by_id',
  'discount_authorized_by_name',
  'receipt_snapshot',
];

const _f3ItemColumns = [
  'custom',
  'base_price',
  'price_source',
  'tax_rate_bp',
  'discount_spec',
  'line_discount_id',
  'line_discount_name',
  'line_discount_authorized_by_id',
  'line_discount_authorized_by_name',
  'line_discount',
  'bill_discount_share',
  'service_share',
  'tax_amount',
  'tax_included',
  'net_amount',
];

Set<String> _columns(List<Map<String, Object?>> info) => {
  for (final row in info) row['name']! as String,
};

/// The v32 upgrade (paritas F3) on a real file: a v31 till with an unsent
/// sale and a signed-in cashier comes out with every Fase 3 table and column,
/// and with every row it went in with — a legacy sale reading as exactly the
/// receipt it was.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v31 → v32 adds the Fase 3 schema and keeps every row', () async {
    await initFfi();
    final dir = await Directory.systemTemp.createTemp('nti_pos_v31_');
    final path = '${dir.path}${Platform.pathSeparator}legacy.db';
    addTearDown(() async {
      await deleteDatabase(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    // Built at v31 by taking the Fase 3 additions back off today's schema —
    // exactly the shape a v31 install has on disk.
    var db = await AppDatabase.openForTest(
      path: path,
      version: 31,
      seed: false,
    );
    for (final table in _f3Tables) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
    for (final column in _f3OrderColumns) {
      await db.execute('ALTER TABLE orders DROP COLUMN $column');
    }
    for (final column in _f3ItemColumns) {
      await db.execute('ALTER TABLE order_items DROP COLUMN $column');
    }
    await db.execute('ALTER TABLE employees DROP COLUMN role_id');

    await db.insert('employees', {
      'id': 'e1',
      'name': 'Siti',
      'role': 'cashier',
    });
    await db.insert('orders', {
      'id': 'o1',
      'number': 'K1-0001',
      'created_at': 1758326400000,
      'type': 'takeaway',
      'subtotal': 20000,
      'discount': 0,
      'tax': 2000,
      'total': 22000,
      'amount_paid': 22000,
      'payment_method': 'cash',
      'status': 'paid',
      'cashier_id': 'e1',
      'cashier_name': 'Siti',
    });
    await db.insert('order_items', {
      'id': 'i1',
      'order_id': 'o1',
      'product_id': 'p1',
      'product_name': 'Kopi Susu',
      'unit_price': 20000,
      'quantity': 1,
    });
    await db.insert('_outbox', {
      'entity': 'orders',
      'entity_id': 'o1',
      'queued_at': 1,
    });
    await db.close();

    db = await AppDatabase.openForTest(path: path, seed: false);
    addTearDown(db.close);

    for (final table in _f3Tables) {
      expect(await db.query(table), isEmpty, reason: '$table exists, empty');
    }
    expect(
      _columns(await db.rawQuery('PRAGMA table_info(orders)')),
      containsAll(_f3OrderColumns),
    );
    expect(
      _columns(await db.rawQuery('PRAGMA table_info(order_items)')),
      containsAll(_f3ItemColumns),
    );
    expect(
      _columns(await db.rawQuery('PRAGMA table_info(employees)')),
      contains('role_id'),
    );

    // The unsent sale is still owed to the server, and still a legacy
    // receipt: no pricing version, nothing included, nothing rounded.
    expect(await db.query('_outbox'), hasLength(1));
    final order = (await db.query('orders')).single;
    expect(order['total'], 22000);
    expect(order['pricing_version'], isNull);
    expect(order['tax_included'], 0);
    expect(order['rounding_amount'], 0);
    final item = (await db.query('order_items')).single;
    expect(item['custom'], 0);
    expect(item['net_amount'], isNull);
    expect(item['line_discount'], 0);

    // The signed-in cashier is untouched; a missing role_id falls back to
    // the system role named in `role`, as before.
    final employee = (await db.query('employees')).single;
    expect(employee['role'], 'cashier');
    expect(employee['role_id'], isNull);
  });
}
