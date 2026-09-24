import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import 'order_push.dart';
import 'session_push.dart';
import 'stock_movement_push.dart';
import 'table_status_push.dart';
import 'customer_push.dart';
import 'bill_push.dart';
import 'kitchen_dispatch_push.dart';

/// One snapshot this device still owes the server.
class OutboxEntry {
  const OutboxEntry({
    required this.entity,
    required this.entityId,
    required this.attempts,
    this.revision,
    this.payload,
    this.lastError,
    this.queuedAt,
    this.lastQueuedAt,
  });

  final String entity;
  final String entityId;

  /// Diagnostics, never a reason to give up on a row.
  final int attempts;

  /// The revision [payload] was taken at. Null only for an entry a v24 build
  /// queued, which stored an identity alone; [OutboxStore.ensureSnapshot]
  /// gives it one before its first v2 send.
  final int? revision;

  /// The exact JSON row sent for [revision]. Retries resend these bytes.
  final String? payload;
  final String? lastError;
  final int? queuedAt;

  /// When the entry last changed. Null on an entry queued before v33, which
  /// reads as [queuedAt].
  final int? lastQueuedAt;

  /// The moment this entry's facts were last written, for ordering stock.
  int get writtenAt => lastQueuedAt ?? queuedAt ?? 0;

  bool get isSnapshotted => revision != null && payload != null;
}

/// The queue of rows waiting to go up.
///
/// **An entry is a snapshot at a revision, not a pointer to a row.** The v2
/// contract acknowledges a specific revision, so what was sent has to be
/// remembered exactly: an order voided while its sale was still in flight is a
/// NEWER revision, and the server's "accepted" for the older one must not
/// remove it. [enqueueWithin] snapshots the row inside the transaction that
/// wrote it; [acknowledge] removes an entry only while it still holds the
/// revision that was accepted.
///
/// The composite primary key `(entity, entity_id)` keeps one pending snapshot
/// per row: queueing the same row again replaces its snapshot with a newer
/// revision rather than adding a second job. Revisions live in
/// `_push_revisions`, which is never pruned, so they keep increasing after an
/// entry is acknowledged and removed.
///
/// Nothing here is business data. It is the mirror image of `_sync_state`:
/// that one remembers what came down, this one remembers what has not gone up.
class OutboxStore {
  const OutboxStore._();
  static const instance = OutboxStore._();

  static const table = '_outbox';
  static const revisionsTable = '_push_revisions';

  /// The entities a device pushes, in the order a request carries them: a
  /// session before the sales that name it; stock movements and table status
  /// changes, which depend on neither, last.
  static const pushOrder = [
    SessionPush.entity,
    CustomerPush.entity,
    // Fase 4: a bill before the dispatches that send its lines, both before
    // the receipt that settles it — the server needs each in place when the
    // next arrives, and a request carries its batches in this order.
    BillPush.entity,
    KitchenDispatchPush.entity,
    OrderPush.entity,
    StockMovementPush.entity,
    TableStatusPush.entity,
  ];

  /// Entities whose entries go up strictly oldest first. See [pending].
  static const _inOrderOfWriting = {
    StockMovementPush.entity,
    KitchenDispatchPush.entity,
    TableStatusPush.entity,
  };

  /// The row as the server receives it, minus `revision`, or null when there
  /// is no such row (or no such pushable entity).
  static Future<Map<String, Object?>?> payloadWithin(
    DatabaseExecutor txn,
    String entity,
    String entityId,
  ) {
    switch (entity) {
      case SessionPush.entity:
        return SessionPush.payloadWithin(txn, entityId);
      case CustomerPush.entity:
        return CustomerPush.payloadWithin(txn, entityId);
      case BillPush.entity:
        return BillPush.payloadWithin(txn, entityId);
      case KitchenDispatchPush.entity:
        return KitchenDispatchPush.payloadWithin(txn, entityId);
      case OrderPush.entity:
        return OrderPush.payloadWithin(txn, entityId);
      case StockMovementPush.entity:
        return StockMovementPush.payloadWithin(txn, entityId);
      case TableStatusPush.entity:
        return TableStatusPush.payloadWithin(txn, entityId);
    }
    return Future.value(null);
  }

  /// Snapshot [entityId] at its next revision, on an executor the caller
  /// already has open.
  ///
  /// The enqueue MUST commit with the row it describes. Queue-then-write loses
  /// the row on a crash; write-then-queue loses the sale silently, which is
  /// worse — the money is on the device and nothing will ever send it.
  ///
  /// Given a bare [Database] rather than a transaction, it opens one: the
  /// revision is read-then-written and must not interleave with another write.
  static Future<void> enqueueWithin(
    DatabaseExecutor txn,
    String entity,
    String entityId,
  ) async {
    if (txn is Database) {
      return txn.transaction((t) => enqueueWithin(t, entity, entityId));
    }

    final payload = await payloadWithin(txn, entity, entityId);
    // Nothing to snapshot. Every caller has just written the row, so this is
    // not a path a sale can take — and throwing here would roll the sale back.
    if (payload == null) return;

    final revision = await _nextRevision(txn, entity, entityId);
    final body = jsonEncode(<String, Object?>{
      'id': payload['id'],
      if (entity != CustomerPush.entity) 'revision': revision,
      ...payload,
    });

    final existing = await txn.query(
      table,
      columns: ['entity_id'],
      where: 'entity = ? AND entity_id = ?',
      whereArgs: [entity, entityId],
      limit: 1,
    );
    if (existing.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.insert(table, {
        'entity': entity,
        'entity_id': entityId,
        'queued_at': now,
        'last_queued_at': now,
        'attempts': 0,
        'revision': revision,
        'payload': body,
      });
    } else {
      // An update, keeping `queued_at` and `attempts`: the row has been owed
      // since it was first queued, and its history is still its history.
      await txn.update(
        table,
        {
          'revision': revision,
          'payload': body,
          // The barrier in OutboxPush orders stock-moving rows by when they
          // last changed: a bill cancelled after a count must follow it.
          'last_queued_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'entity = ? AND entity_id = ?',
        whereArgs: [entity, entityId],
      );
    }
  }

  static Future<int> _nextRevision(
    DatabaseExecutor txn,
    String entity,
    String entityId,
  ) async {
    final rows = await txn.query(
      revisionsTable,
      columns: ['revision'],
      where: 'entity = ? AND entity_id = ?',
      whereArgs: [entity, entityId],
      limit: 1,
    );
    if (rows.isEmpty) {
      await txn.insert(revisionsTable, {
        'entity': entity,
        'entity_id': entityId,
        'revision': 1,
      });
      return 1;
    }
    final next = (rows.first['revision'] as num).toInt() + 1;
    await txn.update(
      revisionsTable,
      {'revision': next},
      where: 'entity = ? AND entity_id = ?',
      whereArgs: [entity, entityId],
    );
    return next;
  }

  /// Everything still owed, least-tried first.
  ///
  /// Ordered by `attempts` before age so rows the server keeps answering
  /// `retry` for cannot fill every 200-row request and starve newer sales
  /// behind them. Sessions still go up before orders — a request carries the
  /// session batch first — so a sale never waits on this order for its drawer.
  ///
  /// Stock movements and table status changes are the exception: strictly
  /// oldest first. The server turns a count into a delta against its quantity
  /// when the count arrives, so a sale this till made before counting has to
  /// reach it first; and it lets a till's own later status change follow its
  /// earlier one, so the earlier one arriving second would put the table back
  /// to a status staff had already moved on from.
  Future<List<OutboxEntry>> pending({String? entity, int limit = 200}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      table,
      where: entity == null ? null : 'entity = ?',
      whereArgs: entity == null ? null : [entity],
      orderBy: _inOrderOfWriting.contains(entity)
          ? 'queued_at ASC, rowid ASC'
          : 'attempts ASC, queued_at ASC, rowid ASC',
      limit: limit,
    );
    return rows.map(_entryFrom).toList();
  }

  /// Gives an identity-only entry (queued by a v24 build) its first snapshot.
  ///
  /// Returns the entry ready to send, or null when the row it named no longer
  /// exists — in which case the entry is removed, because there is nothing to
  /// send and nothing a retry could fix.
  Future<OutboxEntry?> ensureSnapshot(OutboxEntry entry) async {
    if (entry.isSnapshotted) return entry;
    final db = await AppDatabase.instance.db;
    return db.transaction((txn) async {
      final payload = await payloadWithin(txn, entry.entity, entry.entityId);
      if (payload == null) {
        if (pushOrder.contains(entry.entity)) {
          await txn.delete(
            table,
            where: 'entity = ? AND entity_id = ?',
            whereArgs: [entry.entity, entry.entityId],
          );
        }
        return null;
      }
      await enqueueWithin(txn, entry.entity, entry.entityId);
      final rows = await txn.query(
        table,
        where: 'entity = ? AND entity_id = ?',
        whereArgs: [entry.entity, entry.entityId],
        limit: 1,
      );
      return rows.isEmpty ? null : _entryFrom(rows.first);
    });
  }

  /// Removes the entry only while it still holds [revision].
  ///
  /// Returns false when the row was edited while the push was in flight: the
  /// server accepted the older revision, and the newer snapshot stays queued.
  Future<bool> acknowledge(String entity, String entityId, int revision) async {
    final db = await AppDatabase.instance.db;
    final removed = await db.delete(
      table,
      where: 'entity = ? AND entity_id = ? AND revision = ?',
      whereArgs: [entity, entityId, revision],
    );
    return removed == 1;
  }

  /// Record that a push did not settle this entry, keeping it queued.
  ///
  /// `attempts` is kept for diagnostics rather than for giving up: a till with
  /// no wifi for a week must still be holding its sales when it reconnects.
  /// Nothing in this class ever drops an entry because it tried too often.
  Future<void> recordFailure(
    String entity,
    String entityId,
    String error,
  ) async {
    final db = await AppDatabase.instance.db;
    await db.rawUpdate(
      'UPDATE $table SET attempts = attempts + 1, last_error = ? '
      'WHERE entity = ? AND entity_id = ?',
      [error, entity, entityId],
    );
  }

  /// [recordFailure] for a whole request's worth of entries, in one commit.
  Future<void> recordFailures(
    Iterable<OutboxEntry> entries,
    String error,
  ) async {
    final db = await AppDatabase.instance.db;
    final batch = db.batch();
    for (final entry in entries) {
      batch.rawUpdate(
        'UPDATE $table SET attempts = attempts + 1, last_error = ? '
        'WHERE entity = ? AND entity_id = ?',
        [error, entry.entity, entry.entityId],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<int> count() async {
    final db = await AppDatabase.instance.db;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $table'),
        ) ??
        0;
  }

  static OutboxEntry _entryFrom(Map<String, Object?> r) => OutboxEntry(
    entity: r['entity'] as String,
    entityId: r['entity_id'] as String,
    attempts: (r['attempts'] as num?)?.toInt() ?? 0,
    revision: (r['revision'] as num?)?.toInt(),
    payload: r['payload'] as String?,
    lastError: r['last_error'] as String?,
    queuedAt: (r['queued_at'] as num?)?.toInt(),
    lastQueuedAt: (r['last_queued_at'] as num?)?.toInt(),
  );
}
