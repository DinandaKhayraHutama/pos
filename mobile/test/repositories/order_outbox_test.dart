import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/sync/order_push.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

/// Sales waiting to reach the server.
///
/// Every case here guards the same silent failure: a sale that exists on one
/// tablet and nowhere else. Nothing goes red — the cashier prints a receipt and
/// the customer leaves — and the money is simply absent from every report until
/// someone counts a drawer by hand.
void main() {
  late Database db;
  final orders = OrderRepository.instance;

  setUp(() async {
    db = await openInMemoryAppDb(seed: true);
    await AppDatabase.instance.useTestDb(db);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<String> productId() async =>
      (await db.query('products', limit: 1)).first['id'] as String;

  Future<Order> sell({String? posId, String? posName}) async {
    final id = await productId();
    return orders.create(
      type: OrderType.dineIn,
      items: [
        OrderItemDraft(
          productId: id,
          productName: 'Nasi Goreng',
          unitPrice: 15000,
          quantity: 1,
        ),
      ],
      subtotal: 15000,
      discount: 0,
      tax: 1500,
      total: 16500,
      amountPaid: 20000,
      paymentMethod: PaymentMethod.cash,
      cashierId: 'e1',
      cashierName: 'Siti',
      posId: posId,
      posName: posName,
    );
  }

  Future<List<OutboxEntry>> queued() =>
      OutboxStore.instance.pending(entity: OrderPush.entity);

  test('a completed sale is queued for the server', () async {
    final order = await sell();

    final jobs = await queued();
    expect(jobs, hasLength(1));
    expect(jobs.first.entityId, order.id);
  });

  test('voiding it does not queue a second job', () async {
    final order = await sell();
    await orders.voidOrder(
      orderId: order.id,
      authorizedBy: 'Siwi',
      reason: 'Wrong table',
    );

    // The queue is keyed on the row, so "sold then voided" is one push carrying
    // the void — not two racing each other to describe the same sale.
    expect(await queued(), hasLength(1));
  });

  test('a refund also rides the existing entry', () async {
    final order = await sell();
    await orders.refundOrder(
      orderId: order.id,
      authorizedBy: 'Siwi',
      reason: 'Customer complaint',
    );

    expect(await queued(), hasLength(1));
  });

  test('each sale is queued separately', () async {
    final first = await sell();
    final second = await sell();

    final jobs = await queued();
    expect(jobs, hasLength(2));
    expect(
      jobs.map((j) => j.entityId).toSet(),
      {first.id, second.id},
    );
  });

  test('a failed push keeps the sale queued', () async {
    final order = await sell();

    await OutboxStore.instance.recordFailure(
      OrderPush.entity,
      order.id,
      'network',
    );

    // Dropping it here is how a day's takings quietly stop existing.
    final jobs = await queued();
    expect(jobs, hasLength(1));
    expect(jobs.first.attempts, 1);
  });

  test('the sale survives in SQLite even though it never reached the server',
      () async {
    final order = await sell();

    // The premise of offline-first: the till records the sale locally first and
    // the network is a separate, failable concern.
    final rows = await db.query('orders', where: 'id = ?', whereArgs: [order.id]);
    expect(rows, hasLength(1));
    expect(rows.first['total'], 16500);
    expect(await queued(), hasLength(1));
  });

  test('a sale and its queue entry commit together', () async {
    // Both live in one transaction, so there is no state where the order exists
    // and nothing will ever send it.
    final order = await sell();

    final orderRows = await db.query(
      'orders',
      where: 'id = ?',
      whereArgs: [order.id],
    );
    final outboxRows = await db.query(
      OutboxStore.table,
      where: 'entity_id = ?',
      whereArgs: [order.id],
    );

    expect(orderRows, hasLength(1));
    expect(outboxRows, hasLength(1));
  });

  test('sessions and orders queue under different entities', () async {
    await sell();

    // The pusher asks for one entity at a time, so a sale must never be picked
    // up by the session push and sent to the wrong endpoint.
    final all = await OutboxStore.instance.pending();
    expect(all.every((j) => j.entity == OrderPush.entity), isTrue);
  });
}
