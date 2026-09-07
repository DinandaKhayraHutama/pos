import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/enums.dart';
import '../models/table.dart';

/// The floor plan, always for ONE branch.
///
/// [outletId] is required rather than defaulted for the same reason it is on
/// the catalogue: there is no useful "all branches" floor plan, and a board
/// showing two shops' covers at once would have a waiter seating a guest at a
/// table in another city.
class TableRepository {
  TableRepository._();
  static final TableRepository instance = TableRepository._();

  /// Every table at one branch.
  ///
  /// [onlyActive] is what tells the two callers apart: the management screen
  /// (false, the default) has to see a deactivated table to bring it back,
  /// while the "start a new order" pickers (true) must never offer one.
  Future<List<RestaurantTable>> byOutlet(
    String outletId, {
    bool onlyActive = false,
  }) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'tables',
      where: onlyActive
          ? 'outlet_id = ? AND active = 1'
          : 'outlet_id = ?',
      whereArgs: [outletId],
      orderBy: 'floor ASC, sort_order ASC, name ASC',
    );
    return rows.map(RestaurantTable.fromMap).toList();
  }

  /// The floor board's list: every active table, PLUS any inactive table
  /// still mid-service.
  ///
  /// A table deactivated while a guest is seated must not vanish from the
  /// board — staff still need to see it is occupied and clear it. Once it is
  /// available again, an inactive table drops out on the next read.
  Future<List<RestaurantTable>> operational(String outletId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'tables',
      where: "outlet_id = ? AND (active = 1 OR status != 'available')",
      whereArgs: [outletId],
      orderBy: 'floor ASC, sort_order ASC, name ASC',
    );
    return rows.map(RestaurantTable.fromMap).toList();
  }

  /// True when [name] is already taken by another table AT THE SAME BRANCH.
  ///
  /// Scoped per outlet, same reasoning as `PosRegisterRepository`: every
  /// branch is allowed its own "Meja 01".
  Future<bool> isNameTaken(
    String name, {
    required String outletId,
    String? exceptId,
  }) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'tables',
      where: exceptId == null
          ? 'outlet_id = ? AND name = ? COLLATE NOCASE'
          : 'outlet_id = ? AND name = ? COLLATE NOCASE AND id != ?',
      whereArgs: exceptId == null
          ? [outletId, name]
          : [outletId, name, exceptId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> upsert(RestaurantTable t) async {
    final db = await AppDatabase.instance.db;
    await db.insert(
      'tables',
      t.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> setStatus(String id, TableStatus status) async {
    final db = await AppDatabase.instance.db;
    await db.update(
      'tables',
      {'status': status.wire},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// How many orders were rung up against this table.
  ///
  /// Asked before offering to delete one, same reason as
  /// `PosRegisterRepository.orderCount`: `orders.table_name` is a snapshot
  /// (no FK), so deleting the row would not corrupt a past receipt — but it
  /// would leave nothing for staff to reopen if the table comes back into
  /// use, and "gone" is what deactivating already means. Delete stays for a
  /// table nobody ever sat a guest at.
  Future<int> orderCount(String id) async {
    final db = await AppDatabase.instance.db;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM orders WHERE table_id = ?',
            [id],
          ),
        ) ??
        0;
  }

  Future<void> delete(String id) async {
    final db = await AppDatabase.instance.db;
    await db.delete('tables', where: 'id = ?', whereArgs: [id]);
  }
}
