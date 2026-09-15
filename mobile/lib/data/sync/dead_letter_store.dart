import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../repositories/table_repository.dart';
import 'outbox_store.dart';

/// A row the server refused, kept so it can be recovered.
class DeadLetter {
  const DeadLetter({
    required this.id,
    required this.entity,
    required this.entityId,
    required this.revision,
    required this.payload,
    required this.code,
    required this.rejectedAt,
    this.message,
    this.details = const {},
  });

  final int id;
  final String entity;
  final String entityId;
  final int revision;

  /// The exact JSON row that was refused.
  final String payload;
  final String code;
  final String? message;

  /// Anything else the result said, such as who holds a busy register.
  final Map<String, Object?> details;
  final DateTime rejectedAt;
}

/// Where a `rejected` push result goes instead of into nothing.
///
/// The v1 client deleted a sale the server refused. A refusal is a statement
/// about one payload at one moment — a register someone else was holding, a
/// field too long — and every one of those rows is still money a customer
/// paid. So the sent snapshot moves here, atomically with its removal from the
/// outbox, and stays until someone deals with it.
class DeadLetterStore {
  const DeadLetterStore._();
  static const instance = DeadLetterStore._();

  static const table = '_dead_letter';

  /// The closed set of rejection codes in the v2 contract.
  ///
  /// A `rejected` result carrying anything else is not trusted to mean what a
  /// rejection means: the row stays queued, and only these move it here.
  static const rejectionCodes = {
    'duplicate',
    'settled',
    'session_closed',
    'unknown_entity',
    'schema_rejected',
    'stale_revision',
    'register_busy',
    'archived',
  };

  /// Moves the sent snapshot out of the outbox and into this table, in one
  /// transaction.
  ///
  /// The outbox entry is removed only while it still holds the refused
  /// revision. An edit made while the push was in flight is a newer snapshot,
  /// and the server has not answered for that one yet.
  Future<void> moveFromOutbox(
    OutboxEntry sent, {
    required String code,
    String? message,
    Map<String, Object?> details = const {},
  }) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      await txn.insert(table, {
        'entity': sent.entity,
        'entity_id': sent.entityId,
        'revision': sent.revision,
        'payload': sent.payload,
        'code': code,
        'message': message,
        'details': details.isEmpty ? null : jsonEncode(details),
        'rejected_at': DateTime.now().millisecondsSinceEpoch,
      });
      await txn.delete(
        OutboxStore.table,
        where: 'entity = ? AND entity_id = ? AND revision = ?',
        whereArgs: [sent.entity, sent.entityId, sent.revision],
      );
      if (sent.entity == 'table_status_events') {
        await TableRepository.setRejectedWithin(
          txn,
          sent.entityId,
          rejected: true,
        );
      }
    });
  }

  Future<List<DeadLetter>> all() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(table, orderBy: 'rejected_at DESC, id DESC');
    return rows.map(_fromRow).toList();
  }

  Future<int> count() async {
    final db = await AppDatabase.instance.db;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $table'),
        ) ??
        0;
  }

  /// Sends every refused row whose local record still exists up again, as a
  /// fresh snapshot at a new revision.
  ///
  /// A refusal can stop being true — a register freed when its holder closed
  /// their drawer — so recovery is a retry, not an export. Letters whose row
  /// is gone stay here: the stored payload is then the only copy left.
  ///
  /// Returns how many rows went back into the outbox.
  Future<int> requeueAll() async {
    final db = await AppDatabase.instance.db;
    return db.transaction((txn) async {
      final pairs = await txn.rawQuery(
        'SELECT DISTINCT entity, entity_id FROM $table',
      );
      var requeued = 0;
      for (final pair in pairs) {
        final entity = pair['entity'] as String;
        final entityId = pair['entity_id'] as String;
        final payload = await OutboxStore.payloadWithin(txn, entity, entityId);
        if (payload == null) continue;
        await OutboxStore.enqueueWithin(txn, entity, entityId);
        if (entity == 'table_status_events') {
          await TableRepository.setRejectedWithin(
            txn,
            entityId,
            rejected: false,
          );
        }
        await txn.delete(
          table,
          where: 'entity = ? AND entity_id = ?',
          whereArgs: [entity, entityId],
        );
        requeued++;
      }
      return requeued;
    });
  }

  static DeadLetter _fromRow(Map<String, Object?> r) {
    Map<String, Object?> details = const {};
    final raw = r['details'] as String?;
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) details = decoded;
      } catch (_) {
        // Diagnostics only; an unreadable blob must not hide the letter.
      }
    }
    return DeadLetter(
      id: (r['id'] as num).toInt(),
      entity: r['entity'] as String,
      entityId: r['entity_id'] as String,
      revision: (r['revision'] as num).toInt(),
      payload: r['payload'] as String,
      code: r['code'] as String,
      message: r['message'] as String?,
      details: details,
      rejectedAt: DateTime.fromMillisecondsSinceEpoch(
        (r['rejected_at'] as num).toInt(),
      ),
    );
  }
}
