import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/pos_register.dart';

/// The tills a branch trades from. The only place registers are read or
/// written.
///
/// Same shape as every other repository here: swapping to a REST backend means
/// replacing these method bodies, not touching the model or any screen.
class PosRegisterRepository {
  PosRegisterRepository._();
  static final PosRegisterRepository instance = PosRegisterRepository._();

  /// Every till at one branch.
  ///
  /// [outletId] is required rather than defaulted, for the same reason it is
  /// on the catalogue and the floor plan: there is no useful "all branches"
  /// list of tills, and a default would let a call site quietly ask the wrong
  /// shop which registers it has.
  Future<List<PosRegister>> byOutlet(
    String outletId, {
    bool onlyActive = false,
  }) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'pos_registers',
      where: onlyActive ? 'outlet_id = ? AND active = 1' : 'outlet_id = ?',
      whereArgs: [outletId],
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(PosRegister.fromMap).toList();
  }

  Future<PosRegister?> byId(String id) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'pos_registers',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : PosRegister.fromMap(rows.first);
  }

  /// True when [name] is already taken by another till AT THE SAME BRANCH.
  ///
  /// Scoped per outlet on purpose: every branch is allowed its own "Kasir 1",
  /// and forcing "Bintaro Kasir 1" onto the button a cashier taps forty times
  /// a shift would be the tail wagging the dog. Two tills with one name at one
  /// counter is the case that actually confuses somebody.
  Future<bool> isNameTaken(
    String name, {
    required String outletId,
    String? exceptId,
  }) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'pos_registers',
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

  Future<void> upsert(PosRegister register) async {
    final db = await AppDatabase.instance.db;
    await db.insert(
      'pos_registers',
      register.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// How many till sessions a register has held, open or closed.
  ///
  /// The management screen asks before offering to delete one: a till with
  /// sessions has drawer counts filed against it, and deleting the row leaves
  /// those pointing at an id that resolves to nothing. Deactivating keeps the
  /// history readable, which is what somebody means when they say a till is
  /// gone.
  Future<int> sessionCount(String id) async {
    final db = await AppDatabase.instance.db;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM shifts WHERE pos_id = ?', [
            id,
          ]),
        ) ??
        0;
  }

  /// How many sales a register has rung up. Asked for the same reason as
  /// [sessionCount] — an order naming a till that no longer exists is a
  /// receipt that cannot be explained.
  Future<int> orderCount(String id) async {
    final db = await AppDatabase.instance.db;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM orders WHERE pos_id = ?', [
            id,
          ]),
        ) ??
        0;
  }

  Future<void> delete(String id) async {
    final db = await AppDatabase.instance.db;
    await db.delete('pos_registers', where: 'id = ?', whereArgs: [id]);
  }
}
