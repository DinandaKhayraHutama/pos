import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/bill.dart';
import 'bill_push.dart';
import 'stock_movement_push.dart';
import 'wire_values.dart';

/// A batch of lines sent to the kitchen, as `POST /api/v2/sync/push` receives
/// it (the `KitchenDispatch` schema, Device API 2.9.0, paritas F4).
///
/// **The lines and the stock they consumed are immutable** and travel
/// together: the server commits the dispatch and its sale movements in one
/// transaction, exactly once, and an exact retry returns what it recorded the
/// first time. Only the kitchen status moves afterwards, as a newer revision
/// of the same row.
///
/// Queued strictly oldest first, like standalone stock movements: a dispatch
/// made before a stock count has to reach the server before the count does,
/// or the count absorbs it.
class KitchenDispatchPush {
  const KitchenDispatchPush._();

  static const entity = 'kitchen_dispatches';

  static Future<Map<String, Object?>?> payloadWithin(
    DatabaseExecutor txn,
    String dispatchId,
  ) async {
    final rows = await txn.query(
      'kitchen_dispatches',
      where: 'id = ?',
      whereArgs: [dispatchId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final dispatch = KitchenDispatch.fromMap(rows.first);
    if (dispatch.origin != 'device') {
      // A batch another till sent, handed over with a claimed bill: its
      // lines and stock are the server's already, and a status report has
      // to repeat them unchanged. Only the status and the generation this
      // till holds the bill at are ours.
      final raw = rows.first['payload'];
      if (raw is! String) return null;
      final bills = await txn.query(
        'bills',
        columns: ['owner_generation'],
        where: 'id = ?',
        whereArgs: [dispatch.billId],
        limit: 1,
      );
      if (bills.isEmpty) return null;
      final stored = (jsonDecode(raw) as Map).cast<String, Object?>()
        ..remove('revision');
      return {
        ...stored,
        'owner_generation': wireInt(bills.first['owner_generation']),
        'status': dispatch.status.wire,
        'status_changed_at_ms': dispatch.statusChangedAt.millisecondsSinceEpoch,
      };
    }
    final bills = await txn.query(
      'bills',
      columns: ['owner_generation', 'pos_session_id'],
      where: 'id = ?',
      whereArgs: [dispatch.billId],
      limit: 1,
    );
    if (bills.isEmpty) return null;
    final lineRows = await txn.query(
      'bill_lines',
      where: 'dispatch_id = ?',
      whereArgs: [dispatchId],
      orderBy: 'seq ASC, rowid ASC',
    );
    final effects = <Map<String, Object?>>[];
    final movements = await txn.query(
      'stock_movements',
      columns: ['id'],
      where: 'source_kind = ? AND source_id = ?',
      whereArgs: ['dispatch', dispatchId],
      orderBy: 'id',
    );
    for (final m in movements) {
      final payload = await StockMovementPush.payloadWithin(
        txn,
        m['id'] as String,
      );
      if (payload != null) effects.add({...payload, 'revision': 1});
    }

    return {
      'id': dispatch.id,
      'bill_id': dispatch.billId,
      // The generation the till holds the bill at NOW: a status moved after
      // a claim is reported by the new owner, under its generation.
      'owner_generation': wireInt(bills.first['owner_generation']),
      'pos_session_id': dispatch.posSessionId ?? bills.first['pos_session_id'],
      'occurred_at_ms': dispatch.occurredAt.millisecondsSinceEpoch,
      'employee_id': uuidOrNull(dispatch.employeeId),
      'employee_name': dispatch.employeeName,
      'status': dispatch.status.wire,
      'status_changed_at_ms': dispatch.statusChangedAt.millisecondsSinceEpoch,
      'lines': [
        for (final r in lineRows) BillPush.wireLine(BillLine.fromMap(r)),
      ],
      'stock_movements': effects,
    };
  }
}
