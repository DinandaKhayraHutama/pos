import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/category_sales.dart';
import '../models/sales_report.dart';
import '../models/enums.dart';
import '../models/order.dart';
import '../models/order_item.dart';
import '../models/order_item_modifier.dart';
import '../models/stock_movement.dart';
import 'stock_repository.dart';

class OrderRepository {
  OrderRepository._();
  static final OrderRepository instance = OrderRepository._();

  static const _uuid = Uuid();

  Future<String> _nextNumber(Database db) async {
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM orders'),
    );
    final next = (count ?? 0) + 1;
    return 'ORD-${next.toString().padLeft(4, '0')}';
  }

  Future<Order> create({
    required OrderType type,
    required List<OrderItemDraft> items,
    required int subtotal,
    required int discount,
    required int tax, // PB1 amount — param name unchanged, meaning narrowed
    int serviceChargeAmount = 0,
    double? pb1Rate,
    double? serviceChargeRate,
    required int total,
    required int amountPaid,
    required PaymentMethod paymentMethod,
    required String cashierId,
    required String cashierName,
    String? outletId,
    String? outletName,
    // Which till rang it up and during which session. Nullable because a
    // legacy session carries no register, and refusing the sale over that
    // would block a till the app itself left half-configured.
    String? posId,
    String? posName,
    String? posSessionId,
    String? promoName,
    String? tableId,
    String? tableName,
    String? customerName,
    String? note,
  }) async {
    final db = await AppDatabase.instance.db;
    final id = _uuid.v4();
    final number = await _nextNumber(db);

    // Resolved here, deterministically, from `productId` alone — never from
    // a Riverpod provider. A provider watched only by whichever widget
    // happens to be mounted is the wrong thing to depend on for a snapshot
    // that has to be right every single time an order is written; a plain
    // read against the same tables this transaction already touches has no
    // such lifecycle to reason about. Two small `IN (...)` queries cover
    // every line regardless of how many products are on the order.
    final productIds = {for (final item in items) item.productId};
    final categoryByProduct = <String, String?>{};
    if (productIds.isNotEmpty) {
      final rows = await db.query(
        'products',
        columns: ['id', 'category_id'],
        where: 'id IN (${List.filled(productIds.length, '?').join(',')})',
        whereArgs: productIds.toList(),
      );
      for (final r in rows) {
        categoryByProduct[r['id'] as String] = r['category_id'] as String?;
      }
    }
    final categoryIds = categoryByProduct.values.whereType<String>().toSet();
    final categoryNames = <String, String>{};
    if (categoryIds.isNotEmpty) {
      final rows = await db.query(
        'categories',
        columns: ['id', 'name'],
        where: 'id IN (${List.filled(categoryIds.length, '?').join(',')})',
        whereArgs: categoryIds.toList(),
      );
      for (final r in rows) {
        categoryNames[r['id'] as String] = r['name'] as String;
      }
    }

    // Build the OrderItems up front so the returned Order carries the same
    // rows that get persisted. Previously this was built with `items: const
    // []` and `_SuccessReceipt.build` crashed on `order.items.first` every
    // checkout.
    final persistedItems = <OrderItem>[];
    for (final item in items) {
      final itemId = _uuid.v4();
      final categoryId = categoryByProduct[item.productId];
      persistedItems.add(
        OrderItem(
          id: itemId,
          orderId: id,
          productId: item.productId,
          productName: item.productName,
          variantName: item.variantName,
          unitPrice: item.unitPrice,
          unitCost: item.unitCost,
          quantity: item.quantity,
          note: item.note,
          modifiers: [
            for (var i = 0; i < item.modifiers.length; i++)
              OrderItemModifier(
                id: _uuid.v4(),
                orderItemId: itemId,
                groupName: item.modifiers[i].groupName,
                optionName: item.modifiers[i].optionName,
                priceDelta: item.modifiers[i].priceDelta,
                sortOrder: i,
              ),
          ],
          categoryId: categoryId,
          categoryName: categoryId == null ? null : categoryNames[categoryId],
        ),
      );
    }

    final order = Order(
      id: id,
      number: number,
      createdAt: DateTime.now(),
      type: type,
      table: tableId != null
          ? TableAssignment(tableId: tableId, tableName: tableName ?? '')
          : null,
      customerName: customerName,
      note: note,
      subtotal: subtotal,
      discount: discount,
      tax: tax,
      serviceChargeAmount: serviceChargeAmount,
      pb1Rate: pb1Rate,
      serviceChargeRate: serviceChargeRate,
      total: total,
      amountPaid: amountPaid,
      paymentMethod: paymentMethod,
      status: OrderStatus.preparing,
      cashierId: cashierId,
      cashierName: cashierName,
      outletId: outletId,
      outletName: outletName,
      posId: posId,
      posName: posName,
      posSessionId: posSessionId,
      promoName: promoName,
      items: persistedItems,
    );

    await db.transaction((txn) async {
      await txn.insert(
        'orders',
        order.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (final oi in persistedItems) {
        await txn.insert('order_items', oi.toMap());
        for (final m in oi.modifiers) {
          await txn.insert('order_item_modifiers', m.toMap());
        }
      }
      // Draw down stock inside the same transaction as the order, so a
      // failure cannot leave a sale recorded with the stock untouched (or the
      // reverse), and the ledger row lands with it.
      await _applyStock(
        txn,
        outletId: outletId,
        // Several modifier selections can create distinct lines for one SKU.
        quantities: persistedItems.fold<Map<String, int>>({}, (quantities, oi) {
          quantities.update(
            oi.productId,
            (qty) => qty - oi.quantity,
            ifAbsent: () => -oi.quantity,
          );
          return quantities;
        }),
        reason: StockReason.sale,
        employeeId: cashierId,
        employeeName: cashierName,
        note: order.number,
      );
    });

    return order;
  }

  /// Moves stock for a set of products and writes the matching ledger rows.
  ///
  /// [quantities] is signed: negative sells, positive returns. Untracked
  /// products (`stock IS NULL`) are skipped entirely — they have no count to
  /// move and no history worth writing. The floor at zero keeps a stale cart
  /// or a double-tap from driving a shelf negative; the sale is still
  /// recorded, which is what the cashier standing there needs.
  Future<void> _applyStock(
    DatabaseExecutor txn, {
    required String? outletId,
    required Map<String, int> quantities,
    required StockReason reason,
    required String employeeId,
    required String employeeName,
    String? note,
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
      final current = await StockRepository.countAt(
        txn,
        outletId: outletId,
        productId: e.key,
      );
      if (current == null) continue; // untracked

      final next = (current + e.value).clamp(0, 1 << 31);
      if (next == current) continue;
      await StockRepository.setCountAt(
        txn,
        outletId: outletId,
        productId: e.key,
        stock: next,
      );
      movements[e.key] = (
        name: rows.first['name'] as String,
        // The clamped delta, not the requested one: the ledger records what
        // happened to the shelf, not what was asked for.
        delta: next - current,
        balanceAfter: next,
      );
    }

    await StockRepository.recordWithin(
      txn,
      outletId: outletId,
      movements: movements,
      reason: reason,
      employeeId: employeeId,
      employeeName: employeeName,
      note: note,
    );
  }

  /// Puts stock back for an order that was voided or refunded.
  ///
  /// Untracked products are skipped, and callers must only invoke this on a
  /// transition INTO a returning status — crediting twice is the failure mode
  /// this guard exists for, and it lives in [_settle] rather than here.
  Future<void> restockCancelledOrder(
    String orderId, {
    String employeeId = '',
    String employeeName = '',
    String? note,
  }) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      await _restockWithin(
        txn,
        orderId,
        employeeId: employeeId,
        employeeName: employeeName,
        note: note,
      );
    });
  }

  Future<void> _restockWithin(
    DatabaseExecutor txn,
    String orderId, {
    required String employeeId,
    required String employeeName,
    String? note,
  }) async {
    final rows = await txn.query(
      'order_items',
      columns: ['product_id', 'quantity'],
      where: 'order_id = ?',
      whereArgs: [orderId],
    );
    final quantities = <String, int>{};
    for (final r in rows) {
      final id = r['product_id'] as String;
      quantities[id] = (quantities[id] ?? 0) + (r['quantity'] as num).toInt();
    }
    // Back onto the shelf it came off, which is the branch that sold it — not
    // whichever branch the person pressing Void happens to be standing in. A
    // manager can void a Kemang order from the Bintaro tablet, and crediting
    // Bintaro's shelf would create stock out of nothing in one shop while
    // leaving the other short.
    final order = await txn.query(
      'orders',
      columns: ['outlet_id'],
      where: 'id = ?',
      whereArgs: [orderId],
      limit: 1,
    );
    await _applyStock(
      txn,
      outletId: order.isEmpty ? null : order.first['outlet_id'] as String?,
      quantities: quantities,
      reason: StockReason.voidReturn,
      employeeId: employeeId,
      employeeName: employeeName,
      note: note,
    );
  }

  /// Recent orders, newest first.
  ///
  /// [cashierId] and [since] are what make the same list serve two roles: a
  /// manager or owner reads the whole history, while a cashier is scoped to
  /// their own sales for the current day. Scoping in SQL rather than filtering
  /// in the UI matters — a filtered-in-Dart list still pulled every colleague's
  /// takings into memory, which is exactly what the limit exists to prevent.
  /// Restricts a query to one branch.
  ///
  /// Every revenue aggregate carries this for exactly the reason they all
  /// carry [kRevenueStatusSql]: a report where six figures are scoped to
  /// Bintaro and the seventh sums the whole chain is a set of numbers that do
  /// not add up, and nobody notices until someone tries to reconcile them.
  ///
  /// Null means the whole chain on purpose — that is a real question an owner
  /// asks, and it has to be distinguishable from "nobody remembered to scope
  /// this", which is why callers pass it explicitly rather than defaulting.
  static String _outletSql(String? outletId, {String prefix = ''}) =>
      outletId == null ? '' : 'AND ${prefix}outlet_id = ? ';

  static List<Object?> _outletArgs(String? outletId) =>
      outletId == null ? const [] : [outletId];

  Future<List<Order>> recent({
    int limit = 50,
    OrderStatus? status,
    String? cashierId,
    DateTime? since,
    String? outletId,
  }) async {
    final db = await AppDatabase.instance.db;
    final clauses = <String>[];
    final args = <Object?>[];
    if (status != null) {
      clauses.add('o.status = ?');
      args.add(status.wire);
    }
    if (cashierId != null) {
      clauses.add('o.cashier_id = ?');
      args.add(cashierId);
    }
    if (since != null) {
      clauses.add('o.created_at >= ?');
      args.add(since.millisecondsSinceEpoch);
    }
    if (outletId != null) {
      clauses.add('o.outlet_id = ?');
      args.add(outletId);
    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = await db.rawQuery(
      '''
      SELECT o.*, COUNT(oi.id) AS item_count
      FROM orders o
      LEFT JOIN order_items oi ON oi.order_id = o.id
      $where
      GROUP BY o.id
      ORDER BY o.created_at DESC
      LIMIT ?
      ''',
      [...args, limit],
    );
    return rows.map((m) => Order.fromMapRow(m)).toList();
  }

  Future<Order?> byId(String id) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.rawQuery(
      'SELECT * FROM orders WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return null;
    final itemRows = await db.query(
      'order_items',
      where: 'order_id = ?',
      whereArgs: [id],
    );
    final itemIds = itemRows.map((r) => r['id'] as String).toList();
    // A second query, not N — every line's modifiers in one round trip,
    // grouped back onto its own item in Dart. `recent()` never needs this
    // (it only counts items for the list row), so it stays untouched.
    final modifierRows = itemIds.isEmpty
        ? const <Map<String, Object?>>[]
        : await db.query(
            'order_item_modifiers',
            where:
                'order_item_id IN (${List.filled(itemIds.length, '?').join(',')})',
            whereArgs: itemIds,
            orderBy: 'sort_order ASC',
          );
    final modifiersByItem = <String, List<OrderItemModifier>>{};
    for (final r in modifierRows) {
      (modifiersByItem[r['order_item_id'] as String] ??= []).add(
        OrderItemModifier.fromMap(r),
      );
    }
    final items = [
      for (final r in itemRows)
        OrderItem.fromMap(r, modifiers: modifiersByItem[r['id']] ?? const []),
    ];
    return Order.fromMapRow(rows.first, items: items);
  }

  /// Moves an order along the kitchen flow.
  ///
  /// Void and refund do NOT come through here — they need a name and a reason
  /// attached, so they have their own methods and their own guard. Passing a
  /// returning status to this method throws rather than quietly voiding
  /// something with nobody's name on it.
  Future<void> setStatus(String id, OrderStatus status) async {
    if (status.returnsStock) {
      throw ArgumentError(
        'Use voidOrder() or refundOrder() — $status needs an authorizer',
      );
    }
    final db = await AppDatabase.instance.db;
    await db.update(
      'orders',
      {'status': status.wire},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Strikes out an order and returns its goods to the shelf.
  ///
  /// [authorizedBy] is the name of whoever approved it — a manager or owner,
  /// resolved by the PIN prompt before this is called. It is written in the
  /// same update as the status, so a void with no name on it cannot exist.
  Future<void> voidOrder({
    required String orderId,
    required String authorizedBy,
    required String reason,
    String authorizedById = '',
  }) => _settle(
    orderId: orderId,
    status: OrderStatus.cancelled,
    authorizedBy: authorizedBy,
    authorizedById: authorizedById,
    reason: reason,
  );

  /// Gives money back on an order that already counted.
  ///
  /// [amount] defaults to the order total. Recorded separately from the total
  /// so a partial refund keeps the original sale legible.
  Future<void> refundOrder({
    required String orderId,
    required String authorizedBy,
    required String reason,
    int? amount,
    String authorizedById = '',
  }) => _settle(
    orderId: orderId,
    status: OrderStatus.refunded,
    authorizedBy: authorizedBy,
    authorizedById: authorizedById,
    reason: reason,
    refundAmount: amount,
  );

  /// The shared body of void and refund.
  ///
  /// Reads the previous status inside the transaction and no-ops when the
  /// order is already settled. That guard is the whole reason this is one
  /// method: a double-tap on "Void" would otherwise credit the stock twice,
  /// and the second credit is invisible until someone counts the shelf.
  Future<void> _settle({
    required String orderId,
    required OrderStatus status,
    required String authorizedBy,
    required String authorizedById,
    required String reason,
    int? refundAmount,
  }) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'orders',
        columns: ['status', 'total'],
        where: 'id = ?',
        whereArgs: [orderId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final previous = OrderStatusX.fromWire(rows.first['status'] as String);
      if (previous.returnsStock) return; // already settled

      await txn.update(
        'orders',
        {
          'status': status.wire,
          'authorized_by': authorizedBy,
          'void_reason': reason,
          if (status == OrderStatus.refunded)
            'refunded_amount':
                refundAmount ?? (rows.first['total'] as num).toInt(),
        },
        where: 'id = ?',
        whereArgs: [orderId],
      );

      await _restockWithin(
        txn,
        orderId,
        employeeId: authorizedById,
        employeeName: authorizedBy,
        note: reason,
      );
    });
  }

  /// Revenue + count for today (or any [day]).
  ///
  /// Counts every order that was not cancelled, rather than only `paid` ones.
  /// Checkout already collects payment (method, amount tendered, change), so a
  /// sale is revenue the moment it is rung up; `preparing` / `ready` / `served`
  /// describe where the food is, not whether the money came in. Filtering on
  /// `paid` meant the Dashboard read Rp 0 straight after a sale.
  ///
  /// The order-level aggregates deliberately do NOT join `order_items`: that
  /// join fans each order out into one row per line, which multiplied both
  /// `SUM(total)` and `COUNT(*)` by the number of items on the order. Items
  /// sold is counted in its own subquery.
  Future<({int revenue, int count, int itemsSold})> summaryForDay(
    DateTime day, {
    String? outletId,
  }) async {
    final db = await AppDatabase.instance.db;
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final from = start.millisecondsSinceEpoch;
    final to = end.millisecondsSinceEpoch;
    final rows = await db.rawQuery(
      '''
      SELECT
        (SELECT COALESCE(SUM(total), 0) FROM orders
          WHERE $kRevenueStatusSql
            AND created_at >= ? AND created_at < ?
            ${_outletSql(outletId)}) AS revenue,
        (SELECT COUNT(*) FROM orders
          WHERE $kRevenueStatusSql
            AND created_at >= ? AND created_at < ?
            ${_outletSql(outletId)}) AS count,
        (SELECT COALESCE(SUM(oi.quantity), 0)
           FROM order_items oi
           JOIN orders o ON o.id = oi.order_id
          WHERE o.$kRevenueStatusSql
            AND o.created_at >= ? AND o.created_at < ?
            ${_outletSql(outletId, prefix: 'o.')}) AS items
      ''',
      [
        from,
        to,
        ..._outletArgs(outletId),
        from,
        to,
        ..._outletArgs(outletId),
        from,
        to,
        ..._outletArgs(outletId),
      ],
    );
    final m = rows.first;
    return (
      revenue: (m['revenue'] as num?)?.toInt() ?? 0,
      count: (m['count'] as num?)?.toInt() ?? 0,
      itemsSold: (m['items'] as num?)?.toInt() ?? 0,
    );
  }

  /// Everything the sales report needs for [from]..[to], in one pass.
  ///
  /// A report screen that fired one query per tile would show tiles updating
  /// at different moments and, worse, could show figures from two different
  /// instants side by side. This returns a single consistent snapshot.
  ///
  /// [to] is inclusive of its whole day: callers pass a date, and a customer
  /// who bought at 23:50 belongs to that date.
  Future<SalesReport> report({
    required DateTime from,
    required DateTime to,
    String? outletId,
  }) async {
    final db = await AppDatabase.instance.db;
    final start = DateTime(
      from.year,
      from.month,
      from.day,
    ).millisecondsSinceEpoch;
    final end = DateTime(
      to.year,
      to.month,
      to.day,
    ).add(const Duration(days: 1)).millisecondsSinceEpoch;

    // Order-level aggregates never join order_items — that join fans each
    // order into one row per line and multiplies every SUM by its item count.
    final totals = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(total), 0)     AS revenue,
        COALESCE(SUM(subtotal), 0)  AS subtotal,
        COALESCE(SUM(discount), 0)  AS discount,
        COALESCE(SUM(tax), 0)       AS tax,
        COALESCE(SUM(service_charge_amount), 0) AS service_charge,
        COUNT(*)                    AS order_count
      FROM orders
      WHERE $kRevenueStatusSql AND created_at >= ? AND created_at < ?
        ${_outletSql(outletId)}
      ''',
      [start, end, ..._outletArgs(outletId)],
    );

    final byPayment = await db.rawQuery(
      '''
      SELECT payment_method AS k, COALESCE(SUM(total), 0) AS v, COUNT(*) AS c
      FROM orders
      WHERE $kRevenueStatusSql AND created_at >= ? AND created_at < ?
        ${_outletSql(outletId)}
      GROUP BY payment_method
      ''',
      [start, end, ..._outletArgs(outletId)],
    );

    final byType = await db.rawQuery(
      '''
      SELECT type AS k, COALESCE(SUM(total), 0) AS v, COUNT(*) AS c
      FROM orders
      WHERE $kRevenueStatusSql AND created_at >= ? AND created_at < ?
        ${_outletSql(outletId)}
      GROUP BY type
      ''',
      [start, end, ..._outletArgs(outletId)],
    );

    final byCashier = await db.rawQuery(
      '''
      SELECT cashier_name AS k, COALESCE(SUM(total), 0) AS v, COUNT(*) AS c
      FROM orders
      WHERE $kRevenueStatusSql AND created_at >= ? AND created_at < ?
        ${_outletSql(outletId)}
      GROUP BY cashier_id
      ORDER BY v DESC
      ''',
      [start, end, ..._outletArgs(outletId)],
    );

    // Per-day series for the trend. Grouped in SQL by local-midnight buckets
    // computed in Dart would need a per-row timezone conversion, so the bucket
    // key is derived from the epoch in Dart instead — correct for any offset.
    final daily = await db.rawQuery(
      '''
      SELECT created_at AS at, total AS v
      FROM orders
      WHERE $kRevenueStatusSql AND created_at >= ? AND created_at < ?
        ${_outletSql(outletId)}
      ''',
      [start, end, ..._outletArgs(outletId)],
    );
    final perDay = <DateTime, int>{};
    for (final r in daily) {
      final dt = DateTime.fromMillisecondsSinceEpoch((r['at'] as num).toInt());
      final key = DateTime(dt.year, dt.month, dt.day);
      perDay[key] = (perDay[key] ?? 0) + (r['v'] as num).toInt();
    }

    final items = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(oi.quantity), 0) AS items,
        -- Cost of goods, from the price frozen on each line at sale time.
        COALESCE(SUM(COALESCE(oi.unit_cost, 0) * oi.quantity), 0) AS cogs,
        -- How many of those units actually carried a cost. Without it a
        -- catalogue that is half-costed reports a margin that looks great and
        -- means nothing.
        COALESCE(SUM(CASE WHEN oi.unit_cost IS NULL THEN 0 ELSE oi.quantity END), 0)
          AS costed_items
      FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      WHERE o.$kRevenueStatusSql
        AND o.created_at >= ? AND o.created_at < ?
        ${_outletSql(outletId, prefix: 'o.')}
      ''',
      [start, end, ..._outletArgs(outletId)],
    );

    // Cancelled and refunded in one pass, split by status: two separate
    // queries over the same window would be two round trips for one row.
    final undone = await db.rawQuery(
      '''
      SELECT status AS k,
             COUNT(*) AS c,
             COALESCE(SUM(COALESCE(refunded_amount, total)), 0) AS v
      FROM orders
      WHERE status IN ('cancelled', 'refunded')
        AND created_at >= ? AND created_at < ?
        ${_outletSql(outletId)}
      GROUP BY status
      ''',
      [start, end, ..._outletArgs(outletId)],
    );
    int undoneCount(String status) => undone
        .where((r) => r['k'] == status)
        .fold(0, (a, r) => a + (r['c'] as num).toInt());
    int undoneValue(String status) => undone
        .where((r) => r['k'] == status)
        .fold(0, (a, r) => a + (r['v'] as num).toInt());

    Map<String, ReportBucket> bucket(List<Map<String, Object?>> rows) => {
      for (final r in rows)
        (r['k'] as String): ReportBucket(
          amount: (r['v'] as num).toInt(),
          count: (r['c'] as num).toInt(),
        ),
    };

    // Category breakdown. Reads oi.category_id/category_name directly — the
    // snapshot v17 wrote — rather than joining through products, and only
    // LEFT JOINs categories for the CURRENT name (so a rename merges into one
    // row instead of splitting the range across old/new names). No join to
    // products at all: category_id already lives on order_items.
    final categoryRows = await db.rawQuery(
      '''
      SELECT
        o.id AS order_id,
        o.discount AS order_discount,
        o.subtotal AS order_subtotal,
        o.created_at AS order_created_at,
        oi.category_id AS category_id,
        oi.category_name AS snapshot_name,
        c.name AS live_name,
        COALESCE(SUM(oi.unit_price * oi.quantity), 0) AS line_total,
        COALESCE(SUM(oi.quantity), 0) AS qty
      FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      LEFT JOIN categories c ON c.id = oi.category_id
      WHERE o.$kRevenueStatusSql
        AND o.created_at >= ? AND o.created_at < ?
        ${_outletSql(outletId, prefix: 'o.')}
      GROUP BY o.id, oi.category_id
      ''',
      [start, end, ..._outletArgs(outletId)],
    );
    final byCategory = aggregateCategorySales(categoryRows);

    final t = totals.first;
    final itemsSold = (items.first['items'] as num).toInt();
    return SalesReport(
      from: DateTime.fromMillisecondsSinceEpoch(start),
      to: to,
      revenue: (t['revenue'] as num).toInt(),
      subtotal: (t['subtotal'] as num).toInt(),
      discount: (t['discount'] as num).toInt(),
      tax: (t['tax'] as num).toInt(),
      serviceCharge: (t['service_charge'] as num).toInt(),
      orderCount: (t['order_count'] as num).toInt(),
      itemsSold: itemsSold,
      cancelledCount: undoneCount('cancelled'),
      cancelledValue: undoneValue('cancelled'),
      refundedCount: undoneCount('refunded'),
      refundedValue: undoneValue('refunded'),
      costOfGoods: (items.first['cogs'] as num).toInt(),
      costCoverage: itemsSold == 0
          ? 0
          : (items.first['costed_items'] as num).toInt() / itemsSold,
      byPaymentMethod: bucket(byPayment),
      byOrderType: bucket(byType),
      byCashier: bucket(byCashier),
      byCategory: byCategory,
      perDay: perDay,
    );
  }

  /// Turns the raw per-(order, category) rows from [report]'s category query
  /// into a final [CategorySales] list — sorted by [CategorySales.netSales]
  /// descending, contribution percentages already computed.
  ///
  /// Two passes, each independent of row order:
  ///
  ///  1. **Money**, grouped by order first. Discount lives on `orders`, one
  ///     number per order, not per line — so it is allocated to each
  ///     category's share of THAT order's subtotal using a largest-remainder
  ///     split: every category gets `floor(discount * lineTotal /
  ///     subtotal)`, and the few rupiah a floor drops are handed to the
  ///     category with the largest line total in that same order. This is
  ///     what guarantees `Σ netSales == Σ (orders.subtotal - orders.discount)`
  ///     EXACTLY for the whole report, not approximately — floors alone would
  ///     drift low by up to `categories_in_that_order - 1` rupiah per order.
  ///
  ///  2. **Display name**, resolved independently of the money pass so
  ///     processing order can never make a stale name win: a live category
  ///     name (the current JOIN result) always wins when present — every row
  ///     sharing a category id has the same live name, so this is idempotent
  ///     — and only falls back to the newest SNAPSHOT name (by the owning
  ///     order's `created_at`) when the category has since been deleted.
  ///     [CategorySales.uncategorizedId] rows get neither (`category_id`
  ///     itself is null there) and are left with an empty name for the
  ///     caller to localise.
  @visibleForTesting
  List<CategorySales> aggregateCategorySales(List<Map<String, Object?>> rows) {
    String keyOf(Map<String, Object?> r) =>
        (r['category_id'] as String?) ?? CategorySales.uncategorizedId;

    final byOrder = <String, List<Map<String, Object?>>>{};
    for (final r in rows) {
      (byOrder[r['order_id'] as String] ??= []).add(r);
    }

    final gross = <String, int>{};
    final net = <String, int>{};
    final items = <String, int>{};

    for (final orderRows in byOrder.values) {
      final discount = (orderRows.first['order_discount'] as num).toInt();
      final subtotal = (orderRows.first['order_subtotal'] as num).toInt();

      final shares = <int>[];
      var allocated = 0;
      for (final r in orderRows) {
        final lineTotal = (r['line_total'] as num).toInt();
        // subtotal == 0 implies discount == 0 too (CartState.discountAmount
        // clamps discount to [0, subtotal]), so this never silently drops a
        // real discount — there is never one left over to allocate.
        final share = subtotal == 0 ? 0 : (discount * lineTotal) ~/ subtotal;
        shares.add(share);
        allocated += share;
      }

      final remainder = discount - allocated;
      if (remainder != 0) {
        var pick = 0;
        for (var i = 1; i < orderRows.length; i++) {
          final pickTotal = (orderRows[pick]['line_total'] as num).toInt();
          final candidateTotal = (orderRows[i]['line_total'] as num).toInt();
          if (candidateTotal > pickTotal ||
              (candidateTotal == pickTotal &&
                  keyOf(orderRows[i]).compareTo(keyOf(orderRows[pick])) < 0)) {
            pick = i;
          }
        }
        shares[pick] += remainder;
      }

      for (var i = 0; i < orderRows.length; i++) {
        final key = keyOf(orderRows[i]);
        final lineTotal = (orderRows[i]['line_total'] as num).toInt();
        final qty = (orderRows[i]['qty'] as num).toInt();
        gross[key] = (gross[key] ?? 0) + lineTotal;
        // Net is gross MINUS its discount share, not the share itself.
        net[key] = (net[key] ?? 0) + (lineTotal - shares[i]);
        items[key] = (items[key] ?? 0) + qty;
      }
    }

    final names = <String, String>{};
    // Tracked separately from `names.containsKey` on purpose: a snapshot
    // fallback recorded on an earlier row must stay open to being replaced
    // by a NEWER snapshot on a later row — only a LIVE name closes that off,
    // so this set (not `names`' own keys) is what "already resolved" means.
    final liveResolved = <String>{};
    final nameAges = <String, int>{};
    for (final r in rows) {
      final key = keyOf(r);
      final liveName = r['live_name'] as String?;
      if (liveName != null) {
        names[key] = liveName;
        liveResolved.add(key);
        continue;
      }
      if (liveResolved.contains(key)) continue;
      final snapshotName = r['snapshot_name'] as String?;
      if (snapshotName == null) continue;
      final createdAt = (r['order_created_at'] as num).toInt();
      final bestAt = nameAges[key];
      if (bestAt == null || createdAt > bestAt) {
        names[key] = snapshotName;
        nameAges[key] = createdAt;
      }
    }

    final totalNet = net.values.fold(0, (a, v) => a + v);
    final result = [
      for (final key in gross.keys)
        CategorySales(
          categoryId: key,
          categoryName: names[key] ?? '',
          itemsSold: items[key] ?? 0,
          grossSales: gross[key] ?? 0,
          netSales: net[key] ?? 0,
          contributionPercent: totalNet == 0
              ? 0
              : (net[key] ?? 0) * 100 / totalNet,
        ),
    ];
    result.sort((a, b) => b.netSales.compareTo(a.netSales));
    return result;
  }

  /// Top products by quantity within [daysBack].
  Future<List<({String name, String? iconKey, int qty, int revenue})>>
  topProducts({int daysBack = 7, int limit = 5, String? outletId}) async {
    final db = await AppDatabase.instance.db;
    final since = DateTime.now().subtract(Duration(days: daysBack));
    final rows = await db.rawQuery(
      '''
      SELECT oi.product_name AS name,
             p.icon_key AS icon_key,
             SUM(oi.quantity) AS qty,
             SUM(oi.unit_price * oi.quantity) AS revenue
      FROM order_items oi
      INNER JOIN orders o ON o.id = oi.order_id
      LEFT JOIN products p ON p.id = oi.product_id
      WHERE o.$kRevenueStatusSql AND o.created_at >= ?
        ${_outletSql(outletId, prefix: 'o.')}
      GROUP BY oi.product_id
      ORDER BY qty DESC
      LIMIT ?
      ''',
      [since.millisecondsSinceEpoch, ..._outletArgs(outletId), limit],
    );
    return rows
        .map(
          (m) => (
            name: m['name'] as String,
            iconKey: m['icon_key'] as String?,
            qty: (m['qty'] as num?)?.toInt() ?? 0,
            revenue: (m['revenue'] as num?)?.toInt() ?? 0,
          ),
        )
        .toList();
  }
}

class OrderItemDraft {
  final String productId;
  final String productName;

  /// Chosen variant, or null when the product has none.
  final String? variantName;

  /// Price per unit with the variant delta already applied.
  final int unitPrice;

  /// Cost per unit at the moment of sale, copied onto the line so a later
  /// price edit cannot rewrite reported profit.
  final int? unitCost;

  final int quantity;
  final String? note;

  /// Modifiers picked on this line — a record per selected option, not per
  /// group, so a "multiple" group with two picks contributes two entries.
  /// `category_id`/`category_name` are deliberately NOT here: [create]
  /// resolves them itself from [productId], so a caller never needs to know
  /// about categories to place an order.
  final List<({String groupName, String optionName, int priceDelta})> modifiers;

  const OrderItemDraft({
    required this.productId,
    required this.productName,
    required this.unitPrice,
    required this.quantity,
    this.variantName,
    this.unitCost,
    this.note,
    this.modifiers = const [],
  });
}
