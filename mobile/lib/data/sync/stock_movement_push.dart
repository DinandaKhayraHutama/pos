import 'package:sqflite/sqflite.dart';

import 'wire_values.dart';

/// A stock movement as `POST /api/v2/sync/push` receives it (the
/// `StockMovement` schema, Fase 5).
///
/// Immutable: a movement is queued once, when it is written. The outlet is
/// never sent — the server applies it at the token's outlet — and a count
/// carries the counted quantity and the snapshot sequence it was taken
/// against; the server computes its delta.
///
/// Every value is read from the stored row, so a re-snapshot (a dead letter
/// sent again) repeats the same facts and the server recognises the retry.
class StockMovementPush {
  const StockMovementPush._();

  static const entity = 'stock_movements';

  static Future<Map<String, Object?>?> payloadWithin(
    DatabaseExecutor txn,
    String movementId,
  ) async {
    final rows = await txn.query(
      'stock_movements',
      where: 'id = ?',
      whereArgs: [movementId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final m = rows.first;
    // Pulled history is never pushed back.
    if (m['origin'] == 'server') return null;

    final isCount = m['reason'] == 'count';
    return {
      'id': m['id'],
      'product_id': m['product_id'],
      'product_name': _clip(m['product_name'] as String? ?? '', 120),
      'reason': m['reason'],
      'delta_qty': wireInt(m['delta']),
      'counted_qty': isCount ? wireIntOrNull(m['counted_qty']) : null,
      'basis_seq': isCount ? wireIntOrNull(m['basis_seq']) : null,
      'occurred_at_ms': wireInt(m['created_at']),
      'employee_id': uuidOrNull(m['employee_id']),
      'employee_name': _clip(m['employee_name'] as String? ?? '', 120),
      'note': m['note'] == null ? null : _clip(m['note'] as String, 200),
    };
  }

  /// The schema bounds these by characters; a longer local note is cut rather
  /// than getting the whole movement refused.
  static String _clip(String value, int max) {
    final runes = value.runes;
    return runes.length <= max ? value : String.fromCharCodes(runes.take(max));
  }
}
