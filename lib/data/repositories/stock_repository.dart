import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/stock_movement.dart';

/// The stock ledger: every change to an on-hand count, and why.
///
/// The count in `outlet_stock` is the running balance for one branch's shelf;
/// this table is the evidence for it. They are only ever written together, inside one
/// transaction — a balance that moved with no matching row would make the
/// whole history unusable for the one job it has, which is settling an
/// argument about where the goods went.
class StockRepository {
  StockRepository._();
  static final StockRepository instance = StockRepository._();

  static const _uuid = Uuid();

  /// Applies [delta] to a product's count and records why.
  ///
  /// Returns the new balance. Throws [StateError] when the product is not
  /// stock-tracked: booking a delivery against an item nobody counts would
  /// silently start tracking it, which is a decision the product form should
  /// make, not an adjustment screen.
  ///
  /// The floor at zero matches the sale path — a recount that goes below zero
  /// is a typo, and the honest recovery is to land on zero rather than to
  /// record a negative shelf.
  Future<int> adjust({
    required String outletId,
    required String productId,
    required int delta,
    required StockReason reason,
    required String employeeId,
    required String employeeName,
    String? note,
  }) async {
    final db = await AppDatabase.instance.db;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'products',
        columns: ['name'],
        where: 'id = ?',
        whereArgs: [productId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('No such product: $productId');
      }
      final current = await countAt(
        txn,
        outletId: outletId,
        productId: productId,
      );
      if (current == null) {
        throw StateError('Product $productId is not stock-tracked');
      }
      final next = (current + delta).clamp(0, 1 << 31);
      // Recomputed from the clamp, not taken as given: when the clamp bites,
      // the ledger has to say what actually happened to the shelf, not what
      // was asked for.
      final applied = next - current;

      await setCountAt(
        txn,
        outletId: outletId,
        productId: productId,
        stock: next,
      );
      await txn.insert(
        'stock_movements',
        StockMovement(
          id: _uuid.v4(),
          outletId: outletId,
          productId: productId,
          productName: rows.first['name'] as String,
          delta: applied,
          balanceAfter: next,
          reason: reason,
          createdAt: DateTime.now(),
          employeeId: employeeId,
          employeeName: employeeName,
          note: note,
        ).toMap(),
      );
      return next;
    });
  }

  /// What one branch has on the shelf, or null when the product is not
  /// stock-tracked at all.
  ///
  /// Falls back to the catalogue's opening count when this branch has no row
  /// yet — a product added after a branch opened would otherwise read as
  /// untracked there, which hides it from every low-stock alert.
  static Future<int?> countAt(
    DatabaseExecutor txn, {
    required String outletId,
    required String productId,
  }) async {
    final rows = await txn.rawQuery(
      'SELECT COALESCE(os.stock, p.stock) AS stock '
      'FROM products p '
      'LEFT JOIN outlet_stock os '
      '  ON os.product_id = p.id AND os.outlet_id = ? '
      'WHERE p.id = ? LIMIT 1',
      [outletId, productId],
    );
    if (rows.isEmpty) return null;
    return (rows.first['stock'] as num?)?.toInt();
  }

  /// Writes one branch's count, creating the row the first time.
  static Future<void> setCountAt(
    DatabaseExecutor txn, {
    required String outletId,
    required String productId,
    required int stock,
  }) async {
    await txn.rawInsert(
      'INSERT INTO outlet_stock (outlet_id, product_id, stock) '
      'VALUES (?, ?, ?) '
      'ON CONFLICT(outlet_id, product_id) DO UPDATE SET stock = excluded.stock',
      [outletId, productId, stock],
    );
  }

  /// Movement history, newest first.
  ///
  /// Scoped to one branch: a manager in Kemang looking at "why is this short"
  /// must not be shown Bintaro's deliveries, or the running balance in the
  /// list stops matching the shelf in front of them. Pass [productId] for one
  /// product's ledger.
  Future<List<StockMovement>> history({
    required String outletId,
    String? productId,
    int limit = 100,
  }) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'stock_movements',
      where: productId == null
          ? 'outlet_id = ?'
          : 'outlet_id = ? AND product_id = ?',
      whereArgs: productId == null ? [outletId] : [outletId, productId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(StockMovement.fromMap).toList();
  }

  /// Records movements written by another transaction (a sale, a void).
  ///
  /// Takes the [txn] it should join rather than opening its own, so the
  /// ledger row and the count change either both land or neither does.
  /// [balances] maps product id to the count after the change.
  static Future<void> recordWithin(
    DatabaseExecutor txn, {
    required String outletId,
    required Map<String, ({String name, int delta, int balanceAfter})> movements,
    required StockReason reason,
    required String employeeId,
    required String employeeName,
    String? note,
  }) async {
    final now = DateTime.now();
    for (final e in movements.entries) {
      if (e.value.delta == 0) continue;
      await txn.insert(
        'stock_movements',
        StockMovement(
          id: _uuid.v4(),
          outletId: outletId,
          productId: e.key,
          productName: e.value.name,
          delta: e.value.delta,
          balanceAfter: e.value.balanceAfter,
          reason: reason,
          createdAt: now,
          employeeId: employeeId,
          employeeName: employeeName,
          note: note,
        ).toMap(),
      );
    }
  }
}
