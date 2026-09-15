import 'dart:convert';

import '../database/app_database.dart';
import '../device/till_binding.dart';
import '../repositories/stock_repository.dart';
import '../repositories/table_repository.dart';
import 'dead_letter_store.dart';
import 'outbox_store.dart';
import 'sync_client.dart';
import 'sync_meta_store.dart';

/// What one push run did.
class PushReport {
  const PushReport({
    this.accepted = 0,
    this.rejected = 0,
    this.remaining = 0,
    this.requests = 0,
    this.failure,
    this.tableStatusSeq = 0,
  });

  /// Rows the server named accepted for the revision that was sent.
  final int accepted;

  /// Rows moved to the dead-letter table.
  final int rejected;

  /// Entries still in the outbox when the run ended, for whatever reason.
  final int remaining;
  final int requests;

  /// The request-level failure that ended the run, if one did.
  final SyncException? failure;
  final int tableStatusSeq;

  bool get changedAnything => accepted > 0 || rejected > 0;

  /// Whether something is still owed and worth trying again soon.
  bool get needsRetry => remaining > 0 || failure != null;
}

/// Sends the outbox up through `POST /api/v2/sync/push`.
///
/// The rules that make losing a sale structurally impossible here:
///
/// 1. **Only `accepted` removes a row**, and only for the revision that was
///    sent (`OutboxStore.acknowledge`).
/// 2. **`rejected` moves a row to the dead-letter table**, and only with a code
///    from the contract's closed set.
/// 3. **Everything else keeps the row**: `retry`, a result that is missing,
///    duplicated, names another id or revision, or has a status nobody knows;
///    a body that is not an object; any non-2xx; no response at all.
///
/// Rows go up batched — at most [maxRows] per request, sessions before orders
/// — and the run keeps sending while requests make progress. A request where
/// nothing was settled ends the run: sending the same rows again at once would
/// earn the same answer, so the scheduler backs off instead.
class OutboxPush {
  OutboxPush(
    this._client, {
    this.maxRows = 200,
    this.maxBytes = 3 * 1024 * 1024,
    this.maxRequests = 50,
    TillBinding? binding,
  }) : assert(maxRows > 0 && maxRows <= 200),
       _binding = binding ?? TillBinding.current;

  final SyncClient _client;

  /// The till this device is bound to. A row that names another is never sent:
  /// the server would file it under this till anyway.
  final TillBinding? _binding;

  /// The local code for a row that names a different till or outlet. Not in
  /// the server's closed set — the server never saw it.
  static const registerMismatch = 'register_mismatch';

  /// The server refuses more than 200 rows per request.
  final int maxRows;

  /// Kept under the server's 4 MiB body limit with room for the envelope.
  final int maxBytes;

  /// A bound on one run, so a week-offline till drains in paced runs.
  final int maxRequests;

  Future<PushReport> run() async {
    var accepted = 0;
    var rejected = 0;
    var requests = 0;
    var tableStatusSeq = 0;
    SyncException? failure;

    while (requests < maxRequests) {
      final batches = await _nextBatches();
      if (batches.isEmpty) break;
      requests++;

      final sent = [for (final batch in batches) ...batch.entries];
      late Map<String, dynamic> response;
      try {
        response = await _client.post('/sync/push', _encode(batches));
      } on SyncException catch (e) {
        await OutboxStore.instance.recordFailures(sent, e.failure.name);
        // Not this batch's fault and not fixable by retrying it: stop, and let
        // the caller re-activate or ask for an update. Every row stays queued.
        if (e.failure == SyncFailure.unauthorized ||
            e.failure == SyncFailure.schemaOutdated) {
          rethrow;
        }
        failure = e;
        break;
      }

      final serverTime = response['server_time_ms'];
      if (serverTime is int) {
        await SyncMetaStore.instance.recordServerTime(serverTime);
      }

      final settled = await _applyResults(batches, response);
      accepted += settled.accepted;
      rejected += settled.rejected;
      if (settled.tableStatusSeq > tableStatusSeq) {
        tableStatusSeq = settled.tableStatusSeq;
      }
      if (settled.accepted + settled.rejected == 0) break;
    }

    return PushReport(
      accepted: accepted,
      rejected: rejected,
      remaining: await OutboxStore.instance.count(),
      requests: requests,
      failure: failure,
      tableStatusSeq: tableStatusSeq,
    );
  }

  Future<List<_Batch>> _nextBatches() async {
    final batches = <_Batch>[];
    var rows = 0;
    var bytes = 0;

    for (final entity in OutboxStore.pushOrder) {
      if (rows >= maxRows) break;
      final candidates = await OutboxStore.instance.pending(
        entity: entity,
        limit: maxRows - rows,
      );
      final entries = <OutboxEntry>[];
      var full = false;
      for (final candidate in candidates) {
        final entry = await OutboxStore.instance.ensureSnapshot(candidate);
        if (entry == null) continue;
        if (!await _boundToThisTill(entry)) {
          // Written before the binding was enforced, or by a path that went
          // around it. Sending it would misattribute a drawer or a sale, so it
          // is kept — recoverable, never deleted — and never sent as it is.
          await DeadLetterStore.instance.moveFromOutbox(
            entry,
            code: registerMismatch,
            message:
                'Row names a register or outlet this device is not bound to.',
          );
          continue;
        }
        final size = utf8.encode(entry.payload!).length;
        // One oversized row still goes alone, so it earns its own answer
        // instead of blocking every row behind it forever.
        if (rows > 0 && bytes + size > maxBytes) {
          full = true;
          break;
        }
        entries.add(entry);
        rows++;
        bytes += size;
      }
      if (entries.isNotEmpty) batches.add(_Batch(entity, entries));
      if (full) break;
    }
    return batches;
  }

  /// Whether the row behind [entry] belongs to the bound till.
  ///
  /// A session must be on the bound register. A sale must be in a session on
  /// the bound register — that is what the server checks — and any register or
  /// outlet it names itself must match too. With no binding (demo mode, which
  /// never pushes) everything passes; a row that has gone passes too, because
  /// `ensureSnapshot` already dealt with it.
  Future<bool> _boundToThisTill(OutboxEntry entry) async {
    final binding = _binding;
    if (binding == null) return true;
    final db = await AppDatabase.instance.db;
    bool matches(Object? value, String bound) =>
        value == null || value == bound;

    switch (entry.entity) {
      case 'pos_sessions':
        final rows = await db.query(
          'shifts',
          columns: ['pos_id', 'outlet_id'],
          where: 'id = ?',
          whereArgs: [entry.entityId],
          limit: 1,
        );
        if (rows.isEmpty) return true;
        return rows.first['pos_id'] == binding.registerId &&
            matches(rows.first['outlet_id'], binding.outletId);
      case 'orders':
        final rows = await db.rawQuery(
          'SELECT o.pos_id, o.outlet_id, s.pos_id AS session_pos '
          'FROM orders o LEFT JOIN shifts s ON s.id = o.pos_session_id '
          'WHERE o.id = ? LIMIT 1',
          [entry.entityId],
        );
        if (rows.isEmpty) return true;
        final row = rows.first;
        return row['session_pos'] == binding.registerId &&
            matches(row['pos_id'], binding.registerId) &&
            matches(row['outlet_id'], binding.outletId);
      case 'stock_movements':
      case 'table_status_events':
        // The server applies a movement at the token's outlet. One written
        // for another branch's shelf would move the wrong shelf.
        final rows = await db.query(
          entry.entity,
          columns: ['outlet_id'],
          where: 'id = ?',
          whereArgs: [entry.entityId],
          limit: 1,
        );
        if (rows.isEmpty) return true;
        return rows.first['outlet_id'] == binding.outletId;
    }
    return true;
  }

  /// The request body, built from the stored snapshots verbatim so a retry
  /// sends exactly the bytes the first attempt did.
  String _encode(List<_Batch> batches) {
    final out = StringBuffer('{"batches":[');
    for (var b = 0; b < batches.length; b++) {
      if (b > 0) out.write(',');
      out
        ..write('{"entity":')
        ..write(jsonEncode(batches[b].entity))
        ..write(',"rows":[')
        ..writeAll(batches[b].entries.map((e) => e.payload), ',')
        ..write(']}');
    }
    out.write(']}');
    return out.toString();
  }

  Future<({int accepted, int rejected, int tableStatusSeq})> _applyResults(
    List<_Batch> batches,
    Map<String, dynamic> response,
  ) async {
    final all = [for (final batch in batches) ...batch.entries];
    final results = response['results'];
    if (results is! List) {
      await OutboxStore.instance.recordFailures(all, 'response has no results');
      return (accepted: 0, rejected: 0, tableStatusSeq: 0);
    }

    // Correlate by position, exactly as the contract says. A position answered
    // twice is ambiguous, and an ambiguous answer never removes anything.
    final byPosition = <(int, int), Map<String, dynamic>>{};
    final ambiguous = <(int, int)>{};
    for (final result in results) {
      if (result is! Map<String, dynamic>) continue;
      final bi = result['batch_index'];
      final ri = result['row_index'];
      if (bi is! int || ri is! int) continue;
      final position = (bi, ri);
      if (byPosition.containsKey(position)) {
        ambiguous.add(position);
      } else {
        byPosition[position] = result;
      }
    }

    var accepted = 0;
    var rejected = 0;
    final kept = <OutboxEntry>[];
    var tableStatusSeq = 0;
    final keptReasons = <String>[];

    for (var b = 0; b < batches.length; b++) {
      final batch = batches[b];
      for (var r = 0; r < batch.entries.length; r++) {
        final entry = batch.entries[r];
        final result = ambiguous.contains((b, r)) ? null : byPosition[(b, r)];
        final verdict = _judge(entry, batch.entity, result);

        switch (verdict.status) {
          case _Status.accepted:
            if (batch.entity == 'table_status_events') {
              final seq = verdict.details['status_seq'] as int;
              if (seq > tableStatusSeq) tableStatusSeq = seq;
              await TableRepository.instance.markApplied(
                entry.entityId,
                verdict.details['status_seq'] as int,
                verdict.details['outcome'] as String,
              );
            }
            final stockSeq = verdict.details['stock_seq'];
            if (stockSeq is int) {
              // Recorded BEFORE the entry is removed. A crash between the two
              // leaves the entry queued, and its exact retry returns the same
              // sequence; the reverse order would leave a movement the till
              // counts on top of a snapshot that already contains it.
              await StockRepository.instance.markApplied(
                entry.entityId,
                stockSeq,
              );
            }
            await OutboxStore.instance.acknowledge(
              entry.entity,
              entry.entityId,
              entry.revision!,
            );
            accepted++;
          case _Status.rejected:
            await DeadLetterStore.instance.moveFromOutbox(
              entry,
              code: verdict.code!,
              message: verdict.message,
              details: verdict.details,
            );
            rejected++;
          case _Status.keep:
            kept.add(entry);
            keptReasons.add(verdict.code ?? 'unrecognised result');
        }
      }
    }

    for (var i = 0; i < kept.length; i++) {
      await OutboxStore.instance.recordFailure(
        kept[i].entity,
        kept[i].entityId,
        keptReasons[i],
      );
    }
    return (
      accepted: accepted,
      rejected: rejected,
      tableStatusSeq: tableStatusSeq,
    );
  }

  /// What a result means for the entry sent at its position.
  static _Verdict _judge(
    OutboxEntry entry,
    String entity,
    Map<String, dynamic>? result,
  ) {
    if (result == null || result['entity'] != entity) {
      return const _Verdict(_Status.keep);
    }

    final id = result['id'];
    final revision = result['revision'];
    final idMatches =
        id is String && id.toLowerCase() == entry.entityId.toLowerCase();
    final revisionMatches = revision is int && revision == entry.revision;
    // An echoed id or revision that differs from what was sent means this
    // result is not about this row, whatever its position says.
    if ((id != null && !idMatches) || (revision != null && !revisionMatches)) {
      return const _Verdict(_Status.keep, 'miscorrelated result');
    }

    final code = result['code'] is String ? result['code'] as String : null;
    final message = result['message'] is String
        ? result['message'] as String
        : null;

    switch (result['status']) {
      case 'accepted':
        // Removing a sale needs the server to name it: both id and revision.
        // Every row this device builds has a UUID id and a revision >= 1, so
        // a genuine acceptance always echoes both.
        if (!(idMatches && revisionMatches)) {
          return const _Verdict(
            _Status.keep,
            'acceptance did not name the row',
          );
        }
        if (entity == 'stock_movements') {
          // A movement is only settled once the till knows which snapshot
          // includes it. Without the sequence it would be counted twice the
          // moment the next snapshot arrived, so it stays queued; the exact
          // retry answers with the sequence.
          final stockSeq = result['stock_seq'];
          if (stockSeq is! int) {
            return const _Verdict(
              _Status.keep,
              'stock acceptance without stock_seq',
            );
          }
          return _Verdict(_Status.accepted, null, null, {
            'stock_seq': stockSeq,
          });
        }
        if (entity == 'table_status_events') {
          final seq = result['status_seq'];
          final outcome = result['outcome'];
          if (seq is! int ||
              seq < 1 ||
              (outcome != 'applied' && outcome != 'superseded')) {
            return const _Verdict(
              _Status.keep,
              'incomplete table status acceptance',
            );
          }
          return _Verdict(_Status.accepted, null, null, {
            'status_seq': seq,
            'outcome': outcome,
          });
        }
        return const _Verdict(_Status.accepted);
      case 'rejected':
        if (code == null || !DeadLetterStore.rejectionCodes.contains(code)) {
          return _Verdict(_Status.keep, 'rejected with unknown code $code');
        }
        return _Verdict(_Status.rejected, code, message, {
          for (final key in const [
            'holder_session_id',
            'holder_employee_name',
            'business_date',
          ])
            if (result[key] != null) key: result[key],
        });
      case 'retry':
        return _Verdict(_Status.keep, code ?? 'retry');
    }
    return const _Verdict(_Status.keep);
  }
}

class _Batch {
  const _Batch(this.entity, this.entries);
  final String entity;
  final List<OutboxEntry> entries;
}

enum _Status { accepted, rejected, keep }

class _Verdict {
  const _Verdict(
    this.status, [
    this.code,
    this.message,
    this.details = const {},
  ]);
  final _Status status;
  final String? code;
  final String? message;
  final Map<String, Object?> details;
}
