import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';

/// Small values the sync keeps between runs, stored beside the data they
/// describe so they live and die with this merchant's store.
///
/// Device bookkeeping like `_sync_state` and `_outbox`: never pushed, never a
/// merchant's data.
class SyncMetaStore {
  const SyncMetaStore._();
  static const instance = SyncMetaStore._();

  static const table = '_sync_meta';
  static const _serverTimeDelta = 'server_time_delta_ms';
  static const _deviceRevision = 'device_revision';
  static const _manifestEntities = 'manifest_entities';

  /// How far the server's clock is ahead of this device (negative when behind),
  /// as last measured, or null before the first server response.
  ///
  /// Read on an executor the caller already has open, because a sale stamps it
  /// inside its own transaction.
  static Future<int?> serverTimeDeltaWithin(DatabaseExecutor txn) =>
      _readInt(txn, _serverTimeDelta);

  Future<int?> serverTimeDeltaMs() async =>
      serverTimeDeltaWithin(await AppDatabase.instance.db);

  /// Records the offset implied by a `server_time_ms` the server just sent.
  ///
  /// Network latency is ignored: the value exists so the server can flag a
  /// tablet whose clock is minutes or days out, not to synchronise clocks.
  Future<void> recordServerTime(
    int serverTimeMs, {
    DateTime? receivedAt,
  }) async {
    final local = (receivedAt ?? DateTime.now()).millisecondsSinceEpoch;
    await _write(_serverTimeDelta, serverTimeMs - local);
  }

  /// The `device_revision` whose binding this device last confirmed through
  /// `/devices/me`, or null when it never has.
  ///
  /// Persisted so a launch does not need `/devices/me` at all: the first
  /// `/sync/changes` after the startup spread says whether anything changed.
  Future<int?> deviceRevision() async =>
      _readInt(await AppDatabase.instance.db, _deviceRevision);

  Future<void> recordDeviceRevision(int revision) =>
      _write(_deviceRevision, revision);

  Future<void> recordManifestEntities(Set<String> entities) async {
    final sorted = entities.toList()..sort();
    final db = await AppDatabase.instance.db;
    await db.insert(table, {
      'key': _manifestEntities,
      'value': sorted.join(','),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<bool> supportsEntityWithin(
    DatabaseExecutor txn,
    String entity,
  ) async {
    final rows = await txn.query(
      table,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [_manifestEntities],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return (rows.first['value'] as String).split(',').contains(entity);
  }

  static Future<int?> _readInt(DatabaseExecutor txn, String key) async {
    final rows = await txn.query(
      table,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : int.tryParse(rows.first['value'] as String);
  }

  Future<void> _write(String key, int value) async {
    final db = await AppDatabase.instance.db;
    await db.insert(table, {
      'key': key,
      'value': '$value',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
