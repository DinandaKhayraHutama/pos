import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/pricing/pricing.dart';
import '../database/app_database.dart';
import '../device/till_binding.dart';
import '../device/till_coordinator.dart';
import '../models/bill.dart';
import '../models/enums.dart';
import '../models/order.dart';
import '../models/stock_movement.dart';
import '../sync/bill_push.dart';
import '../sync/kitchen_dispatch_push.dart';
import '../sync/outbox_store.dart';
import 'stock_repository.dart';
import 'table_repository.dart';

/// Why a bill write was refused. [code] is what the screen explains.
class BillException implements Exception {
  const BillException(this.code);

  /// `bill_not_found`, `bill_not_editable` (closed, cancelled or parked),
  /// `bill_other_session` (owned under a drawer this till no longer runs),
  /// `bill_line_dispatched` (a line the kitchen has cannot change) or
  /// `bill_empty`.
  final String code;

  @override
  String toString() => 'BillException($code)';
}

/// A line as the editor hands it over to be saved. [id] is null for a line
/// that was never saved; the repository names it.
class BillLineDraft {
  const BillLineDraft({
    this.id,
    this.productId,
    required this.productName,
    this.variantId,
    this.variantName,
    this.modifiers = const [],
    required this.unitPrice,
    this.basePrice,
    this.priceSource,
    this.taxRateBp,
    this.unitCost,
    required this.quantity,
    this.note,
    this.custom = false,
    this.discount,
    this.lineDiscountId,
    this.lineDiscountName,
    this.lineDiscountAuthorizedById,
    this.lineDiscountAuthorizedByName,
  });

  final String? id;
  final String? productId;
  final String productName;
  final String? variantId;
  final String? variantName;
  final List<BillLineModifier> modifiers;
  final int unitPrice;
  final int? basePrice;
  final String? priceSource;
  final int? taxRateBp;
  final int? unitCost;
  final int quantity;
  final String? note;
  final bool custom;
  final Map<String, Object>? discount;
  final String? lineDiscountId;
  final String? lineDiscountName;
  final String? lineDiscountAuthorizedById;
  final String? lineDiscountAuthorizedByName;
}

/// Everything the editor knows about a bill at the moment it is saved.
class BillDraft {
  const BillDraft({
    this.billId,
    required this.type,
    this.salesTypeId,
    this.salesTypeName,
    this.tableId,
    this.tableName,
    this.tableSessionId,
    this.customerId,
    this.customerName,
    this.servedById,
    this.servedByName,
    this.note,
    required this.pricing,
    required this.lines,
    required this.cashierId,
    required this.cashierName,
    this.outletId,
    this.posId,
    this.posName,
    this.posSessionId,
  });

  /// Null for a bill never saved.
  final String? billId;
  final String type;
  final String? salesTypeId;
  final String? salesTypeName;
  final String? tableId;
  final String? tableName;
  final String? tableSessionId;
  final String? customerId;
  final String? customerName;
  final String? servedById;
  final String? servedByName;
  final String? note;

  /// For a new bill, the configuration to freeze. For a saved one, only its
  /// bill discount is taken — the rest stays what it was frozen at.
  final BillPricing pricing;

  /// EVERY line not yet sent to the kitchen — a line left out is removed from
  /// the bill. Lines the kitchen already has are kept as stored whatever the
  /// editor says, and naming one here is refused.
  final List<BillLineDraft> lines;
  final String cashierId;
  final String cashierName;
  final String? outletId;
  final String? posId;
  final String? posName;
  final String? posSessionId;
}

/// Saved bills on this till (v33, paritas F4).
///
/// The rules that carry the design, each enforced HERE and not only by the
/// buttons that call it:
///
/// 1. **Saving moves no money and no stock.** A save writes the bill and its
///    lines and queues one snapshot. Nothing else.
/// 2. **A dispatch consumes stock exactly once**, for the lines it sends, in
///    the transaction that records it — and marks those lines sent, after
///    which they never change.
/// 3. **Settling consumes nothing again.** It sends whatever was not sent yet
///    (the direct-sale case), writes the receipt, and closes the bill, in one
///    transaction.
/// 4. **Only an owned, open bill is edited**, and only under the drawer that
///    owns it; the server enforces the same with the owner generation.
class BillRepository {
  BillRepository._();
  static final BillRepository instance = BillRepository._();

  static const _uuid = Uuid();

  /// Whether bill writes go to the server — an activated till. The demo keeps
  /// its bills locally and pushes nothing.
  static bool get _connected => TillBinding.current != null;

  // ---- reads ---------------------------------------------------------------

  static Future<Bill?> byIdWithin(DatabaseExecutor db, String id) async {
    final rows = await db.query(
      'bills',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final lines = await db.query(
      'bill_lines',
      where: 'bill_id = ?',
      whereArgs: [id],
      orderBy: 'seq ASC, rowid ASC',
    );
    final dispatches = await db.query(
      'kitchen_dispatches',
      where: 'bill_id = ?',
      whereArgs: [id],
      orderBy: 'occurred_at ASC, rowid ASC',
    );
    return Bill.fromMap(
      rows.first,
      lines: [for (final r in lines) BillLine.fromMap(r)],
      dispatches: [for (final r in dispatches) KitchenDispatch.fromMap(r)],
    );
  }

  Future<Bill?> byId(String id) async =>
      byIdWithin(await AppDatabase.instance.db, id);

  /// Open bills at [outletId] this till knows: its own and the ones it
  /// parked. Newest first. [sessionId] narrows to one drawer's.
  Future<List<Bill>> openBills({String? outletId, String? sessionId}) async {
    final db = await AppDatabase.instance.db;
    final clauses = ["status = 'open'"];
    final args = <Object?>[];
    if (outletId != null) {
      clauses.add('(outlet_id = ? OR outlet_id IS NULL)');
      args.add(outletId);
    }
    if (sessionId != null) {
      clauses.add("pos_session_id = ? AND ownership = 'owned'");
      args.add(sessionId);
    }
    final rows = await db.query(
      'bills',
      columns: ['id'],
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'opened_at DESC',
    );
    return [for (final r in rows) (await byIdWithin(db, r['id'] as String))!];
  }

  /// Dispatches the kitchen has not finished, with their bill and lines,
  /// oldest first — the kitchen board.
  Future<List<({KitchenDispatch dispatch, Bill bill, List<BillLine> lines})>>
  activeDispatches({String? outletId}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.rawQuery(
      '''SELECT k.id, k.bill_id FROM kitchen_dispatches k
         JOIN bills b ON b.id = k.bill_id
         WHERE k.status IN ('queued', 'preparing', 'ready')
           ${outletId == null ? '' : 'AND (b.outlet_id = ? OR b.outlet_id IS NULL)'}
         ORDER BY k.occurred_at ASC, k.rowid ASC''',
      [?outletId],
    );
    final out =
        <({KitchenDispatch dispatch, Bill bill, List<BillLine> lines})>[];
    final bills = <String, Bill>{};
    for (final r in rows) {
      final billId = r['bill_id'] as String;
      final bill = bills[billId] ??= (await byIdWithin(db, billId))!;
      final dispatch = bill.dispatches.firstWhere((d) => d.id == r['id']);
      out.add((
        dispatch: dispatch,
        bill: bill,
        lines: [
          for (final l in bill.lines)
            if (l.dispatchId == dispatch.id) l,
        ],
      ));
    }
    return out;
  }

  // ---- guards --------------------------------------------------------------

  /// The bill, if this till may change it now, under [sessionId].
  static Future<Bill> _editable(
    DatabaseExecutor txn,
    String billId, {
    String? sessionId,
    bool allowClosed = false,
  }) async {
    final bill = await byIdWithin(txn, billId);
    if (bill == null) throw const BillException('bill_not_found');
    if (bill.ownership != BillOwnership.owned) {
      throw const BillException('bill_not_editable');
    }
    if (!bill.isOpen && !(allowClosed && bill.status == BillStatus.closed)) {
      throw const BillException('bill_not_editable');
    }
    if (_connected &&
        sessionId != null &&
        bill.posSessionId != null &&
        bill.posSessionId != sessionId) {
      throw const BillException('bill_other_session');
    }
    return bill;
  }

  /// The next label for a new bill on this till: `K1-B007`. A label, not a
  /// key — two installations may print the same one; the UUID is the key.
  static Future<String> _nextNumber(
    DatabaseExecutor txn,
    String? posId,
    String? posName,
  ) async {
    final rows = await txn.rawQuery(
      'SELECT COUNT(*) AS n FROM bills WHERE pos_id IS ?',
      [posId],
    );
    final next = ((rows.first['n'] as num?)?.toInt() ?? 0) + 1;
    final clean = (posName ?? '').toUpperCase().replaceAll(
      RegExp(r'[^A-Z0-9]'),
      '',
    );
    final digits = RegExp(r'\d+').firstMatch(clean)?.group(0);
    final letters = clean.replaceAll(RegExp(r'\d'), '');
    final prefix = clean.isEmpty
        ? 'B'
        : digits != null && letters.isNotEmpty
        ? '${letters[0]}$digits'
        : digits ?? (letters.length <= 2 ? letters : letters.substring(0, 2));
    return '$prefix-B${next.toString().padLeft(3, '0')}';
  }

  // ---- writes --------------------------------------------------------------

  /// Saves [draft], inside [txn]: a new bill, or a new revision of one this
  /// till owns. Queues the snapshot on an activated till. Moves no stock.
  static Future<Bill> saveWithin(DatabaseExecutor txn, BillDraft draft) async {
    if (_connected) {
      await TillCoordinator.assertSellable(
        txn,
        draft.posSessionId,
        draft.cashierId,
      );
    }
    final now = DateTime.now();
    Bill? existing;
    if (draft.billId != null) {
      existing = await _editable(
        txn,
        draft.billId!,
        sessionId: draft.posSessionId,
      );
    }
    final kept = [
      for (final l in existing?.lines ?? const <BillLine>[])
        if (l.dispatched) l,
    ];
    if (kept.isEmpty && draft.lines.isEmpty) {
      throw const BillException('bill_empty');
    }
    final keptIds = {for (final l in kept) l.id};
    for (final l in draft.lines) {
      if (l.id != null && keptIds.contains(l.id)) {
        throw const BillException('bill_line_dispatched');
      }
    }

    final billId = existing?.id ?? _uuid.v4();
    final pricing = existing == null
        ? draft.pricing
        : existing.pricing.withDiscount(
            billDiscount: draft.pricing.billDiscount,
            discountSource: draft.pricing.discountSource,
            promoId: draft.pricing.promoId,
            promoName: draft.pricing.promoName,
            discountId: draft.pricing.discountId,
            discountName: draft.pricing.discountName,
            discountAuthorizedById: draft.pricing.discountAuthorizedById,
            discountAuthorizedByName: draft.pricing.discountAuthorizedByName,
          );
    final bill = Bill(
      id: billId,
      number:
          existing?.number ??
          await _nextNumber(txn, draft.posId, draft.posName),
      status: BillStatus.open,
      ownerGeneration: existing?.ownerGeneration ?? 1,
      revision: existing?.revision ?? 0,
      outletId: existing?.outletId ?? draft.outletId,
      posId: existing?.posId ?? draft.posId,
      posSessionId: existing?.posSessionId ?? draft.posSessionId,
      // What kind of visit it is was decided when it was first saved: the
      // frozen prices depend on it.
      type: existing?.type ?? draft.type,
      salesTypeId: existing?.salesTypeId ?? draft.salesTypeId,
      salesTypeName: existing?.salesTypeName ?? draft.salesTypeName,
      tableId: draft.tableId,
      tableName: draft.tableName,
      tableSessionId: draft.tableSessionId,
      customerId: draft.customerId,
      customerName: draft.customerName,
      servedById: draft.servedById,
      servedByName: draft.servedByName,
      note: draft.note,
      createdById: existing?.createdById ?? draft.cashierId,
      createdByName: existing?.createdByName ?? draft.cashierName,
      pricing: pricing,
      openedAt: existing?.openedAt ?? now,
      updatedAt: now,
    );

    if (existing == null) {
      await txn.insert('bills', bill.toMap());
    } else {
      // An update, never a replace: REPLACE deletes the row first, and its
      // lines and dispatches cascade from it.
      await txn.update(
        'bills',
        bill.toMap(),
        where: 'id = ?',
        whereArgs: [billId],
      );
    }
    await txn.delete(
      'bill_lines',
      where: 'bill_id = ? AND dispatch_id IS NULL',
      whereArgs: [billId],
    );
    var seq = kept.fold<int>(-1, (m, l) => l.seq > m ? l.seq : m) + 1;
    for (final l in draft.lines) {
      await txn.insert(
        'bill_lines',
        BillLine(
          id: l.id ?? _uuid.v4(),
          billId: billId,
          seq: seq++,
          productId: l.productId,
          productName: l.productName,
          variantId: l.variantId,
          variantName: l.variantName,
          modifiers: l.modifiers,
          unitPrice: l.unitPrice,
          basePrice: l.basePrice,
          priceSource: l.priceSource,
          taxRateBp: l.taxRateBp,
          unitCost: l.unitCost,
          quantity: l.quantity,
          note: l.note,
          custom: l.custom,
          discount: DiscountSpec.fromJson(l.discount),
          lineDiscountId: l.lineDiscountId,
          lineDiscountName: l.lineDiscountName,
          lineDiscountAuthorizedById: l.lineDiscountAuthorizedById,
          lineDiscountAuthorizedByName: l.lineDiscountAuthorizedByName,
          createdAt: now,
        ).toMap(),
      );
    }
    await _snapshotCategories(txn, billId);
    await _bumpRevision(txn, billId);
    return (await byIdWithin(txn, billId))!;
  }

  /// Copies each new line's category and brand, from the product it names,
  /// the same way a receipt snapshots them at checkout.
  static Future<void> _snapshotCategories(
    DatabaseExecutor txn,
    String billId,
  ) async {
    await txn.rawUpdate(
      '''UPDATE bill_lines SET
           category_id = (SELECT p.category_id FROM products p WHERE p.id = bill_lines.product_id),
           brand_id = (SELECT p.brand_id FROM products p WHERE p.id = bill_lines.product_id)
         WHERE bill_id = ? AND dispatch_id IS NULL AND category_id IS NULL''',
      [billId],
    );
    await txn.rawUpdate(
      '''UPDATE bill_lines SET
           category_name = (SELECT c.name FROM categories c WHERE c.id = bill_lines.category_id)
         WHERE bill_id = ? AND dispatch_id IS NULL AND category_id IS NOT NULL''',
      [billId],
    );
  }

  /// Queues the bill (activated till) and records the revision it went up
  /// at; the demo just counts.
  static Future<void> _bumpRevision(DatabaseExecutor txn, String billId) async {
    if (_connected) {
      await OutboxStore.enqueueWithin(txn, BillPush.entity, billId);
      final rows = await txn.query(
        OutboxStore.revisionsTable,
        columns: ['revision'],
        where: 'entity = ? AND entity_id = ?',
        whereArgs: [BillPush.entity, billId],
        limit: 1,
      );
      final revision = rows.isEmpty
          ? 0
          : (rows.first['revision'] as num).toInt();
      await txn.update(
        'bills',
        {'revision': revision},
        where: 'id = ?',
        whereArgs: [billId],
      );
    } else {
      await txn.rawUpdate(
        'UPDATE bills SET revision = revision + 1 WHERE id = ?',
        [billId],
      );
    }
  }

  /// Sends every line of [billId] the kitchen does not have yet, inside
  /// [txn]: one batch, its stock consumed now and exactly once. Returns null
  /// when there was nothing to send.
  static Future<KitchenDispatch?> dispatchWithin(
    DatabaseExecutor txn,
    String billId, {
    required String employeeId,
    required String employeeName,
    String? sessionId,
  }) async {
    final bill = await _editable(txn, billId, sessionId: sessionId);
    final pending = bill.pendingLines.toList();
    if (pending.isEmpty) return null;
    final now = DateTime.now();
    final dispatch = KitchenDispatch(
      id: _uuid.v4(),
      billId: billId,
      status: DispatchStatus.queued,
      occurredAt: now,
      statusChangedAt: now,
      employeeId: employeeId,
      employeeName: employeeName,
      posSessionId: bill.posSessionId,
      outletId: bill.outletId,
    );
    await txn.insert('kitchen_dispatches', dispatch.toMap());
    await txn.update(
      'bill_lines',
      {'dispatch_id': dispatch.id},
      where: 'bill_id = ? AND dispatch_id IS NULL',
      whereArgs: [billId],
    );
    // The same quantities per product a checkout would take; several lines of
    // one product (different modifiers) fold into one movement.
    final quantities = <String, int>{};
    for (final l in pending) {
      if (l.custom || l.productId == null) continue;
      quantities.update(
        l.productId!,
        (q) => q - l.quantity,
        ifAbsent: () => -l.quantity,
      );
    }
    await StockRepository.moveWithin(
      txn,
      outletId: bill.outletId,
      quantities: quantities,
      reason: StockReason.sale,
      employeeId: employeeId,
      employeeName: employeeName,
      note: bill.number,
      sourceKind: 'dispatch',
      sourceId: dispatch.id,
    );
    if (_connected) {
      await OutboxStore.enqueueWithin(
        txn,
        KitchenDispatchPush.entity,
        dispatch.id,
      );
    }
    await txn.update(
      'bills',
      {'updated_at': now.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [billId],
    );
    return dispatch;
  }

  /// Saves [draft] and sends its new lines to the kitchen, in one
  /// transaction.
  Future<Bill> saveAndDispatch(BillDraft draft) async {
    final db = await AppDatabase.instance.db;
    return db.transaction((txn) async {
      final bill = await saveWithin(txn, draft);
      await dispatchWithin(
        txn,
        bill.id,
        employeeId: draft.cashierId,
        employeeName: draft.cashierName,
        sessionId: draft.posSessionId,
      );
      return (await byIdWithin(txn, bill.id))!;
    });
  }

  Future<Bill> save(BillDraft draft) async {
    final db = await AppDatabase.instance.db;
    return db.transaction((txn) => saveWithin(txn, draft));
  }

  /// Settles a bill, in ONE transaction: saves [draft], sends anything the
  /// kitchen does not have yet, writes the receipt through [writeReceipt]
  /// (which gets the saved bill, so its lines can name their bill lines) and
  /// closes the bill. A crash at any step leaves none of them.
  Future<Order> settle(
    BillDraft draft, {
    required Future<Order> Function(DatabaseExecutor txn, Bill bill)
    writeReceipt,
  }) async {
    final db = await AppDatabase.instance.db;
    return db.transaction((txn) async {
      final saved = await saveWithin(txn, draft);
      await dispatchWithin(
        txn,
        saved.id,
        employeeId: draft.cashierId,
        employeeName: draft.cashierName,
        sessionId: draft.posSessionId,
      );
      final bill = (await byIdWithin(txn, saved.id))!;
      final order = await writeReceipt(txn, bill);
      final now = DateTime.now().millisecondsSinceEpoch;
      await txn.update(
        'bills',
        {
          'status': BillStatus.closed.wire,
          'closed_order_id': order.id,
          'closed_at': now,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [bill.id],
      );
      return order;
    });
  }

  /// Cancels an unpaid bill. Every line already sent to the kitchen needs a
  /// decision in [restock]: true puts it back on the shelf, false records it
  /// as made and thrown away — a classification of stock already consumed,
  /// never a second debit.
  Future<void> cancel(
    String billId, {
    required String reason,
    required String authorizedBy,
    String? authorizedById,
    required Map<String, bool> restock,
    required String employeeId,
    required String employeeName,
    String? sessionId,
  }) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      final bill = await _editable(txn, billId, sessionId: sessionId);
      final dispatched = bill.lines.where((l) => l.dispatched).toList();
      for (final l in dispatched) {
        if (!restock.containsKey(l.id)) {
          throw const BillException('bill_line_decision_missing');
        }
      }
      final returns = <String, int>{};
      for (final l in dispatched) {
        if (restock[l.id] != true || l.custom || l.productId == null) continue;
        returns.update(
          l.productId!,
          (q) => q + l.quantity,
          ifAbsent: () => l.quantity,
        );
      }
      await StockRepository.moveWithin(
        txn,
        outletId: bill.outletId,
        quantities: returns,
        reason: StockReason.voidReturn,
        employeeId: employeeId,
        employeeName: employeeName,
        note: reason,
        sourceKind: 'bill_cancel',
        sourceId: billId,
      );
      final now = DateTime.now();
      await txn.update(
        'kitchen_dispatches',
        {
          'status': DispatchStatus.cancelled.wire,
          'status_changed_at': now.millisecondsSinceEpoch,
        },
        where: "bill_id = ? AND status IN ('queued', 'preparing', 'ready')",
        whereArgs: [billId],
      );
      await txn.update(
        'bills',
        {
          'status': BillStatus.cancelled.wire,
          'updated_at': now.millisecondsSinceEpoch,
          'cancel': jsonEncode(
            BillCancellation(
              reason: reason,
              authorizedBy: authorizedBy,
              authorizedById: authorizedById,
              cancelledAt: now,
              decisions: {for (final l in dispatched) l.id: restock[l.id]!},
            ).toJson(),
          ),
        },
        where: 'id = ?',
        whereArgs: [billId],
      );
      await _bumpRevision(txn, billId);
    });
  }

  /// Moves one dispatch along the kitchen flow. Forward only; the kitchen
  /// keeps working after the bill is paid, so a closed bill still takes it.
  Future<void> setDispatchStatus(
    String dispatchId,
    DispatchStatus status,
  ) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'kitchen_dispatches',
        where: 'id = ?',
        whereArgs: [dispatchId],
        limit: 1,
      );
      if (rows.isEmpty) throw const BillException('bill_not_found');
      final current = KitchenDispatch.fromMap(rows.first);
      await _editable(txn, current.billId, allowClosed: true);
      if (status == DispatchStatus.cancelled ||
          status.index <= current.status.index) {
        return;
      }
      await txn.update(
        'kitchen_dispatches',
        {
          'status': status.wire,
          'status_changed_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [dispatchId],
      );
      if (_connected) {
        await OutboxStore.enqueueWithin(
          txn,
          KitchenDispatchPush.entity,
          dispatchId,
        );
      }
    });
  }

  // ---- ownership -----------------------------------------------------------

  /// Whether anything about [billId] is still owed to the server: the bill
  /// itself, one of its dispatches, or a refused row of either. A bill can
  /// only be parked once the server holds all of it.
  Future<bool> hasUnsentChanges(String billId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.rawQuery(
      '''SELECT 1 FROM _outbox WHERE (entity = 'bills' AND entity_id = ?)
           OR (entity = 'kitchen_dispatches' AND entity_id IN
               (SELECT id FROM kitchen_dispatches WHERE bill_id = ?))
         UNION ALL
         SELECT 1 FROM _dead_letter WHERE (entity = 'bills' AND entity_id = ?)
           OR (entity = 'kitchen_dispatches' AND entity_id IN
               (SELECT id FROM kitchen_dispatches WHERE bill_id = ?))
         LIMIT 1''',
      [billId, billId, billId, billId],
    );
    return rows.isNotEmpty;
  }

  /// What the server must already hold before a park: the last revision this
  /// till pushed and how many dispatches it sent.
  Future<({int revision, int dispatches})> parkBasis(String billId) async {
    final db = await AppDatabase.instance.db;
    final rev = await db.query(
      OutboxStore.revisionsTable,
      columns: ['revision'],
      where: 'entity = ? AND entity_id = ?',
      whereArgs: [BillPush.entity, billId],
      limit: 1,
    );
    final count = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM kitchen_dispatches WHERE bill_id = ?',
      [billId],
    );
    return (
      revision: rev.isEmpty ? 0 : (rev.first['revision'] as num).toInt(),
      dispatches: (count.first['n'] as num).toInt(),
    );
  }

  /// The server accepted the park: the bill is no longer this till's to edit.
  Future<void> markParked(String billId, int generation) async {
    final db = await AppDatabase.instance.db;
    await db.update(
      'bills',
      {
        'ownership': BillOwnership.parked.wire,
        'owner_generation': generation,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [billId],
    );
  }

  /// Stores a bill the server just handed this till (a claim), as owned,
  /// under [sessionId], in one transaction — before anyone can edit it.
  ///
  /// Its dispatches are the server's already: they are stored with their
  /// payload as `origin = 'server'`, and their stock is never written here as
  /// a movement this till owes. The push revisions are seeded from the
  /// server's, so this till's next save is newer than the last one accepted.
  Future<Bill> adoptClaimed(
    Map<String, dynamic> detail, {
    required String sessionId,
    String? outletId,
    String? posId,
  }) async {
    final db = await AppDatabase.instance.db;
    final summary = (detail['summary'] as Map).cast<String, dynamic>();
    final wire = (detail['bill'] as Map).cast<String, dynamic>();
    final billId = wire['id'] as String;
    final dispatches = [
      for (final d in (detail['dispatches'] as List? ?? const []))
        (d as Map).cast<String, dynamic>(),
    ];
    return db.transaction((txn) async {
      final pricing = BillPricing.fromJson(wire['pricing']);
      final generation = (summary['owner_generation'] as num).toInt();
      final revision = (summary['revision'] as num).toInt();
      final row = {
        'id': billId,
        'number': wire['number'],
        'status': BillStatus.open.wire,
        'ownership': BillOwnership.owned.wire,
        'owner_generation': generation,
        'revision': revision,
        'outlet_id': outletId,
        'pos_id': posId,
        'pos_session_id': sessionId,
        'type': wire['type'],
        'sales_type_id': wire['sales_type_id'],
        'sales_type_name': wire['sales_type_name'],
        'table_id': wire['table_id'],
        'table_name': wire['table_name'],
        'table_session_id': wire['table_session_id'],
        'customer_id': wire['customer_id'],
        'customer_name': wire['customer_name'],
        'served_by_id': wire['served_by_id'],
        'served_by_name': wire['served_by_name'],
        'note': wire['note'],
        'created_by_id': wire['created_by_id'],
        'created_by_name': wire['created_by_name'],
        'pricing': jsonEncode(pricing.toJson()),
        'opened_at': (wire['opened_at_ms'] as num).toInt(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'closed_order_id': null,
        'closed_at': null,
        'cancel': null,
      };
      final existing = await txn.query(
        'bills',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [billId],
      );
      if (existing.isEmpty) {
        await txn.insert('bills', row);
      } else {
        await txn.update('bills', row, where: 'id = ?', whereArgs: [billId]);
      }
      // The server's picture replaces this till's: lines and dispatches are
      // rewritten from it (children only — the bill row is updated above).
      await txn.delete('bill_lines', where: 'bill_id = ?', whereArgs: [billId]);
      await txn.delete(
        'kitchen_dispatches',
        where: 'bill_id = ?',
        whereArgs: [billId],
      );
      final lineDispatch = <String, String>{};
      for (final d in dispatches) {
        final full = (d['dispatch'] as Map?)?.cast<String, dynamic>();
        await txn.insert('kitchen_dispatches', {
          'id': d['id'],
          'bill_id': billId,
          'status': d['status'],
          'occurred_at': (d['occurred_at_ms'] as num).toInt(),
          'status_changed_at': (d['status_changed_at_ms'] as num).toInt(),
          'employee_name': d['employee_name'] ?? '',
          'employee_id': full?['employee_id'],
          'pos_session_id': full?['pos_session_id'],
          'outlet_id': outletId,
          'origin': 'server',
          'payload': full == null ? null : jsonEncode(full),
        });
        for (final lineId in (d['line_ids'] as List? ?? const [])) {
          lineDispatch[lineId as String] = d['id'] as String;
        }
        await _seedRevision(
          txn,
          KitchenDispatchPush.entity,
          d['id'] as String,
          (d['revision'] as num).toInt(),
        );
      }
      final lines = (wire['lines'] as List? ?? const []);
      for (final l in lines) {
        final line = BillLine.fromWire(
          billId,
          (l as Map).cast<String, dynamic>(),
          dispatchId: lineDispatch[l['id']],
        );
        await txn.insert('bill_lines', line.toMap());
      }
      await _seedRevision(txn, BillPush.entity, billId, revision);
      return (await byIdWithin(txn, billId))!;
    });
  }

  static Future<void> _seedRevision(
    DatabaseExecutor txn,
    String entity,
    String id,
    int revision,
  ) async {
    final rows = await txn.query(
      OutboxStore.revisionsTable,
      columns: ['revision'],
      where: 'entity = ? AND entity_id = ?',
      whereArgs: [entity, id],
      limit: 1,
    );
    if (rows.isEmpty) {
      await txn.insert(OutboxStore.revisionsTable, {
        'entity': entity,
        'entity_id': id,
        'revision': revision,
      });
    } else if ((rows.first['revision'] as num).toInt() < revision) {
      await txn.update(
        OutboxStore.revisionsTable,
        {'revision': revision},
        where: 'entity = ? AND entity_id = ?',
        whereArgs: [entity, id],
      );
    }
  }

  // ---- table seatings --------------------------------------------------------

  /// The open seating at [tableId] this till knows of.
  Future<TableSeating?> openSeating(String tableId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'table_sessions',
      where: 'table_id = ? AND closed_at IS NULL',
      whereArgs: [tableId],
      orderBy: 'opened_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : TableSeating.fromMap(rows.first);
  }

  Future<List<TableSeating>> openSeatings({String? outletId}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'table_sessions',
      where: outletId == null
          ? 'closed_at IS NULL'
          : 'closed_at IS NULL AND (outlet_id = ? OR outlet_id IS NULL)',
      whereArgs: outletId == null ? null : [outletId],
      orderBy: 'opened_at ASC',
    );
    return [for (final r in rows) TableSeating.fromMap(r)];
  }

  /// Records a seating: the one the server just opened on an activated till,
  /// or a local one in the demo — where the table's status moves with it.
  Future<void> recordSeating(TableSeating seating) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'table_sessions',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [seating.id],
      );
      if (existing.isEmpty) {
        await txn.insert('table_sessions', seating.toMap());
      } else {
        await txn.update(
          'table_sessions',
          seating.toMap(),
          where: 'id = ?',
          whereArgs: [seating.id],
        );
      }
      if (!_connected) {
        await TableRepository.setStatusWithin(
          txn,
          seating.tableId,
          seating.isOpen ? TableStatus.occupied : TableStatus.available,
        );
      }
    });
  }

  /// Open bills at [seatingId] this till knows of — a demo seating can only be
  /// cleared once none is left.
  Future<int> openBillsAtSeating(String seatingId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS n FROM bills WHERE table_session_id = ? AND status = 'open'",
      [seatingId],
    );
    return (rows.first['n'] as num).toInt();
  }

  /// Replaces the cached board of the outlet's open bills and seatings with
  /// the one the server just returned. A read cache: it never makes a bill
  /// editable here.
  Future<void> cacheBoard(String outletId, Map<String, dynamic> board) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      await txn.delete(
        '_bill_board',
        where: 'outlet_id = ?',
        whereArgs: [outletId],
      );
      await txn.insert('_bill_board', {
        'outlet_id': outletId,
        'payload': jsonEncode(board),
        'fetched_at': DateTime.now().millisecondsSinceEpoch,
      });
      // The server's open seatings are this outlet's truth: mirror them so
      // the table board and the picker can name the seating offline.
      final seatings = [
        for (final s in (board['table_sessions'] as List? ?? const []))
          TableSeating.fromWire(
            (s as Map).cast<String, dynamic>(),
            outletId: outletId,
          ),
      ];
      final open = {for (final s in seatings) s.id};
      final known = await txn.query(
        'table_sessions',
        columns: ['id'],
        where: 'closed_at IS NULL AND (outlet_id = ? OR outlet_id IS NULL)',
        whereArgs: [outletId],
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final r in known) {
        if (!open.contains(r['id'])) {
          await txn.update(
            'table_sessions',
            {'closed_at': now},
            where: 'id = ?',
            whereArgs: [r['id']],
          );
        }
      }
      for (final s in seatings) {
        final exists = await txn.query(
          'table_sessions',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [s.id],
        );
        if (exists.isEmpty) {
          await txn.insert('table_sessions', s.toMap());
        } else {
          await txn.update(
            'table_sessions',
            s.toMap(),
            where: 'id = ?',
            whereArgs: [s.id],
          );
        }
      }
    });
  }

  Future<({Map<String, dynamic> board, DateTime fetchedAt})?> cachedBoard(
    String outletId,
  ) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      '_bill_board',
      where: 'outlet_id = ?',
      whereArgs: [outletId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (
      board: (jsonDecode(rows.first['payload'] as String) as Map)
          .cast<String, dynamic>(),
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(
        (rows.first['fetched_at'] as num).toInt(),
      ),
    );
  }
}
