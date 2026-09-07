import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/outlet.dart';

/// The only place outlets are read or written.
///
/// Same shape as every other repository here: swapping to a REST backend means
/// replacing these method bodies, not touching the model or any screen.
class OutletRepository {
  OutletRepository._();
  static final OutletRepository instance = OutletRepository._();

  Future<List<Outlet>> all({bool onlyActive = false}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'outlets',
      where: onlyActive ? 'active = 1' : null,
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(Outlet.fromMap).toList();
  }

  Future<Outlet?> byId(String id) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'outlets',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Outlet.fromMap(rows.first);
  }

  /// The outlet a device falls back to when its own choice is gone — closed,
  /// or never made in the first place.
  ///
  /// Returns null only when every outlet is closed, which the caller has to
  /// handle rather than paper over.
  Future<Outlet?> firstActive() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'outlets',
      where: 'active = 1',
      orderBy: 'sort_order ASC, name ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : Outlet.fromMap(rows.first);
  }

  /// True when [name] is already taken by another outlet.
  ///
  /// Two branches called "Bintaro" make every per-outlet report unreadable,
  /// and the person reading it cannot tell which row is which.
  Future<bool> isNameTaken(String name, {String? exceptId}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'outlets',
      where: exceptId == null
          ? 'name = ? COLLATE NOCASE'
          : 'name = ? COLLATE NOCASE AND id != ?',
      whereArgs: exceptId == null ? [name] : [name, exceptId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> upsert(Outlet outlet) async {
    final db = await AppDatabase.instance.db;
    await db.insert(
      'outlets',
      outlet.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// How many sales a branch has taken.
  ///
  /// The manager screen asks before offering to delete one: a branch with
  /// history has to be closed instead, or its orders point at an id that
  /// resolves to nothing and the chain's totals stop adding up.
  Future<int> orderCount(String id) async {
    final db = await AppDatabase.instance.db;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM orders WHERE outlet_id = ?',
            [id],
          ),
        ) ??
        0;
  }

  Future<void> delete(String id) async {
    final db = await AppDatabase.instance.db;
    await db.delete('outlets', where: 'id = ?', whereArgs: [id]);
  }
}
