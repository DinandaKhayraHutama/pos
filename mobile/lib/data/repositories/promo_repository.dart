import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../device/till_binding.dart';
import '../models/promo.dart';

/// Configured discounts. Owned by the owner, applied by anyone.
///
/// On an activated till promos are pulled from the Backoffice (Fase 6) with
/// their branch scoping: `promos.all_outlets`, and `promo_outlets` naming the
/// branches of a promo that is not company-wide.
class PromoRepository {
  PromoRepository._();
  static final PromoRepository instance = PromoRepository._();

  /// [onlyActive] is what the till asks for; the management screen wants the
  /// retired ones too, so it can bring one back.
  ///
  /// [outletId] narrows the list to the promos live at that branch: every
  /// company-wide promo, plus those whose scoping names the branch. A promo
  /// scoped to no branch is live nowhere — absence of scoping never reads as
  /// "everywhere", or narrowing a promo one branch too far would spread it
  /// across the chain.
  Future<List<Promo>> all({bool onlyActive = false, String? outletId}) async {
    final db = await AppDatabase.instance.db;
    final where = <String>[];
    final args = <Object?>[];
    if (onlyActive) where.add('active = 1');
    if (outletId != null) {
      where.add(
        '(all_outlets = 1 OR id IN '
        '(SELECT promo_id FROM promo_outlets WHERE outlet_id = ?))',
      );
      args.add(outletId);
    }
    final rows = await db.query(
      'promos',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(Promo.fromMap).toList();
  }

  /// The demo's promo editor. On an activated till promos are the
  /// Backoffice's, and the screen that calls this is closed.
  Future<void> upsert(Promo promo) async {
    if (TillBinding.current != null)
      throw StateError('Promos are managed in Backoffice.');
    final db = await AppDatabase.instance.db;
    await db.insert(
      'promos',
      promo.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String id) async {
    if (TillBinding.current != null)
      throw StateError('Promos are managed in Backoffice.');
    final db = await AppDatabase.instance.db;
    await db.delete('promos', where: 'id = ?', whereArgs: [id]);
  }
}
