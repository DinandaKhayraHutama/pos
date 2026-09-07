import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/promo.dart';

/// Configured discounts. Owned by the owner, applied by anyone.
class PromoRepository {
  PromoRepository._();
  static final PromoRepository instance = PromoRepository._();

  /// [onlyActive] is what the till asks for; the management screen wants the
  /// retired ones too, so it can bring one back.
  Future<List<Promo>> all({bool onlyActive = false}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'promos',
      where: onlyActive ? 'active = 1' : null,
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(Promo.fromMap).toList();
  }

  Future<void> upsert(Promo promo) async {
    final db = await AppDatabase.instance.db;
    await db.insert(
      'promos',
      promo.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String id) async {
    final db = await AppDatabase.instance.db;
    await db.delete('promos', where: 'id = ?', whereArgs: [id]);
  }
}
