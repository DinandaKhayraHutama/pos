import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../device/till_binding.dart';
import '../models/enums.dart';
import '../models/table.dart';
import '../sync/outbox_store.dart';
import '../sync/table_status_push.dart';

/// The floor plan, always for ONE branch.
///
/// [outletId] is required rather than defaulted for the same reason it is on
/// the catalogue: there is no useful "all branches" floor plan, and a board
/// showing two shops' covers at once would have a waiter seating a guest at a
/// table in another city.
///
/// **On an activated till the floor plan is the server's (Fase 6).** Tables
/// arrive by pull, and a status change is an event queued for push in the
/// transaction that makes it. What the board shows is
///
///     the server's status snapshot, unless this till has a newer change of
///     its own the snapshot does not reflect yet
///
/// where "does not reflect" means not yet answered, or applied at a status
/// sequence newer than the snapshot held. A change the server superseded
/// (another till's later change won) stops showing the moment the answer
/// arrives. `tables.contested` is the server's word that two tills raced on
/// the table; the board shows it and never resolves it silently. The demo
/// writes `tables.status` directly, as it always has.
class TableRepository {
  TableRepository._();
  static final TableRepository instance = TableRepository._();

  static const _uuid = Uuid();

  /// The server's two answers to a status change.
  static const outcomeApplied = 'applied';
  static const outcomeSuperseded = 'superseded';

  /// Every table at one branch.
  ///
  /// [onlyActive] is what tells the two callers apart: the management screen
  /// (false, the default) has to see a deactivated table to bring it back,
  /// while the "start a new order" pickers (true) must never offer one.
  Future<List<RestaurantTable>> byOutlet(
    String outletId, {
    bool onlyActive = false,
  }) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'tables',
      where: onlyActive ? 'outlet_id = ? AND active = 1' : 'outlet_id = ?',
      whereArgs: [outletId],
      orderBy: 'floor ASC, sort_order ASC, name ASC',
    );
    return rows.map(RestaurantTable.fromMap).toList();
  }

  /// The floor board's list: every active table, PLUS any inactive table
  /// still mid-service.
  ///
  /// A table deactivated while a guest is seated must not vanish from the
  /// board — staff still need to see it is occupied and clear it. Once it is
  /// available again, an inactive table drops out on the next read.
  Future<List<RestaurantTable>> operational(String outletId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'tables',
      where: "outlet_id = ? AND (active = 1 OR status != 'available')",
      whereArgs: [outletId],
      orderBy: 'floor ASC, sort_order ASC, name ASC',
    );
    return rows.map(RestaurantTable.fromMap).toList();
  }

  /// True when [name] is already taken by another table AT THE SAME BRANCH.
  ///
  /// Scoped per outlet, same reasoning as `PosRegisterRepository`: every
  /// branch is allowed its own "Meja 01".
  Future<bool> isNameTaken(
    String name, {
    required String outletId,
    String? exceptId,
  }) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'tables',
      where: exceptId == null
          ? 'outlet_id = ? AND name = ? COLLATE NOCASE'
          : 'outlet_id = ? AND name = ? COLLATE NOCASE AND id != ?',
      whereArgs: exceptId == null
          ? [outletId, name]
          : [outletId, name, exceptId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The demo's table editor. On an activated till the floor plan is the
  /// Backoffice's, and the screen that calls this is closed.
  Future<void> upsert(RestaurantTable t) async {
    if (TillBinding.current != null) {
      throw StateError('The connected floor plan is managed in Backoffice.');
    }
    final db = await AppDatabase.instance.db;
    await db.insert(
      'tables',
      t.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Seats, clears or reserves a table.
  ///
  /// On an activated till the change is also an event, made against the
  /// status snapshot this till holds, and queued in the same transaction:
  /// write-then-queue would leave a change the other tills never hear about.
  /// [employeeName] is who made it, for the Backoffice board.
  Future<void> setStatus(
    String id,
    TableStatus status, {
    String employeeName = '',
  }) async {
    final db = await AppDatabase.instance.db;
    await db.transaction(
      (txn) => setStatusWithin(txn, id, status, employeeName: employeeName),
    );
  }

  static Future<void> setStatusWithin(
    DatabaseExecutor txn,
    String id,
    TableStatus status, {
    String employeeName = '',
  }) async {
    if (TillBinding.current == null) {
      await txn.update(
        'tables',
        {'status': status.wire},
        where: 'id = ?',
        whereArgs: [id],
      );
      return;
    }

    final rows = await txn.query(
      'tables',
      columns: ['outlet_id', 'server_seq'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    if (rows.first['outlet_id'] != TillBinding.current!.outletId) {
      throw const TillBindingException('table in another outlet');
    }

    final eventId = _uuid.v4();
    // Monotonic on this store even when the clock is corrected backwards
    // (previous + 1), and seeded from the wall clock so a store that starts
    // empty never reuses a number the server already recorded for this
    // device. That happens when the installation id outlives the database —
    // the iOS keychain survives a reinstall, and re-activation reuses the
    // device row — and a reused number would be refused as a duplicate.
    final previous =
        Sqflite.firstIntValue(
          await txn.rawQuery(
            'SELECT COALESCE(MAX(client_seq), 0) FROM table_status_events WHERE table_id = ?',
            [id],
          ),
        ) ??
        0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final clientSeq = previous + 1 > now ? previous + 1 : now;
    await txn.insert('table_status_events', {
      'id': eventId,
      'table_id': id,
      'outlet_id': rows.first['outlet_id'],
      'status': status.wire,
      'client_seq': clientSeq,
      'basis_seq': (rows.first['server_seq'] as num?)?.toInt() ?? 0,
      'employee_name': employeeName,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await txn.update(
      'tables',
      {'status': status.wire},
      where: 'id = ?',
      whereArgs: [id],
    );
    await OutboxStore.enqueueWithin(txn, TableStatusPush.entity, eventId);
  }

  /// Applies one pulled `table_status` row, inside the pull's transaction.
  ///
  /// An older snapshot arriving after a newer one changes nothing. A status
  /// for a table this till does not hold (deleted since) has nowhere to go.
  static Future<void> applyServerStatusWithin(
    DatabaseExecutor txn, {
    required String tableId,
    required String status,
    required int seq,
    required bool contested,
  }) async {
    final rows = await txn.query(
      'tables',
      columns: ['server_seq'],
      where: 'id = ?',
      whereArgs: [tableId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final held = (rows.first['server_seq'] as num?)?.toInt();
    if (held != null && held >= seq) return;

    await txn.update(
      'tables',
      {
        'server_status': status,
        'server_seq': seq,
        'contested': contested ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [tableId],
    );
    await recomputeWithin(txn, tableId);
  }

  /// Re-derives what the board shows for one table. No-op until a snapshot
  /// has arrived: until then the local status is all there is.
  static Future<void> recomputeWithin(
    DatabaseExecutor txn,
    String tableId,
  ) async {
    final rows = await txn.query(
      'tables',
      columns: ['server_status', 'server_seq'],
      where: 'id = ?',
      whereArgs: [tableId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final snapshotSeq = (rows.first['server_seq'] as num?)?.toInt();
    if (snapshotSeq == null) return;

    // A status is a value, not a delta: the newest change still pending wins.
    final pending = await txn.query(
      'table_status_events',
      columns: ['status'],
      where:
          'table_id = ? AND (outcome IS NULL OR outcome = ?) '
          'AND (server_seq IS NULL OR server_seq > ?)',
      whereArgs: [tableId, outcomeApplied, snapshotSeq],
      orderBy: 'client_seq DESC',
      limit: 1,
    );
    final shown = pending.isNotEmpty
        ? pending.first['status'] as String
        : (rows.first['server_status'] as String?) ??
              TableStatus.available.wire;

    await txn.update(
      'tables',
      {'status': shown},
      where: 'id = ?',
      whereArgs: [tableId],
    );
  }

  /// Records the server's answer to one of this till's changes: the status
  /// sequence it was recorded at, and whether the table took it.
  ///
  /// Called BEFORE the outbox entry is removed, for the same reason as a
  /// stock movement: the reverse order would leave a change the till keeps
  /// showing over a snapshot that already settled it.
  Future<void> markApplied(
    String eventId,
    int statusSeq,
    String outcome,
  ) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'table_status_events',
        columns: ['table_id'],
        where: 'id = ?',
        whereArgs: [eventId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      await txn.update(
        'table_status_events',
        {'server_seq': statusSeq, 'outcome': outcome},
        where: 'id = ?',
        whereArgs: [eventId],
      );
      await recomputeWithin(txn, rows.first['table_id'] as String);
    });
  }

  /// Refused events stay auditable but must not mask the authoritative status
  /// forever. Recovery restores the overlay in the same outbox transaction.
  static Future<void> setRejectedWithin(
    DatabaseExecutor txn,
    String eventId, {
    required bool rejected,
  }) async {
    final rows = await txn.query(
      'table_status_events',
      columns: ['table_id'],
      where: 'id = ?',
      whereArgs: [eventId],
    );
    if (rows.isEmpty) return;
    await txn.update(
      'table_status_events',
      {'outcome': rejected ? 'rejected' : null},
      where: 'id = ?',
      whereArgs: [eventId],
    );
    await recomputeWithin(txn, rows.single['table_id'] as String);
  }

  /// How many orders were rung up against this table.
  ///
  /// Asked before offering to delete one, same reason as
  /// `PosRegisterRepository.orderCount`: `orders.table_name` is a snapshot
  /// (no FK), so deleting the row would not corrupt a past receipt — but it
  /// would leave nothing for staff to reopen if the table comes back into
  /// use, and "gone" is what deactivating already means. Delete stays for a
  /// table nobody ever sat a guest at.
  Future<int> orderCount(String id) async {
    final db = await AppDatabase.instance.db;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM orders WHERE table_id = ?', [
            id,
          ]),
        ) ??
        0;
  }

  Future<void> delete(String id) async {
    if (TillBinding.current != null) {
      throw StateError('The connected floor plan is managed in Backoffice.');
    }
    final db = await AppDatabase.instance.db;
    await db.delete('tables', where: 'id = ?', whereArgs: [id]);
  }
}
