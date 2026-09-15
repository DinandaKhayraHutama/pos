import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/sync/dead_letter_store.dart';
import 'package:nti_pos/data/sync/order_push.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/session_push.dart';
import 'package:nti_pos/data/sync/wire_values.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

/// The key sets of the frozen v2 contract (`backend-go/api/openapi.yaml`).
/// `Order`, `OrderItem`, `OrderItemModifier` and `Session` are all
/// `additionalProperties: false`: one extra key and the server rejects the row.
const _orderKeys = {
  'id',
  'revision',
  'business_date',
  'number',
  'placed_at_ms',
  'server_time_delta_ms',
  'type',
  'status',
  'pos_session_id',
  'table_id',
  'table_name',
  'customer_name',
  'note',
  'subtotal',
  'discount',
  'tax',
  'service_charge_amount',
  'total',
  'amount_paid',
  'pb1_rate',
  'service_charge_rate',
  'payment_method',
  'promo_name',
  'cashier_id',
  'cashier_name',
  'outlet_name',
  'pos_name',
  'authorized_by',
  'void_reason',
  'refunded_amount',
  'items',
};
const _orderRequired = {
  'id',
  'revision',
  'business_date',
  'number',
  'placed_at_ms',
  'type',
  'status',
  'pos_session_id',
  'subtotal',
  'discount',
  'tax',
  'service_charge_amount',
  'total',
  'amount_paid',
  'payment_method',
  'cashier_name',
  'items',
};
const _itemKeys = {
  'id',
  'product_id',
  'product_name',
  'variant_name',
  'unit_price',
  'unit_cost',
  'quantity',
  'note',
  'category_id',
  'category_name',
  'modifiers',
};
const _modifierKeys = {
  'id',
  'group_name',
  'option_name',
  'price_delta',
  'sort_order',
};
const _sessionKeys = {
  'id',
  'revision',
  'employee_id',
  'employee_name',
  'pos_name',
  'outlet_name',
  'opened_at_ms',
  'opening_cash',
  'closed_at_ms',
  'counted_cash',
  'expected_cash',
  'closed_by_id',
  'closed_by_name',
  'note',
};

/// The fields the server lets change after a revision is first accepted.
const _mutableOrderKeys = {
  'revision',
  'status',
  'authorized_by',
  'void_reason',
  'refunded_amount',
};

const _uuidA = '6f1c3c4e-8a53-4c79-9d8e-0c6f1f2b7a10';
const _uuidB = '2b7d0d8a-51f6-4a55-8d0c-3d9f4e2c1b20';

void main() {
  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<String> openSession() async => (await ShiftRepository.instance.open(
    employeeId: 'e1',
    employeeName: 'Siti',
    openingCash: 100000,
    posId: 'reg-1',
    posName: 'Kasir 1',
  )).id;

  Future<Order> sell(String sessionId) => OrderRepository.instance.create(
    type: OrderType.dineIn,
    items: const [
      OrderItemDraft(
        productId: _uuidA,
        productName: 'Kopi Susu',
        unitPrice: 18000,
        quantity: 2,
        modifiers: [(groupName: 'Susu', optionName: 'Oat', priceDelta: 3000)],
      ),
      OrderItemDraft(
        productId: 'p_1726000000000',
        productName: 'Roti Bakar',
        unitPrice: 12000,
        quantity: 1,
      ),
    ],
    subtotal: 48000,
    discount: 2000,
    serviceChargeAmount: 2300,
    tax: 4830,
    total: 53130,
    amountPaid: 60000,
    pb1Rate: 10,
    serviceChargeRate: 5,
    paymentMethod: PaymentMethod.cash,
    cashierId: _uuidB,
    cashierName: 'Siti',
    posId: 'reg-1',
    posName: 'Kasir 1',
    posSessionId: sessionId,
    tableId: 'table_1726000000000',
    tableName: 'Meja 1',
  );

  Future<Map<String, dynamic>> snapshot(String entity, String id) async {
    final entry = (await OutboxStore.instance.pending(
      entity: entity,
    )).firstWhere((e) => e.entityId == id);
    return jsonDecode(entry.payload!) as Map<String, dynamic>;
  }

  test('an order carries exactly the Order schema keys, and reconciles the '
      'way the server checks it', () async {
    final order = await sell(await openSession());
    final payload = await snapshot(OrderPush.entity, order.id);

    expect(
      _orderKeys.containsAll(payload.keys),
      isTrue,
      reason: 'extra keys: ${payload.keys.toSet().difference(_orderKeys)}',
    );
    expect(payload.keys, containsAll(_orderRequired));
    expect(payload['revision'], 1);
    expect(payload['placed_at_ms'], order.createdAt.millisecondsSinceEpoch);
    expect(payload['business_date'], businessDateFor(order.createdAt));

    // total = subtotal - discount + tax + service charge, as validate.go says.
    expect(
      payload['total'],
      (payload['subtotal'] as int) -
          (payload['discount'] as int) +
          (payload['tax'] as int) +
          (payload['service_charge_amount'] as int),
    );

    final items = (payload['items'] as List).cast<Map<String, dynamic>>();
    var sum = 0;
    for (final item in items) {
      expect(_itemKeys.containsAll(item.keys), isTrue);
      sum += (item['unit_price'] as int) * (item['quantity'] as int);
      for (final m
          in (item['modifiers'] as List).cast<Map<String, dynamic>>()) {
        expect(m.keys.toSet(), _modifierKeys);
      }
    }
    // unit_price already includes modifier deltas; they are never added again.
    expect(sum, payload['subtotal']);
    expect(items.first['modifiers'], hasLength(1));
  });

  test('references that are not UUIDs go up as null, names stay', () async {
    final order = await sell(await openSession());
    final payload = await snapshot(OrderPush.entity, order.id);
    final items = (payload['items'] as List).cast<Map<String, dynamic>>();

    // A locally created table and product would otherwise get the whole sale
    // rejected: the server refuses an optional reference that is not a UUID.
    expect(payload['table_id'], isNull);
    expect(payload['table_name'], 'Meja 1');
    expect(payload['cashier_id'], _uuidB);
    expect(items[0]['product_id'], _uuidA);
    expect(items[1]['product_id'], isNull);
    expect(items[1]['product_name'], 'Roti Bakar');
  });

  test('a void is a new revision that repeats every immutable field', () async {
    final order = await sell(await openSession());
    final first = await snapshot(OrderPush.entity, order.id);

    await OrderRepository.instance.voidOrder(
      orderId: order.id,
      authorizedBy: 'Siwi',
      reason: 'Tamu membatalkan',
    );
    final second = await snapshot(OrderPush.entity, order.id);

    expect(second['revision'], 2);
    expect(second['status'], 'cancelled');
    expect(second['authorized_by'], 'Siwi');
    Map<String, dynamic> fixed(Map<String, dynamic> p) =>
        Map.of(p)..removeWhere((k, _) => _mutableOrderKeys.contains(k));
    // The server compares these byte for byte against the first revision; any
    // drift turns the void into a rejected "immutable fields changed".
    expect(fixed(second), fixed(first));
  });

  test('a kitchen status change goes up as a new revision', () async {
    final order = await sell(await openSession());
    await OrderRepository.instance.setStatus(order.id, OrderStatus.served);

    final payload = await snapshot(OrderPush.entity, order.id);
    expect(payload['revision'], 2);
    expect(payload['status'], 'served');
    expect(
      await OutboxStore.instance.pending(entity: OrderPush.entity),
      hasLength(1),
    );
  });

  test('a sale with no stored business day gets one, once', () async {
    final order = await sell(await openSession());
    await db.update(
      'orders',
      {'business_date': null},
      where: 'id = ?',
      whereArgs: [order.id],
    );

    final first = await OrderPush.payloadWithin(db, order.id);
    final stored = (await db.query(
      'orders',
      where: 'id = ?',
      whereArgs: [order.id],
    )).single['business_date'];
    expect(stored, first!['business_date']);

    final again = await OrderPush.payloadWithin(db, order.id);
    expect(again!['business_date'], stored);
  });

  test('a session carries exactly the Session schema keys', () async {
    final shift = await ShiftRepository.instance.open(
      employeeId: 'e1',
      employeeName: 'Siti',
      openingCash: 100000,
      posId: 'reg-1',
      posName: 'Kasir 1',
      outletId: 'outlet-1',
      outletName: 'Kemang',
    );
    await ShiftRepository.instance.close(
      shift: shift,
      countedCash: 120000,
      closedById: _uuidA,
      closedByName: 'Dani',
    );

    final payload = await snapshot(SessionPush.entity, shift.id);
    expect(
      _sessionKeys.containsAll(payload.keys),
      isTrue,
      reason: 'extra keys: ${payload.keys.toSet().difference(_sessionKeys)}',
    );
    // Identity comes from the token, never from the row.
    expect(payload.containsKey('pos_id'), isFalse);
    expect(payload.containsKey('outlet_id'), isFalse);
    expect(payload['revision'], 2);
    expect(payload['employee_id'], isNull);
    expect(payload['closed_by_id'], _uuidA);
    expect(payload['counted_cash'], 120000);
    expect(payload['expected_cash'], isA<int>());
    expect(payload['closed_at_ms'], isA<int>());
  });

  test('revisions keep increasing after an acknowledgement', () async {
    final session = await openSession();
    final entry = (await OutboxStore.instance.pending()).single;
    expect(
      await OutboxStore.instance.acknowledge(
        SessionPush.entity,
        session,
        entry.revision!,
      ),
      isTrue,
    );

    await OutboxStore.enqueueWithin(db, SessionPush.entity, session);
    // The server already stored revision 1; the next change must be above it.
    expect((await OutboxStore.instance.pending()).single.revision, 2);
  });

  test('an acknowledgement for an older revision removes nothing', () async {
    final session = await openSession();
    await OutboxStore.enqueueWithin(db, SessionPush.entity, session);

    expect(
      await OutboxStore.instance.acknowledge(SessionPush.entity, session, 1),
      isFalse,
    );
    expect((await OutboxStore.instance.pending()).single.revision, 2);
  });

  test('refused rows go back up as a fresh revision, and only while the row '
      'exists', () async {
    final session = await openSession();
    final sent = (await OutboxStore.instance.pending()).single;
    await DeadLetterStore.instance.moveFromOutbox(sent, code: 'register_busy');
    expect(await OutboxStore.instance.count(), 0);

    // A letter whose row is gone stays: its payload is then the only copy.
    final orphan = OutboxEntry(
      entity: OrderPush.entity,
      entityId: 'gone',
      attempts: 0,
      revision: 3,
      payload: '{"id":"gone"}',
    );
    await DeadLetterStore.instance.moveFromOutbox(orphan, code: 'settled');

    expect(await DeadLetterStore.instance.requeueAll(), 1);
    final back = (await OutboxStore.instance.pending()).single;
    expect(back.entityId, session);
    expect(back.revision, 2);
    final left = await DeadLetterStore.instance.all();
    expect(left.single.entityId, 'gone');
  });
}
