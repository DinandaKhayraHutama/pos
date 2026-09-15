import '../database/app_database.dart';
import '../repositories/stock_repository.dart';
import '../repositories/table_repository.dart';
import 'sync_client.dart';
import 'sync_state_store.dart';

/// What one pull run moved.
class SyncReport {
  const SyncReport({required this.applied, required this.deleted});
  final Map<String, int> applied;
  final Map<String, int> deleted;

  int get totalApplied => applied.values.fold(0, (a, b) => a + b);
  int get totalDeleted => deleted.values.fold(0, (a, b) => a + b);
  bool get changedAnything => totalApplied > 0 || totalDeleted > 0;
}

/// One feed as `GET /api/v2/sync/manifest` describes it.
class ManifestEntity {
  const ManifestEntity({
    required this.name,
    required this.key,
    required this.pull,
    required this.apply,
  });

  final String name;

  /// The columns that identify a row. `id` for most feeds; the pair for the
  /// join tables, where that pair IS the local primary key.
  final List<String> key;
  final bool pull;
  final String apply;

  static final _identifier = RegExp(r'^[a-z_][a-z0-9_]*$');

  /// Null for an entry this build cannot read. The fields that decide how a
  /// row is written are validated, because they end up in SQL.
  static ManifestEntity? tryParse(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['name'];
    final key = json['key'];
    final pull = json['pull'];
    final apply = json['apply'];
    if (name is! String || !_identifier.hasMatch(name)) return null;
    if (key is! List || key.isEmpty) return null;
    if (key.any((k) => k is! String || !_identifier.hasMatch(k))) return null;
    if (pull is! bool || apply is! String) return null;
    return ManifestEntity(
      name: name,
      key: key.cast<String>(),
      pull: pull,
      apply: apply,
    );
  }
}

/// Pulls the merchant's master data down to this device.
///
/// One direction only. The catalogue, staff and branch structure belong to the
/// Backoffice; a till editing a price locally would be a change with no
/// authority behind it and nowhere to go.
///
/// The properties that make this safe on a flaky connection:
///
/// - **Each page is applied in one transaction, together with its cursor.**
///   A crash mid-page rolls back both, and the next run re-fetches exactly the
///   same page.
/// - **Entities are applied in the server's manifest order.** The device's
///   SQLite has `PRAGMA foreign_keys` ON, so a product landing before its
///   category fails outright.
/// - **Rows are matched on the manifest's `key`, never REPLACEd.** REPLACE
///   deletes first, and `ON DELETE CASCADE` would take unchanged children with
///   it that a delta page will never send again.
/// - **Unknown keys are ignored.** A column the server adds tomorrow is not a
///   SQLite error that stops the whole page today.
/// - **`/sync/changes` is only a hint.** Its cursors decide which feeds are
///   worth a request; they are never stored as applied cursors.
class CatalogueSync {
  CatalogueSync(this._client);

  final SyncClient _client;

  /// The feeds this build knows how to store.
  ///
  /// Modifiers and promos (Fase 6) are written generically. Promo scoping is
  /// `promos.all_outlets` plus `promo_outlets`, so a promo the owner narrowed
  /// to one branch stays out of the others (`PromoRepository.all`).
  ///
  /// The stock feeds (Fase 5) and the floor plan (Fase 6) are outlet-scoped:
  /// the server sends this till's branch only. The stock feeds and
  /// `table_status` are not written generically — a snapshot changes what the
  /// till shows through `StockRepository` and `TableRepository`, which also
  /// account for this till's own changes the snapshot does not reflect yet.
  static const supportedEntities = {
    'employees',
    'outlets',
    'pos_registers',
    'categories',
    'products',
    'product_variants',
    'modifier_groups',
    'modifier_options',
    'product_modifier_groups',
    'product_modifier_options',
    'promos',
    'promo_outlets',
    'outlet_stock',
    'stock_movements',
    'tables',
    'table_status',
  };

  static const _bookkeeping = {'sync_seq', 'deleted_at_ms'};

  /// Pulls every supported feed, or — given [hints] from `/sync/changes` —
  /// only those whose server cursor is ahead of what this device applied.
  Future<SyncReport> run({int pageLimit = 500, Map<String, int>? hints}) async {
    final applied = <String, int>{};
    final deleted = <String, int>{};

    Set<String>? stale;
    if (hints != null) {
      stale = {};
      for (final name in supportedEntities) {
        final local = await SyncStateStore.instance.lastSeq(name);
        if ((hints[name] ?? 0) > local) stale.add(name);
      }
      // Nothing moved: no manifest, no pages, one request for the whole poll.
      if (stale.isEmpty) return SyncReport(applied: applied, deleted: deleted);
    }

    for (final entity in await _manifest()) {
      if (!entity.pull || !supportedEntities.contains(entity.name)) continue;
      if (stale != null && !stale.contains(entity.name)) continue;
      // Only in-place upserts are implemented, and nothing is published any
      // other way. A feed that asks for something else is left alone rather
      // than written in a way nobody reviewed.
      if (entity.apply != 'upsert') continue;

      final counts = await _pullEntity(entity, pageLimit);
      applied[entity.name] = counts.$1;
      deleted[entity.name] = counts.$2;
    }

    return SyncReport(applied: applied, deleted: deleted);
  }

  /// (applied, deleted) for one entity, paging until the server says it is done.
  Future<(int, int)> _pullEntity(ManifestEntity entity, int pageLimit) async {
    var applied = 0;
    var deleted = 0;
    var guard = 0;

    while (true) {
      // Re-read the cursor each page rather than tracking it in a local: the
      // previous page committed it, and reading it back is what proves that.
      final after = await SyncStateStore.instance.lastSeq(entity.name);
      final page = await _client.get('/sync/pull', {
        'entity': entity.name,
        'after_seq': '$after',
        'limit': '$pageLimit',
      });

      final rows = page['rows'];
      final nextSeq = page['next_seq'];
      final hasMore = page['has_more'];
      if (rows is! List ||
          nextSeq is! int ||
          nextSeq < 0 ||
          hasMore is! bool ||
          (page['entity'] != null && page['entity'] != entity.name) ||
          rows.any((r) => r is! Map<String, dynamic>)) {
        throw SyncException(
          SyncFailure.malformed,
          'pull page for ${entity.name} does not match the contract',
        );
      }

      if (rows.isNotEmpty) {
        final counts = await _applyPage(
          entity,
          rows.cast<Map<String, dynamic>>(),
          nextSeq > after ? nextSeq : after,
        );
        applied += counts.$1;
        deleted += counts.$2;
      } else if (nextSeq > after) {
        // Nothing to write, but the cursor still moved past rows this device
        // has no use for.
        final db = await AppDatabase.instance.db;
        await SyncStateStore.recordWithin(db, entity.name, nextSeq);
      }

      if (!hasMore) break;

      // A server that reports has_more without advancing the cursor would spin
      // here forever; bounded so a bug is a failed sync, not a flat battery.
      if (nextSeq <= after || ++guard > 1000) {
        throw SyncException(
          SyncFailure.server,
          'pagination for ${entity.name} did not advance',
        );
      }
    }

    return (applied, deleted);
  }

  /// Writes one page and its cursor in a single transaction.
  Future<(int, int)> _applyPage(
    ManifestEntity entity,
    List<Map<String, dynamic>> rows,
    int nextSeq,
  ) async {
    final db = await AppDatabase.instance.db;
    var applied = 0;
    var deleted = 0;

    await db.transaction((txn) async {
      // table_status has no local table of its own: it lands on `tables`.
      final generic = entity.name != 'table_status';
      final columns = !generic
          ? const <String>{}
          : {
              for (final c in await txn.rawQuery(
                'PRAGMA table_info(${entity.name})',
              ))
                c['name'] as String,
            };
      if (generic && (columns.isEmpty || !entity.key.every(columns.contains))) {
        throw SyncException(
          SyncFailure.malformed,
          '${entity.name} key does not match the local table',
        );
      }
      final where = entity.key.map((k) => '$k = ?').join(' AND ');

      for (final row in rows) {
        final keyValues = [for (final k in entity.key) row[k]];
        if (keyValues.any((v) => v is! String || v.isEmpty)) {
          throw SyncException(
            SyncFailure.malformed,
            '${entity.name} row has no usable key',
          );
        }

        if (entity.name == 'table_status') {
          // Its table's own tombstone, pulled first, already removed the row.
          if (row['deleted_at_ms'] != null) {
            deleted++;
            continue;
          }
          final status = row['status'];
          final seq = row['sync_seq'];
          final contested = row['contested'];
          if (!const {'available', 'occupied', 'reserved'}.contains(status) ||
              seq is! int ||
              seq < 0 ||
              contested is! bool) {
            throw const SyncException(
              SyncFailure.malformed,
              'table_status row has no status, sequence or contested flag',
            );
          }
          await TableRepository.applyServerStatusWithin(
            txn,
            tableId: keyValues[0] as String,
            status: status as String,
            seq: seq,
            contested: contested,
          );
          applied++;
          continue;
        }

        if (row['deleted_at_ms'] != null) {
          // A tombstone. The row is gone upstream, so it goes here too —
          // `ON DELETE CASCADE` in the local schema takes its children with it,
          // exactly as deleting through the app would.
          await txn.delete(entity.name, where: where, whereArgs: keyValues);
          deleted++;
          continue;
        }

        if (entity.name == 'outlet_stock') {
          final qty = row['qty_on_hand'];
          final seq = row['sync_seq'];
          if (qty is! int || seq is! int) {
            throw const SyncException(
              SyncFailure.malformed,
              'outlet_stock row has no quantity or sequence',
            );
          }
          await StockRepository.applyServerSnapshotWithin(
            txn,
            outletId: keyValues[0] as String,
            productId: keyValues[1] as String,
            qty: qty,
            seq: seq,
          );
          applied++;
          continue;
        }
        if (entity.name == 'stock_movements') {
          await StockRepository.applyServerMovementWithin(txn, row);
          applied++;
          continue;
        }

        final local = <String, Object?>{};
        for (final entry in row.entries) {
          if (_bookkeeping.contains(entry.key)) continue;
          // The server's `area` is what the till has always called `floor`.
          final column = entity.name == 'tables' && entry.key == 'area'
              ? 'floor'
              : entry.key;
          if (!columns.contains(column)) continue;
          final value = entry.value;
          if (value is bool) {
            local[column] = value ? 1 : 0;
          } else if (value == null || value is num || value is String) {
            local[column] = value;
          }
        }

        // UPDATE first, INSERT only when nothing matched. It also preserves
        // device-only columns the feed does not carry, such as local stock or
        // a table's status.
        final updated = await txn.update(
          entity.name,
          local,
          where: where,
          whereArgs: keyValues,
        );
        if (updated == 0) await txn.insert(entity.name, local);
        applied++;
      }

      await SyncStateStore.recordWithin(txn, entity.name, nextSeq);
    });

    return (applied, deleted);
  }

  Future<List<ManifestEntity>> _manifest() async {
    final body = await _client.get('/sync/manifest');
    final entities = body['entities'];
    if (entities is! List) {
      throw const SyncException(
        SyncFailure.malformed,
        'manifest has no entities',
      );
    }
    return [for (final json in entities) ?ManifestEntity.tryParse(json)];
  }
}
