import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';

/// Where each entity's cursor has got to on this device.
///
/// The cursor is advanced ONLY after the rows it covers are committed, in the
/// same transaction as those rows. Storing it separately — "apply the page,
/// then remember it" — leaves a window where a crash between the two makes the
/// device believe it has data it never wrote, and the missing products only
/// surface when a cashier cannot find them.
class SyncStateStore {
  const SyncStateStore._();
  static const instance = SyncStateStore._();

  static const table = '_sync_state';

  Future<int> lastSeq(String entity) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      table,
      columns: ['last_seq'],
      where: 'entity = ?',
      whereArgs: [entity],
      limit: 1,
    );
    return rows.isEmpty ? 0 : rows.first['last_seq'] as int;
  }

  /// Records [seq] for [entity] on an executor the caller already has open.
  ///
  /// Takes a [DatabaseExecutor] rather than opening its own connection so it
  /// can join the transaction that wrote the rows — that is the whole point.
  static Future<void> recordWithin(
    DatabaseExecutor txn,
    String entity,
    int seq,
  ) => txn.insert(table, {
    'entity': entity,
    'last_seq': seq,
    'synced_at': DateTime.now().millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  /// Every entity's cursor, for the diagnostics screen.
  Future<Map<String, int>> all() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(table);
    return {
      for (final row in rows) row['entity'] as String: row['last_seq'] as int,
    };
  }

  /// Forget every cursor, so the next sync re-pulls from zero.
  ///
  /// For recovery, not routine use: it re-downloads the catalogue but never
  /// deletes anything, so a device that has drifted can be made consistent
  /// without losing unsynced local work.
  Future<void> reset() async {
    final db = await AppDatabase.instance.db;
    await db.delete(table);
  }
}
