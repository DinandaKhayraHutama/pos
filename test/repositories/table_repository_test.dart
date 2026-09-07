import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/table.dart';
import 'package:nti_pos/data/repositories/table_repository.dart';

import '../helpers/db_helper.dart';

/// These exercise one branch's board. Per-outlet separation has its own
/// coverage; threading a second outlet through every case here would only
/// obscure what is being asserted.
const _outlet = 'outlet-1';

void main() {
  setUpAll(() async {
    await initFfi();
  });

  group('TableRepository — seeded DB', () {
    late Database db;

    setUp(() async {
      db = await openInMemoryAppDb(seed: true);
      await AppDatabase.instance.useTestDb(db);
    });
    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('all() returns a full restaurant floor plan', () async {
      final tables = await TableRepository.instance.byOutlet(_outlet);
      // A count rather than an exact number: the floor plan is data that grows
      // (it went from 8 to 31 in v12), and a test that has to be edited every
      // time a table is added is a test that gets edited without being read.
      expect(tables.length, greaterThanOrEqualTo(28));
      // The original ids still resolve — `orders.table_name` is a snapshot, so
      // history points at these.
      expect(tables.any((t) => t.id == 't_1'), isTrue);
      expect(tables.any((t) => t.id == 't_8'), isTrue);
    });

    // Tables used to seed uniformly available. Since the demo's trading
    // history was added, the board mirrors it: a table holding a dine-in order
    // that has not reached a terminal status reads occupied.
    //
    // Derived from the orders rather than from a list of ids. The seeded
    // history is generated now, so naming the tables it happens to fill would
    // pin the test to one draw of the random seed; the invariant is what
    // matters, and it is the stronger claim anyway.
    test('seeded table statuses mirror the seeded orders', () async {
      final tables = await TableRepository.instance.byOutlet(_outlet);
      final byId = {for (final t in tables) t.id: t.status};

      final openRows = await db.query(
        'orders',
        columns: ['table_id'],
        where:
            "table_id IS NOT NULL AND status IN ('pending', 'preparing', "
            "'ready', 'served')",
      );
      final held = {for (final r in openRows) r['table_id'] as String};
      expect(held, isNotEmpty, reason: 'the demo must open with live tables');

      for (final entry in byId.entries) {
        if (held.contains(entry.key)) {
          expect(
            entry.value,
            TableStatus.occupied,
            reason: '${entry.key} holds an unfinished dine-in order',
          );
        } else {
          expect(
            entry.value,
            isNot(TableStatus.occupied),
            reason: '${entry.key} has no open order',
          );
        }
      }

      // All three states visible, or the board only ever demonstrates two.
      final states = byId.values.toSet();
      expect(
        states,
        containsAll(<TableStatus>[
          TableStatus.available,
          TableStatus.occupied,
          TableStatus.reserved,
        ]),
      );
    });

    test('setStatus(id, occupied) persists (re-read confirms)', () async {
      // Control picked from the board rather than hardcoded: which tables the
      // generated history leaves free is not something a test should assume.
      final before = await TableRepository.instance.byOutlet(_outlet);
      final free = before.firstWhere((t) => t.status == TableStatus.available);
      final target = before.firstWhere(
        (t) => t.id != free.id && t.status != TableStatus.occupied,
      );

      await TableRepository.instance.setStatus(target.id, TableStatus.occupied);

      final tables = await TableRepository.instance.byOutlet(_outlet);
      expect(
        tables.firstWhere((t) => t.id == target.id).status,
        TableStatus.occupied,
      );
      expect(
        tables.firstWhere((t) => t.id == free.id).status,
        TableStatus.available,
        reason: 'setting one table must not disturb another',
      );
    });

    test('setStatus cycles available -> occupied -> reserved', () async {
      await TableRepository.instance.setStatus('t_1', TableStatus.occupied);
      var tables = await TableRepository.instance.byOutlet(_outlet);
      expect(
        tables.firstWhere((t) => t.id == 't_1').status,
        TableStatus.occupied,
      );

      await TableRepository.instance.setStatus('t_1', TableStatus.reserved);
      tables = await TableRepository.instance.byOutlet(_outlet);
      expect(
        tables.firstWhere((t) => t.id == 't_1').status,
        TableStatus.reserved,
      );
    });
  });

  group('TableRepository — empty DB', () {
    late Database db;

    setUp(() async {
      db = await openInMemoryAppDb(seed: false);
      await AppDatabase.instance.useTestDb(db);
    });
    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('upsert then all() round-trips the table', () async {
      const t = RestaurantTable(
        outletId: _outlet,
        id: 't_custom',
        name: 'Meja Custom',
        capacity: 6,
        floor: 'floor_2',
        sortOrder: 3,
      );
      await TableRepository.instance.upsert(t);

      final all = await TableRepository.instance.byOutlet(_outlet);
      expect(all, hasLength(1));
      expect(all.first.id, t.id);
      expect(all.first.capacity, t.capacity);
      expect(all.first.floor, t.floor);
    });

    test('byOutlet(onlyActive: true) excludes a deactivated table', () async {
      const active = RestaurantTable(
        outletId: _outlet,
        id: 't_active',
        name: 'Meja Aktif',
        capacity: 2,
      );
      const inactive = RestaurantTable(
        outletId: _outlet,
        id: 't_inactive',
        name: 'Meja Nonaktif',
        capacity: 2,
        active: false,
      );
      await TableRepository.instance.upsert(active);
      await TableRepository.instance.upsert(inactive);

      final all = await TableRepository.instance.byOutlet(_outlet);
      expect(all.map((t) => t.id), containsAll(['t_active', 't_inactive']));

      final onlyActive = await TableRepository.instance.byOutlet(
        _outlet,
        onlyActive: true,
      );
      expect(onlyActive.map((t) => t.id), ['t_active']);
    });

    test(
      'operational() keeps an inactive table while it is occupied, drops it '
      'once available again',
      () async {
        const t = RestaurantTable(
          outletId: _outlet,
          id: 't_deactivated',
          name: 'Meja Ditutup',
          capacity: 4,
          status: TableStatus.occupied,
          active: false,
        );
        await TableRepository.instance.upsert(t);

        final whileOccupied = await TableRepository.instance.operational(
          _outlet,
        );
        expect(whileOccupied.map((r) => r.id), contains('t_deactivated'));

        await TableRepository.instance.setStatus(
          't_deactivated',
          TableStatus.available,
        );
        final afterCleared = await TableRepository.instance.operational(
          _outlet,
        );
        expect(afterCleared.map((r) => r.id), isNot(contains('t_deactivated')));
      },
    );

    test('delete removes the table', () async {
      const t = RestaurantTable(
        outletId: _outlet,
        id: 't_del',
        name: 'Meja Del',
        capacity: 2,
      );
      await TableRepository.instance.upsert(t);
      expect(await TableRepository.instance.byOutlet(_outlet), hasLength(1));

      await TableRepository.instance.delete(t.id);
      expect(await TableRepository.instance.byOutlet(_outlet), isEmpty);
    });

    test('orderCount reflects orders naming this table, 0 for an unused one',
        () async {
      const withOrder = RestaurantTable(
        outletId: _outlet,
        id: 't_history',
        name: 'Meja Riwayat',
        capacity: 2,
      );
      const withoutOrder = RestaurantTable(
        outletId: _outlet,
        id: 't_fresh',
        name: 'Meja Baru',
        capacity: 2,
      );
      await TableRepository.instance.upsert(withOrder);
      await TableRepository.instance.upsert(withoutOrder);

      await db.insert('orders', {
        'id': 'ord_1',
        'number': 'ord_1',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'type': 'dineIn',
        'table_id': withOrder.id,
        'table_name': withOrder.name,
        'subtotal': 10000,
        'discount': 0,
        'tax': 0,
        'total': 10000,
        'amount_paid': 10000,
        'payment_method': 'cash',
        'status': 'paid',
        'cashier_id': 'c1',
        'cashier_name': 'Kasir',
        'outlet_id': _outlet,
      });

      expect(await TableRepository.instance.orderCount(withOrder.id), 1);
      expect(await TableRepository.instance.orderCount(withoutOrder.id), 0);
    });

    test('isNameTaken is scoped per outlet and excludes exceptId', () async {
      const t = RestaurantTable(
        outletId: _outlet,
        id: 't_named',
        name: 'Meja VIP',
        capacity: 4,
      );
      await TableRepository.instance.upsert(t);

      expect(
        await TableRepository.instance.isNameTaken('meja vip', outletId: _outlet),
        isTrue,
        reason: 'name match is case-insensitive',
      );
      expect(
        await TableRepository.instance.isNameTaken(
          'Meja VIP',
          outletId: _outlet,
          exceptId: t.id,
        ),
        isFalse,
        reason: 'editing the same row must not collide with itself',
      );
      expect(
        await TableRepository.instance.isNameTaken(
          'Meja VIP',
          outletId: 'other-outlet',
        ),
        isFalse,
        reason: 'another branch is allowed the same table name',
      );
    });
  });
}
