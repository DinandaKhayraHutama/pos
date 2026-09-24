import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/bill.dart';
import 'stock_movement_push.dart';
import 'wire_values.dart';

/// A saved bill as `POST /api/v2/sync/push` receives it (the `Bill` schema,
/// Device API 2.9.0, paritas F4).
///
/// **A snapshot at a revision, like a session.** Every save queues the whole
/// bill again; the outbox keeps the newest, and the server keeps the last one
/// it accepted. Lines already sent to the kitchen must come back identical in
/// every revision — the server refuses one that changed or dropped them.
///
/// Never `closed`: the receipt that settles the bill is what closes it on the
/// server, so a settled bill is not queued again. A cancelled bill carries its
/// cancellation and the returns of the lines that went back on the shelf,
/// committed with it in one transaction.
class BillPush {
  const BillPush._();

  static const entity = 'bills';

  static Future<Map<String, Object?>?> payloadWithin(
    DatabaseExecutor txn,
    String billId,
  ) async {
    final rows = await txn.query(
      'bills',
      where: 'id = ?',
      whereArgs: [billId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final lineRows = await txn.query(
      'bill_lines',
      where: 'bill_id = ?',
      whereArgs: [billId],
      orderBy: 'seq ASC, rowid ASC',
    );
    final bill = Bill.fromMap(
      rows.first,
      lines: [for (final r in lineRows) BillLine.fromMap(r)],
    );
    final cancelled = bill.status == BillStatus.cancelled;
    Map<String, Object?>? cancel;
    if (cancelled && bill.cancellation != null) {
      final c = bill.cancellation!;
      final returns = <Map<String, Object?>>[];
      final movements = await txn.query(
        'stock_movements',
        columns: ['id'],
        where: 'source_kind = ? AND source_id = ?',
        whereArgs: ['bill_cancel', billId],
        orderBy: 'id',
      );
      for (final m in movements) {
        final payload = await StockMovementPush.payloadWithin(
          txn,
          m['id'] as String,
        );
        if (payload != null) returns.add({...payload, 'revision': 1});
      }
      cancel = {
        'reason': c.reason,
        'authorized_by': c.authorizedBy,
        'authorized_by_id': uuidOrNull(c.authorizedById),
        'cancelled_at_ms': c.cancelledAt.millisecondsSinceEpoch,
        'decisions': [
          for (final e in c.decisions.entries)
            {
              'bill_line_id': e.key,
              'disposition': e.value ? 'restock' : 'waste',
            },
        ],
        'stock_movements': returns,
      };
    }

    return {
      'id': bill.id,
      'owner_generation': bill.ownerGeneration,
      'number': bill.number,
      // A settled bill is never queued again; anything but cancelled is open.
      'status': cancelled ? 'cancelled' : 'open',
      'pos_session_id': bill.posSessionId,
      'opened_at_ms': bill.openedAt.millisecondsSinceEpoch,
      'type': bill.type,
      'sales_type_id': uuidOrNull(bill.salesTypeId),
      'sales_type_name': bill.salesTypeName,
      'table_session_id': uuidOrNull(bill.tableSessionId),
      'table_id': uuidOrNull(bill.tableId),
      'table_name': bill.tableName,
      'customer_id': uuidOrNull(bill.customerId),
      'customer_name': bill.customerName,
      'served_by_id': uuidOrNull(bill.servedById),
      'served_by_name': bill.servedByName,
      'note': bill.note,
      'created_by_id': uuidOrNull(bill.createdById),
      'created_by_name': bill.createdByName,
      'pricing': _pricing(bill.pricing),
      'lines': [for (final line in bill.lines) wireLine(line)],
      'cancel': ?cancel,
    };
  }

  /// The frozen configuration as the contract carries it. Ids that are not
  /// UUIDs (demo-era rows) go up as null, like every other reference.
  static Map<String, Object?> _pricing(BillPricing p) {
    final json = p.toJson();
    return {
      ...json,
      'promo_id': uuidOrNull(p.promoId),
      'discount_id': uuidOrNull(p.discountId),
      'discount_authorized_by_id': uuidOrNull(p.discountAuthorizedById),
    };
  }

  /// One line as the contract carries it, identically inside the bill and
  /// inside the dispatch that sends it: references that are not UUIDs go up
  /// as null, exactly as a receipt's do.
  static Map<String, Object?> wireLine(BillLine line) {
    final w = line.toWire();
    return {
      ...w,
      'product_id': uuidOrNull(line.productId),
      'category_id': uuidOrNull(line.categoryId),
      'brand_id': uuidOrNull(line.brandId),
      'line_discount_id': uuidOrNull(line.lineDiscountId),
      'line_discount_authorized_by_id': uuidOrNull(
        line.lineDiscountAuthorizedById,
      ),
    };
  }

  /// A bill's pricing as its JSON column stores it, for callers that only
  /// hold the raw row.
  static BillPricing pricingOf(Object? raw) =>
      BillPricing.fromJson(raw is String ? jsonDecode(raw) : raw);
}
