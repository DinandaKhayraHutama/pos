import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/models/bill.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/bill_repository.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/stock_repository.dart';
import 'package:nti_pos/data/sync/bill_push.dart';
import 'package:nti_pos/data/sync/kitchen_dispatch_push.dart';
import 'package:nti_pos/data/sync/order_push.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/stock_movement_push.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _outlet = '11111111-1111-4111-8111-111111111111';
const _register = '22222222-2222-4222-8222-222222222222';
const _session = '33333333-3333-4333-8333-333333333333';
const _nasi = '44444444-4444-4444-8444-444444444444';
const _teh = '55555555-5555-4555-8555-555555555555';

/// Saved bills on the till (paritas F4). Every case guards one of the four
/// promises: saving takes nothing, a dispatch consumes exactly once, settling
/// consumes nothing again, and only the owning till edits.
void main() {
  late Database db;
  final bills = BillRepository.instance;

  Future<void> seed() async {
    await db.insert('outlets', {'id': _outlet, 'name': 'Bintaro'});
    await db.insert('categories', {'id': 'cat', 'name': 'Makanan'});
    for (final p in [(_nasi, 'Nasi', 25000), (_teh, 'Teh', 10000)]) {
      await db.insert('products', {
        'id': p.$1,
        'category_id': 'cat',
        'name': p.$2,
        'price': p.$3,
        'emoji': '',
      });
      await db.insert('outlet_stock', {
        'outlet_id': _outlet,
        'product_id': p.$1,
        'stock': 10,
      });
    }
    await db.insert('shifts', {
      'id': _session,
      'employee_id': 'e1',
      'employee_name': 'Siti',
      'opened_at': DateTime.now().millisecondsSinceEpoch,
      'opening_cash': 0,
      'pos_id': _register,
      'pos_name': 'Kasir 1',
      'outlet_id': _outlet,
    });
  }

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    await seed();
  });

  tearDown(() async {
    TillBinding.configure(null);
    if (db.isOpen) await db.close();
  });

  BillLineDraft line(String product, String name, int qty, int price) =>
      BillLineDraft(
        productId: product,
        productName: name,
        unitPrice: price,
        quantity: qty,
        basePrice: price,
        priceSource: 'base',
        taxRateBp: 1000,
        unitCost: price ~/ 2,
      );

  BillDraft draft(List<BillLineDraft> lines, {String? billId}) => BillDraft(
    billId: billId,
    type: OrderType.dineIn.wire,
    pricing: const BillPricing(
      version: 1,
      serviceRateBp: 500,
      defaultTaxRateBp: 1000,
    ),
    lines: lines,
    cashierId: 'e1',
    cashierName: 'Siti',
    outletId: _outlet,
    posId: _register,
    posName: 'Kasir 1',
    posSessionId: _session,
  );

  Future<int?> shelf(String product) =>
      StockRepository.countAt(db, outletId: _outlet, productId: product);

  Future<int> count(String table) async =>
      ((await db.rawQuery('SELECT COUNT(*) AS n FROM $table')).first['n']! as num).toInt();

  test('saving a bill takes no money and moves no stock', () async {
    final bill = await bills.save(draft([line(_nasi, 'Nasi', 2, 25000)]));

    expect(bill.isEditable, isTrue);
    expect(bill.number, 'K1-B001');
    expect(bill.lines.single.dispatched, isFalse);
    expect(await shelf(_nasi), 10);
    expect(await count('orders'), 0);
    expect(await count('stock_movements'), 0);
  });

  test('a dispatch consumes each line once; a second sends only new lines', () async {
    var bill = await bills.saveAndDispatch(draft([line(_nasi, 'Nasi', 2, 25000)]));
    expect(await shelf(_nasi), 8);
    expect(bill.dispatches, hasLength(1));
    expect(bill.lines.single.dispatched, isTrue);

    // Adding a line to a saved bill moves nothing until it is sent.
    bill = await bills.save(
      draft([line(_teh, 'Teh', 1, 10000)], billId: bill.id),
    );
    expect(bill.lines, hasLength(2), reason: 'the dispatched line is kept');
    expect(await shelf(_teh), 10);

    final teh = bill.lines.firstWhere((l) => !l.dispatched);
    bill = await bills.saveAndDispatch(
      draft([
        BillLineDraft(
          id: teh.id,
          productId: _teh,
          productName: 'Teh',
          unitPrice: 10000,
          quantity: 1,
        ),
      ], billId: bill.id),
    );
    expect(await shelf(_nasi), 8, reason: 'the first line is not taken twice');
    expect(await shelf(_teh), 9);
    expect(bill.dispatches, hasLength(2));
  });

  test('a line the kitchen has cannot be sent back as an edit', () async {
    final bill = await bills.saveAndDispatch(
      draft([line(_nasi, 'Nasi', 2, 25000)]),
    );
    final sent = bill.lines.single;
    await expectLater(
      bills.save(
        draft([
          BillLineDraft(
            id: sent.id,
            productId: _nasi,
            productName: 'Nasi',
            unitPrice: 25000,
            quantity: 5,
          ),
        ], billId: bill.id),
      ),
      throwsA(isA<BillException>()),
    );
  });

  test('settling sends the rest, writes one receipt and closes the bill', () async {
    final saved = await bills.saveAndDispatch(
      draft([line(_nasi, 'Nasi', 2, 25000)]),
    );
    final order = await bills.settle(
      draft([line(_teh, 'Teh', 1, 10000)], billId: saved.id),
      writeReceipt: (txn, bill) => OrderRepository.instance.create(
        within: txn,
        billId: bill.id,
        type: OrderType.dineIn,
        items: [
          for (final l in bill.lines)
            OrderItemDraft(
              productId: l.productId!,
              productName: l.productName,
              unitPrice: l.unitPrice,
              quantity: l.quantity,
              billLineId: l.id,
            ),
        ],
        subtotal: 60000,
        discount: 0,
        tax: 0,
        total: 60000,
        amountPaid: 100000,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'e1',
        cashierName: 'Siti',
        outletId: _outlet,
        posSessionId: _session,
      ),
    );

    expect(order.status, OrderStatus.paid);
    expect(order.billId, saved.id);
    expect(await shelf(_nasi), 8, reason: 'settling takes nothing again');
    expect(await shelf(_teh), 9, reason: 'but sends what was left, once');
    final closed = (await bills.byId(saved.id))!;
    expect(closed.status, BillStatus.closed);
    expect(closed.closedOrderId, order.id);
    final items = await db.query('order_items', where: 'order_id = ?', whereArgs: [order.id]);
    expect(
      items.map((r) => r['bill_line_id']).toSet(),
      closed.lines.map((l) => l.id).toSet(),
    );
    expect(
      await count('stock_movements'),
      2,
      reason: 'one movement per dispatched product, none for the receipt',
    );
  });

  test('cancelling restocks only what came back; waste is no second debit', () async {
    final bill = await bills.saveAndDispatch(
      draft([line(_nasi, 'Nasi', 2, 25000), line(_teh, 'Teh', 1, 10000)]),
    );
    final nasiLine = bill.lines.firstWhere((l) => l.productId == _nasi);
    final tehLine = bill.lines.firstWhere((l) => l.productId == _teh);

    await expectLater(
      bills.cancel(
        bill.id,
        reason: 'Tamu batal',
        authorizedBy: 'Siwi',
        restock: {nasiLine.id: true},
        employeeId: 'e1',
        employeeName: 'Siti',
      ),
      throwsA(isA<BillException>()),
      reason: 'every dispatched line needs a decision',
    );

    await bills.cancel(
      bill.id,
      reason: 'Tamu batal',
      authorizedBy: 'Siwi',
      restock: {nasiLine.id: true, tehLine.id: false},
      employeeId: 'e1',
      employeeName: 'Siti',
    );
    expect(await shelf(_nasi), 10);
    expect(await shelf(_teh), 9);
    final cancelled = (await bills.byId(bill.id))!;
    expect(cancelled.status, BillStatus.cancelled);
    expect(cancelled.dispatches.single.status, DispatchStatus.cancelled);
    expect(cancelled.cancellation!.decisions, {nasiLine.id: true, tehLine.id: false});
    await expectLater(
      bills.save(draft([line(_nasi, 'Nasi', 1, 25000)], billId: bill.id)),
      throwsA(isA<BillException>()),
    );
  });

  test('a parked bill is read-only here', () async {
    final bill = await bills.save(draft([line(_nasi, 'Nasi', 1, 25000)]));
    await bills.markParked(bill.id, 2);
    await expectLater(
      bills.save(draft([line(_nasi, 'Nasi', 2, 25000)], billId: bill.id)),
      throwsA(isA<BillException>()),
    );
  });

  group('on an activated till', () {
    setUp(() {
      TillBinding.configure(
        const TillBinding(outletId: _outlet, registerId: _register),
      );
    });

    test('bill, dispatch and receipt go up as three rows, stock inside the dispatch', () async {
      final bill = await bills.saveAndDispatch(
        draft([line(_nasi, 'Nasi', 2, 25000)]),
      );
      await bills.settle(
        draft(const [], billId: bill.id),
        writeReceipt: (txn, b) => OrderRepository.instance.create(
          within: txn,
          billId: b.id,
          type: OrderType.dineIn,
          items: [
            for (final l in b.lines)
              OrderItemDraft(
                productId: l.productId!,
                productName: l.productName,
                unitPrice: l.unitPrice,
                quantity: l.quantity,
                billLineId: l.id,
              ),
          ],
          subtotal: 50000,
          discount: 0,
          tax: 0,
          total: 50000,
          amountPaid: 50000,
          paymentMethod: PaymentMethod.cash,
          cashierId: 'e1',
          cashierName: 'Siti',
          posSessionId: _session,
        ),
      );

      final entities = {
        for (final e in await OutboxStore.instance.pending()) e.entity,
      };
      expect(entities, {
        BillPush.entity,
        KitchenDispatchPush.entity,
        OrderPush.entity,
      });
      expect(
        await OutboxStore.instance.pending(entity: StockMovementPush.entity),
        isEmpty,
        reason: 'a dispatch movement travels inside its dispatch, never alone',
      );

      final billRow = (await OutboxStore.instance.pending(entity: BillPush.entity)).single;
      final billWire = jsonDecode(billRow.payload!) as Map<String, dynamic>;
      expect(billWire['status'], 'open', reason: 'the receipt closes it');
      expect(billWire['owner_generation'], 1);
      expect(billWire['revision'], billRow.revision);
      final wireLine = (billWire['lines'] as List).single as Map;

      final dispatchRow = (await OutboxStore.instance.pending(
        entity: KitchenDispatchPush.entity,
      )).single;
      final dispatchWire = jsonDecode(dispatchRow.payload!) as Map<String, dynamic>;
      expect(
        jsonEncode((dispatchWire['lines'] as List).single),
        jsonEncode(wireLine),
        reason: 'the server compares the two copies of a line',
      );
      final effect = (dispatchWire['stock_movements'] as List).single as Map;
      expect(effect['reason'], 'sale');
      expect(effect['delta_qty'], -2);

      final orderRow = (await OutboxStore.instance.pending(entity: OrderPush.entity)).single;
      final orderWire = jsonDecode(orderRow.payload!) as Map<String, dynamic>;
      expect(orderWire['status'], 'paid');
      expect(orderWire['bill_id'], bill.id);
      expect(
        ((orderWire['items'] as List).single as Map)['bill_line_id'],
        bill.lines.single.id,
      );
    });

    test('a status change re-queues the dispatch as a newer revision', () async {
      final bill = await bills.saveAndDispatch(
        draft([line(_nasi, 'Nasi', 1, 25000)]),
      );
      final dispatch = bill.dispatches.single;
      final before = (await OutboxStore.instance.pending(
        entity: KitchenDispatchPush.entity,
      )).single;
      await bills.setDispatchStatus(dispatch.id, DispatchStatus.ready);
      await bills.setDispatchStatus(dispatch.id, DispatchStatus.preparing);
      final after = (await OutboxStore.instance.pending(
        entity: KitchenDispatchPush.entity,
      )).single;
      expect(after.revision, before.revision! + 1, reason: 'backwards is ignored');
      expect((jsonDecode(after.payload!) as Map)['status'], 'ready');
    });

    test('a claimed bill is adopted with its server dispatches and revisions', () async {
      const billId = '66666666-6666-4666-8666-666666666666';
      const lineId = '77777777-7777-4777-8777-777777777777';
      const dispatchId = '88888888-8888-4888-8888-888888888888';
      final wireLine = {
        'id': lineId, 'seq': 0, 'product_id': _nasi, 'product_name': 'Nasi',
        'unit_price': 25000, 'quantity': 1, 'custom': false, 'modifiers': [],
      };
      final adopted = await bills.adoptClaimed({
        'summary': {'owner_generation': 3, 'revision': 4},
        'bill': {
          'id': billId, 'number': 'K2-B001', 'type': 'dineIn',
          'created_by_name': 'Dani', 'opened_at_ms': 1,
          'pricing': {'version': 1}, 'lines': [wireLine],
        },
        'dispatches': [
          {
            'id': dispatchId, 'revision': 2, 'status': 'preparing',
            'occurred_at_ms': 2, 'status_changed_at_ms': 3,
            'employee_name': 'Dani', 'line_ids': [lineId],
            'dispatch': {
              'id': dispatchId, 'revision': 2, 'bill_id': billId,
              'owner_generation': 3, 'pos_session_id': _session,
              'occurred_at_ms': 2, 'employee_name': 'Dani',
              'status': 'preparing', 'status_changed_at_ms': 3,
              'lines': [wireLine], 'stock_movements': [],
            },
          },
        ],
      }, sessionId: _session, outletId: _outlet, posId: _register);

      expect(adopted.isEditable, isTrue);
      expect(adopted.ownerGeneration, 3);
      expect(adopted.lines.single.dispatched, isTrue);
      expect(await shelf(_nasi), 10, reason: 'the server holds its stock already');

      await bills.save(draft([line(_teh, 'Teh', 1, 10000)], billId: billId));
      final billRow = (await OutboxStore.instance.pending(entity: BillPush.entity)).single;
      expect(billRow.revision, 5, reason: 'newer than the server\'s revision 4');

      await bills.setDispatchStatus(dispatchId, DispatchStatus.ready);
      final progress = (await OutboxStore.instance.pending(
        entity: KitchenDispatchPush.entity,
      )).single;
      final wire = jsonDecode(progress.payload!) as Map<String, dynamic>;
      expect(progress.revision, 3);
      expect(wire['status'], 'ready');
      expect(wire['owner_generation'], 3);
      expect(wire['lines'], [wireLine], reason: 'repeated exactly as handed over');
    });
  });
}
