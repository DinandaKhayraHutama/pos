import 'package:sqflite/sqflite.dart';

import 'wire_values.dart';
import '../device/till_coordinator.dart';

/// A cash session as `POST /api/v2/sync/push` receives it.
///
/// A local `shifts` row IS the POS session. Sent with every snapshot column
/// (`employee_name`, `pos_name`, `outlet_name`, `closed_by_name`): the server
/// stores them rather than re-deriving from its own tables, so a session keeps
/// naming the person who actually counted the drawer after they are renamed
/// or leave.
///
/// The register and outlet are NOT sent. The `Session` schema forbids them, and
/// the server takes both from the device token — a till cannot file a drawer
/// under a register it is not bound to.
///
/// Epoch milliseconds go up as-is. The device's clock is not trusted for
/// ordering, but it IS the only record of when the drawer was opened.
class SessionPush {
  const SessionPush._();

  static const entity = 'pos_sessions';

  static Future<Map<String, Object?>?> payloadWithin(
    DatabaseExecutor txn,
    String shiftId,
  ) async {
    final rows = await txn.query(
      'shifts',
      where: 'id = ?',
      whereArgs: [shiftId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;

    return {
      if (TillCoordinator.current != null && row['closed_at'] != null)
        'order_count': Sqflite.firstIntValue(await txn.rawQuery(
          'SELECT COUNT(*) FROM orders WHERE pos_session_id = ?', [shiftId])) ?? 0,
      'id': row['id'],
      'employee_id': uuidOrNull(row['employee_id']),
      'employee_name': row['employee_name'],
      'pos_name': row['pos_name'],
      'outlet_name': row['outlet_name'],
      'opened_at_ms': wireInt(row['opened_at']),
      'opening_cash': wireInt(row['opening_cash']),
      'closed_at_ms': wireIntOrNull(row['closed_at']),
      'counted_cash': wireIntOrNull(row['counted_cash']),
      'expected_cash': wireIntOrNull(row['expected_cash']),
      'closed_by_id': uuidOrNull(row['closed_by_id']),
      'closed_by_name': row['closed_by_name'],
      'note': row['note'],
    };
  }
}
