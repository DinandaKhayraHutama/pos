import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/models/enums.dart';

import '../helpers/db_helper.dart';

/// Guards the *shape* of the demo data, not its exact figures.
///
/// The generator is fixed-seeded, so a single arithmetic slip would silently
/// halve the takings on every screen a client is shown. These bounds are wide
/// enough to survive tuning the pools and tight enough to catch a day that
/// generated nothing, a discount that ate the revenue, or a party-size change
/// that quietly turned the restaurant back into a warung.
void main() {
  late Database db;

  setUpAll(initFfi);

  setUp(() async {
    db = await openInMemoryAppDb(seed: true);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  test('the floor plan is a restaurant, spread over four areas', () async {
    final tables = await db.query('tables');
    expect(tables.length, greaterThanOrEqualTo(28));

    final floors = tables.map((t) => t['floor']).toSet();
    expect(
      floors,
      containsAll(<String>['floor_1', 'floor_2', 'floor_3', 'floor_4']),
    );

    // The original eight survive by id, name and floor: `orders.table_name` is
    // a snapshot, so renaming one orphans the history that points at it.
    final vip = tables.firstWhere((t) => t['id'] == 't_8');
    expect(vip['name'], 'VIP Room');
    expect(vip['floor'], 'floor_3');
  });

  test('every board status is represented', () async {
    final statuses = (await db.query(
      'tables',
      columns: ['status'],
    )).map((r) => r['status']).toSet();
    expect(
      statuses,
      containsAll(<String>['available', 'occupied', 'reserved']),
    );
  });

  test('a month of trading, with every day covered', () async {
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM orders'),
    )!;
    expect(count, greaterThan(700), reason: 'a large restaurant, not a stall');

    // 30 distinct days, none of them empty — an empty day is a hole in the
    // report chart and a zero in a range the client happens to pick.
    final days = Sqflite.firstIntValue(
      await db.rawQuery('''
        SELECT COUNT(*) FROM (
          SELECT DISTINCT date(created_at / 1000, 'unixepoch', 'localtime')
          FROM orders
        )
      '''),
    )!;
    expect(days, 30);
  });

  test(
    "today's takings are worth showing, and exclude what was not kept",
    () async {
      final startOfDay = DateTime.now();
      final midnight = DateTime(
        startOfDay.year,
        startOfDay.month,
        startOfDay.day,
      ).millisecondsSinceEpoch;

      final revenue = Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT SUM(total) FROM orders '
          'WHERE created_at >= ? AND $kRevenueStatusSql',
          [midnight],
        ),
      )!;
      // Tens of millions of rupiah: the point of the exercise.
      expect(revenue, greaterThan(8000000));

      final orders = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM orders WHERE created_at >= ?', [
          midnight,
        ]),
      )!;
      expect(orders, greaterThan(25));
      // Average check in the hundreds of thousands — a table, not a takeaway.
      expect(revenue ~/ orders, greaterThan(150000));
    },
  );

  test('voids and refunds exist, are explained, and leave revenue', () async {
    final settled = await db.query(
      'orders',
      where: 'status IN (?, ?)',
      whereArgs: [OrderStatus.cancelled.wire, OrderStatus.refunded.wire],
    );
    expect(settled.length, greaterThanOrEqualTo(8));

    for (final row in settled) {
      expect(
        row['authorized_by'],
        isNotNull,
        reason: 'voidOrder/refundOrder always write an approver',
      );
      if (row['status'] == OrderStatus.cancelled.wire) {
        expect(row['void_reason'], isNotNull);
      } else {
        expect(row['refunded_amount'], isNotNull);
      }
    }

    final kept = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT SUM(total) FROM orders WHERE $kRevenueStatusSql',
      ),
    )!;
    final all = Sqflite.firstIntValue(
      await db.rawQuery('SELECT SUM(total) FROM orders'),
    )!;
    expect(
      kept,
      lessThan(all),
      reason: 'settled orders must not count as revenue',
    );
  });

  test('the kitchen board has live work', () async {
    final open = await db.query(
      'orders',
      where: 'status IN (?, ?, ?, ?)',
      whereArgs: [
        OrderStatus.pending.wire,
        OrderStatus.preparing.wire,
        OrderStatus.ready.wire,
        OrderStatus.served.wire,
      ],
    );
    expect(open.length, greaterThanOrEqualTo(6));
  });

  test('every order line points at a product that exists', () async {
    final orphans = Sqflite.firstIntValue(
      await db.rawQuery('''
        SELECT COUNT(*) FROM order_items oi
        LEFT JOIN products p ON p.id = oi.product_id
        WHERE p.id IS NULL
      '''),
    )!;
    expect(orphans, 0);
  });

  test('quantities are whole and positive', () async {
    final bad = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM order_items WHERE quantity < 1'),
    )!;
    expect(bad, 0, reason: 'a zero-quantity line is a split-allocation bug');
  });
}
