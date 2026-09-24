import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../device/till_binding.dart';
import '../models/stock_movement.dart';
import '../sync/outbox_store.dart';
import '../sync/stock_movement_push.dart';

/// The stock ledger: every change to an on-hand count, and why.
///
/// The count in `outlet_stock` is the running balance for one branch's shelf;
/// this table is the evidence for it. They are only ever written together, inside one
/// transaction — a balance that moved with no matching row would make the
/// whole history unusable for the one job it has, which is settling an
/// argument about where the goods went.
///
/// **On an activated till the server's ledger is the truth (Fase 5).** Every
/// movement this till writes is queued for push, and the displayed count is
///
///     server snapshot + Σ(this till's movements the snapshot does not include)
///
/// where "does not include" means not yet acknowledged, or acknowledged at a
/// projection sequence newer than the snapshot held. Two tills selling the
/// same item offline therefore each show a locally correct number and land on
/// the same number once both have pushed and pulled. Negative counts are
/// recorded, never floored: a sale that happened is not refused because the
/// shelf looked empty. The demo keeps its floor at zero.
class StockRepository {
  StockRepository._();
  static final StockRepository instance = StockRepository._();

  static const _uuid = Uuid();

  /// A movement this till wrote.
  static const originDevice = 'device';

  /// A movement pulled from the server: another till's, or the Backoffice's.
  /// History only — already inside the snapshot it came with.
  static const originServer = 'server';

  static bool get _ledgerMode => TillBinding.current != null;

  /// Where a count lands after [delta]. Floored at zero in the demo; exact on
  /// an activated till, where the shortfall is a fact the server must hear.
  static int landing(int current, int delta) {
    final next = current + delta;
    return _ledgerMode ? next : next.clamp(0, 1 << 31);
  }

  /// Applies [delta] to a product's count and records why.
  ///
  /// Returns the new balance. Throws [StateError] when the product is not
  /// stock-tracked: booking a delivery against an item nobody counts would
  /// silently start tracking it, which is a decision the product form should
  /// make, not an adjustment screen.
  ///
  /// In the demo the floor at zero matches the sale path — a recount that goes
  /// below zero is a typo, and the honest recovery is to land on zero rather
  /// than to record a negative shelf.
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
      final name = await _productName(txn, productId);
      final current = await countAt(
        txn,
        outletId: outletId,
        productId: productId,
      );
      if (current == null) {
        throw StateError('Product $productId is not stock-tracked');
      }
      final next = landing(current, delta);
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
      await writeMovementWithin(
        txn,
        outletId: outletId,
        productId: productId,
        productName: name,
        delta: applied,
        balanceAfter: next,
        reason: reason,
        employeeId: employeeId,
        employeeName: employeeName,
        note: note,
      );
      return next;
    });
  }

  /// Records a stock opname: [countedQty] is what is on the shelf.
  ///
  /// The movement carries both the counted quantity and the delta from what
  /// this till believed. On an activated till the server replaces that delta
  /// with one against its own count — a physical count is a fact about now,
  /// and the server holds the freshest total — and the snapshot sequence the
  /// till counted against travels with it for audit.
  Future<int> count({
    required String outletId,
    required String productId,
    required int countedQty,
    required String employeeId,
    required String employeeName,
    String? note,
  }) async {
    if (countedQty < 0) {
      throw ArgumentError.value(countedQty, 'countedQty', 'cannot be negative');
    }
    final db = await AppDatabase.instance.db;
    return db.transaction((txn) async {
      final name = await _productName(txn, productId);
      final current = await countAt(
        txn,
        outletId: outletId,
        productId: productId,
      );
      if (current == null) {
        throw StateError('Product $productId is not stock-tracked');
      }
      final basis = await txn.query(
        'outlet_stock',
        columns: ['server_seq'],
        where: 'outlet_id = ? AND product_id = ?',
        whereArgs: [outletId, productId],
        limit: 1,
      );

      await setCountAt(
        txn,
        outletId: outletId,
        productId: productId,
        stock: countedQty,
      );
      await writeMovementWithin(
        txn,
        outletId: outletId,
        productId: productId,
        productName: name,
        delta: countedQty - current,
        balanceAfter: countedQty,
        reason: StockReason.count,
        employeeId: employeeId,
        employeeName: employeeName,
        note: note,
        countedQty: countedQty,
        basisSeq: basis.isEmpty
            ? null
            : (basis.first['server_seq'] as num?)?.toInt(),
      );
      return countedQty;
    });
  }

  static Future<String> _productName(
    DatabaseExecutor txn,
    String productId,
  ) async {
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
    return rows.first['name'] as String;
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

  /// Writes one movement this till made, and on an activated till queues it
  /// for push in the same transaction — a movement written and queued
  /// afterwards is one a crash can keep from the server forever.
  static Future<String> writeMovementWithin(
    DatabaseExecutor txn, {
    required String outletId,
    required String productId,
    required String productName,
    required int delta,
    required int balanceAfter,
    required StockReason reason,
    required String employeeId,
    required String employeeName,
    String? note,
    int? countedQty,
    int? basisSeq,
    String? orderId,
    String? sourceKind,
    String? sourceId,
  }) async {
    final id = _uuid.v4();
    await txn.insert('stock_movements', {
      ...StockMovement(
        id: id,
        outletId: outletId,
        productId: productId,
        productName: productName,
        delta: delta,
        balanceAfter: balanceAfter,
        reason: reason,
        createdAt: DateTime.now(),
        employeeId: employeeId,
        employeeName: employeeName,
        note: note,
      ).toMap(),
      'counted_qty': countedQty,
      'basis_seq': basisSeq,
      'origin': originDevice,
      'order_id': orderId,
      'source_kind': sourceKind,
      'source_id': sourceId,
    });
    // A movement that belongs to a receipt, a kitchen dispatch or a bill
    // cancellation travels inside that row's push, committed with it on the
    // server; queueing it on its own as well would apply it twice.
    if (_ledgerMode && orderId == null && sourceId == null) {
      await OutboxStore.enqueueWithin(txn, StockMovementPush.entity, id);
    }
    return id;
  }

  /// Moves stock for a set of products and writes the matching ledger rows,
  /// inside the caller's transaction.
  ///
  /// [quantities] is signed: negative takes stock, positive returns it.
  /// Untracked products are skipped — they have no count to move and no
  /// history worth writing — as is any product the device no longer holds. A
  /// shelf is floored at zero only in the demo; an activated till records a
  /// shortfall the server has to know about. Returns the movement written per
  /// product, which is what a kitchen dispatch sends up with itself.
  ///
  /// Shared by checkout, void/refund and the Fase 4 dispatch and
  /// cancellation, so the four cannot disagree about what "consume" means.
  static Future<void> moveWithin(
    DatabaseExecutor txn, {
    required String? outletId,
    required Map<String, int> quantities,
    required StockReason reason,
    required String employeeId,
    required String employeeName,
    String? note,
    String? orderId,
    String? sourceKind,
    String? sourceId,
  }) async {
    if (quantities.isEmpty) return;
    // A sale that cannot say which branch it came from must not move any
    // shelf: guessing an outlet here would draw stock down in a shop that
    // never served the customer.
    if (outletId == null) return;
    final movements = <String, ({String name, int delta, int balanceAfter})>{};

    for (final e in quantities.entries) {
      final rows = await txn.query(
        'products',
        columns: ['name'],
        where: 'id = ?',
        whereArgs: [e.key],
        limit: 1,
      );
      if (rows.isEmpty) continue;
      final current = await countAt(txn, outletId: outletId, productId: e.key);
      if (current == null) continue; // untracked

      final next = landing(current, e.value);
      if (next == current) continue;
      await setCountAt(txn, outletId: outletId, productId: e.key, stock: next);
      movements[e.key] = (
        name: rows.first['name'] as String,
        // The clamped delta, not the requested one: the ledger records what
        // happened to the shelf, not what was asked for.
        delta: next - current,
        balanceAfter: next,
      );
    }

    await recordWithin(
      txn,
      outletId: outletId,
      movements: movements,
      reason: reason,
      employeeId: employeeId,
      employeeName: employeeName,
      note: note,
      orderId: orderId,
      sourceKind: sourceKind,
      sourceId: sourceId,
    );
  }

  /// Records movements written by another transaction (a sale, a void).
  ///
  /// Takes the [txn] it should join rather than opening its own, so the
  /// ledger row and the count change either both land or neither does.
  /// [movements] maps product id to the change and the count after it.
  static Future<void> recordWithin(
    DatabaseExecutor txn, {
    required String outletId,
    required Map<String, ({String name, int delta, int balanceAfter})>
    movements,
    required StockReason reason,
    required String employeeId,
    required String employeeName,
    String? note,
    String? orderId,
    String? sourceKind,
    String? sourceId,
  }) async {
    for (final e in movements.entries) {
      if (e.value.delta == 0) continue;
      await writeMovementWithin(
        txn,
        outletId: outletId,
        productId: e.key,
        productName: e.value.name,
        delta: e.value.delta,
        balanceAfter: e.value.balanceAfter,
        reason: reason,
        employeeId: employeeId,
        employeeName: employeeName,
        note: note,
        orderId: orderId,
        sourceKind: sourceKind,
        sourceId: sourceId,
      );
    }
  }

  // ---- Server ledger (activated tills) -------------------------------------

  /// Re-derives the displayed count from the server snapshot and this till's
  /// movements the snapshot does not include yet, replayed oldest first: a
  /// count sets the value, every other movement adds its delta. No-op until a
  /// snapshot has arrived: until then the local running balance is all there
  /// is.
  static Future<void> recomputeWithin(
    DatabaseExecutor txn, {
    required String outletId,
    required String productId,
  }) async {
    final snapshot = await txn.query(
      'outlet_stock',
      columns: ['server_qty', 'server_seq'],
      where:
          'outlet_id = ? AND product_id = ? '
          'AND server_seq IS NOT NULL AND server_qty IS NOT NULL',
      whereArgs: [outletId, productId],
      limit: 1,
    );
    if (snapshot.isEmpty) return;

    // Replayed in the order this till made them. A pending COUNT sets the
    // value instead of adding its delta: that delta was taken against an
    // older snapshot, and the server replaces it with one against its own
    // quantity. Only the movements made after the count add to it.
    final pending = await txn.query(
      'stock_movements',
      columns: ['delta', 'reason', 'counted_qty'],
      where:
          'outlet_id = ? AND product_id = ? AND origin = ? '
          'AND (server_seq IS NULL OR server_seq > ?)',
      whereArgs: [
        outletId,
        productId,
        originDevice,
        snapshot.first['server_seq'],
      ],
      orderBy: 'created_at ASC, rowid ASC',
    );
    var derived = (snapshot.first['server_qty'] as num).toInt();
    for (final m in pending) {
      final counted = (m['counted_qty'] as num?)?.toInt();
      if (m['reason'] == StockReason.count.wire && counted != null) {
        derived = counted;
      } else {
        derived += (m['delta'] as num).toInt();
      }
    }

    await txn.update(
      'outlet_stock',
      {'stock': derived},
      where: 'outlet_id = ? AND product_id = ?',
      whereArgs: [outletId, productId],
    );
  }

  /// Applies a pulled `outlet_stock` row: the server's count at [seq].
  ///
  /// A snapshot older than the one held is ignored — pages arrive in sequence
  /// order, but a later edit must never be overwritten by an earlier number.
  /// The first snapshot is also what makes a product tracked at this branch.
  static Future<void> applyServerSnapshotWithin(
    DatabaseExecutor txn, {
    required String outletId,
    required String productId,
    required int qty,
    required int seq,
  }) async {
    final existing = await txn.query(
      'outlet_stock',
      columns: ['server_seq'],
      where: 'outlet_id = ? AND product_id = ?',
      whereArgs: [outletId, productId],
      limit: 1,
    );
    if (existing.isEmpty) {
      await txn.insert('outlet_stock', {
        'outlet_id': outletId,
        'product_id': productId,
        'stock': qty,
        'server_qty': qty,
        'server_seq': seq,
      });
    } else {
      final held = (existing.first['server_seq'] as num?)?.toInt();
      if (held != null && held >= seq) return;
      await txn.update(
        'outlet_stock',
        {'server_qty': qty, 'server_seq': seq},
        where: 'outlet_id = ? AND product_id = ?',
        whereArgs: [outletId, productId],
      );
    }
    await recomputeWithin(txn, outletId: outletId, productId: productId);
  }

  /// Applies a pulled `stock_movements` row.
  ///
  /// This till's own movement coming back is marked applied at its
  /// `stock_seq` — the pull can settle it even when the push response was
  /// lost. Anyone else's is stored as history, never as a pending delta: the
  /// snapshot already contains it.
  static Future<void> applyServerMovementWithin(
    DatabaseExecutor txn,
    Map<String, dynamic> row,
  ) async {
    final id = row['id'] as String;
    final outletId = row['outlet_id'] as String;
    final productId = row['product_id'] as String;
    final stockSeq = (row['stock_seq'] as num?)?.toInt();

    final existing = await txn.query(
      'stock_movements',
      columns: ['server_seq'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      if (existing.first['server_seq'] == null && stockSeq != null) {
        await txn.update(
          'stock_movements',
          {'server_seq': stockSeq},
          where: 'id = ?',
          whereArgs: [id],
        );
        await recomputeWithin(txn, outletId: outletId, productId: productId);
      }
      return;
    }

    await txn.insert('stock_movements', {
      'id': id,
      'outlet_id': outletId,
      'product_id': productId,
      'product_name': row['product_name'] as String? ?? '',
      'delta': (row['delta_qty'] as num).toInt(),
      'balance_after': (row['balance_after'] as num).toInt(),
      'reason': row['reason'] as String,
      'created_at': (row['occurred_at_ms'] as num).toInt(),
      'employee_id': '',
      'employee_name': row['employee_name'] as String? ?? '',
      'note': row['note'] as String?,
      'counted_qty': (row['counted_qty'] as num?)?.toInt(),
      'server_seq': stockSeq,
      'origin': originServer,
    });
  }

  /// The server accepted this till's movement at projection [stockSeq].
  static Future<void> markAppliedWithin(
    DatabaseExecutor txn,
    String movementId,
    int stockSeq,
  ) async {
    final rows = await txn.query(
      'stock_movements',
      columns: ['outlet_id', 'product_id', 'server_seq'],
      where: 'id = ?',
      whereArgs: [movementId],
      limit: 1,
    );
    if (rows.isEmpty || rows.first['server_seq'] != null) return;
    await txn.update(
      'stock_movements',
      {'server_seq': stockSeq},
      where: 'id = ?',
      whereArgs: [movementId],
    );
    final outletId = rows.first['outlet_id'] as String?;
    if (outletId == null) return;
    await recomputeWithin(
      txn,
      outletId: outletId,
      productId: rows.first['product_id'] as String,
    );
  }

  Future<void> markApplied(String movementId, int stockSeq) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) => markAppliedWithin(txn, movementId, stockSeq));
  }
}
