import 'package:sqflite/sqflite.dart';

import 'wire_values.dart';

/// A table status change as `POST /api/v2/sync/push` receives it (the
/// `TableStatusEvent` schema, Fase 6).
///
/// Immutable, like a stock movement: one event per change, queued in the
/// transaction that makes it. The outlet is never sent. `basis_seq` is the
/// status snapshot this till held for the table when the change was made, which
/// is how the server tells a change made against what the till could see from
/// one that raced another till.
///
/// Every value is read from the stored row, so a re-snapshot (a dead letter
/// sent again) repeats the same facts and the server recognises the retry.
class TableStatusPush {
  const TableStatusPush._();

  static const entity = 'table_status_events';

  static Future<Map<String, Object?>?> payloadWithin(
    DatabaseExecutor txn,
    String eventId,
  ) async {
    final rows = await txn.query(
      'table_status_events',
      where: 'id = ?',
      whereArgs: [eventId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final e = rows.first;
    // A table made up on this device has no row on the server to change.
    if (!isUuid(e['table_id'])) return null;

    return {
      'id': e['id'],
      'table_id': e['table_id'],
      'status': e['status'],
      'client_seq': wireInt(e['client_seq']),
      'basis_seq': wireInt(e['basis_seq']),
      'occurred_at_ms': wireInt(e['created_at']),
      'employee_name': _clip(e['employee_name'] as String? ?? '', 120),
    };
  }

  static String _clip(String value, int max) {
    final runes = value.runes;
    return runes.length <= max ? value : String.fromCharCodes(runes.take(max));
  }
}
