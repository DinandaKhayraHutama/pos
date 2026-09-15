import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';

import '../helpers/db_helper.dart';

OrderItemDraft _draft(String name, {int qty = 1, int price = 10000}) =>
    OrderItemDraft(
      productId: 'p_$name',
      productName: name,
      unitPrice: price,
      quantity: qty,
    );

Future<Order> _create({
  required List<OrderItemDraft> items,
  OrderType type = OrderType.dineIn,
  String? tableId,
  String? tableName,
  String? posId,
  String? posName,
}) async {
  final subtotal = items.fold<int>(
      0, (s, i) => s + i.unitPrice * i.quantity);
  return OrderRepository.instance.create(
    type: type,
    items: items,
    subtotal: subtotal,
    discount: 0,
    tax: 0,
    total: subtotal,
    amountPaid: subtotal,
    paymentMethod: PaymentMethod.cash,
    cashierId: 'u_test',
    cashierName: 'Tester',
    tableId: tableId,
    tableName: tableName,
    posId: posId,
    posName: posName,
  );
}

void main() {
  setUpAll(() async {
    await initFfi();
  });

  group('OrderRepository', () {
    late Database db;

    setUp(() async {
      db = await openInMemoryAppDb(seed: false);
      await AppDatabase.instance.useTestDb(db);
    });
    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    group('create + recent (LEFT JOIN COUNT)', () {
      test('create with 2 items writes order + items, recent() returns it '
          'with resolvedItemCount == 2', () async {
        final order = await _create(items: [
          _draft('Nasi Goreng', price: 25000, qty: 1),
          _draft('Es Teh', price: 5000, qty: 2),
        ]);

        final recent = await OrderRepository.instance.recent();
        expect(recent, hasLength(1));
        expect(recent.first.id, order.id);

        // CRITICAL: the LEFT JOIN COUNT populates item_count, which
        // resolvedItemCount prefers over items.length (items is empty
        // from recent()). If the JOIN or GROUP BY is wrong, this fails.
        expect(recent.first.resolvedItemCount, 2,
            reason: 'LEFT JOIN COUNT should yield 2');
        expect(recent.first.itemCount, 2);
        expect(recent.first.items, isEmpty,
            reason: 'recent() does not join order_items rows');
      });

      test('create with 0 items -> resolvedItemCount == 0', () async {
        // LEFT JOIN on no items still yields one row with COUNT(oi.id)=0.
        await _create(items: const []);

        final recent = await OrderRepository.instance.recent();
        expect(recent, hasLength(1));
        expect(recent.first.resolvedItemCount, 0);
      });

      test('create with 3 items -> resolvedItemCount == 3', () async {
        await _create(items: [
          _draft('A', qty: 1),
          _draft('B', qty: 2),
          _draft('C', qty: 3),
        ]);

        final recent = await OrderRepository.instance.recent();
        expect(recent.first.resolvedItemCount, 3);
      });

      test('multiple orders — each resolvedItemCount tracks own line count',
          () async {
        await _create(items: [_draft('A'), _draft('B')]);
        await _create(items: [_draft('C')]);
        await _create(items: const []);

        final recent = await OrderRepository.instance.recent();
        expect(recent, hasLength(3));
        // recent() orders by created_at DESC -> last-created first.
        // Third order has 0 items, second has 1, first has 2.
        expect(recent[0].resolvedItemCount, 0);
        expect(recent[1].resolvedItemCount, 1);
        expect(recent[2].resolvedItemCount, 2);
      });
    });

    group('byId', () {
      test('returns the order WITH its items populated', () async {
        final created = await _create(items: [
          _draft('Nasi Goreng', price: 25000, qty: 1),
          _draft('Es Teh', price: 5000, qty: 2),
        ]);

        final fetched = await OrderRepository.instance.byId(created.id);
        expect(fetched, isNotNull);
        expect(fetched!.id, created.id);
        expect(fetched.items, hasLength(2));
        expect(fetched.items.map((i) => i.productName).toSet(),
            {'Nasi Goreng', 'Es Teh'});

        // byId doesn't run the COUNT join, so itemCount is null and
        // resolvedItemCount falls back to items.length.
        expect(fetched.itemCount, isNull);
        expect(fetched.resolvedItemCount, fetched.items.length);
        expect(fetched.resolvedItemCount, 2);
      });

      test('returns null for unknown id', () async {
        final fetched = await OrderRepository.instance.byId('does-not-exist');
        expect(fetched, isNull);
      });

      test('order with 0 items — byId returns empty items list', () async {
        final created = await _create(items: const []);
        final fetched = await OrderRepository.instance.byId(created.id);
        expect(fetched, isNotNull);
        expect(fetched!.items, isEmpty);
        expect(fetched.resolvedItemCount, 0);
      });
    });

    group('setStatus', () {
      test('persists OrderStatus.paid (re-read confirms)', () async {
        final created = await _create(items: [_draft('A')]);
        // create() always sets status = OrderStatus.preparing.
        expect(created.status, OrderStatus.preparing);

        await OrderRepository.instance.setStatus(created.id, OrderStatus.paid);

        final fetched = await OrderRepository.instance.byId(created.id);
        expect(fetched, isNotNull);
        expect(fetched!.status, OrderStatus.paid);
      });

      test('status filter on recent() only returns matching rows', () async {
        final o1 = await _create(items: [_draft('A')]);
        final o2 = await _create(items: [_draft('B')]);

        await OrderRepository.instance.setStatus(o1.id, OrderStatus.paid);
        // Cancelling goes through voidOrder now: setStatus refuses a status
        // that returns stock, because those have to carry an authorizer.
        await OrderRepository.instance.voidOrder(
          orderId: o2.id,
          authorizedBy: 'Siwi Wiyono Raharjo',
          reason: 'test',
        );

        final paid =
            await OrderRepository.instance.recent(status: OrderStatus.paid);
        expect(paid, hasLength(1));
        expect(paid.first.id, o1.id);

        final cancelled =
            await OrderRepository.instance.recent(status: OrderStatus.cancelled);
        expect(cancelled, hasLength(1));
        expect(cancelled.first.id, o2.id);
      });
    });

    group('dine-in table assignment', () {
      test('create with tableId wires table_id + table_name columns',
          () async {
        final created = await _create(
          items: [_draft('A')],
          type: OrderType.dineIn,
          tableId: 't_5',
          tableName: 'Meja 5',
        );

        // recent() reads the table_id / table_name columns.
        final recent = await OrderRepository.instance.recent();
        expect(recent.first.id, created.id);
        expect(recent.first.table, isNotNull);
        expect(recent.first.table?.tableId, 't_5');
        expect(recent.first.table?.tableName, 'Meja 5');
        expect(recent.first.type, OrderType.dineIn);
      });

      test('takeaway without tableId -> table is null', () async {
        await _create(items: [_draft('A')], type: OrderType.takeaway);

        final recent = await OrderRepository.instance.recent();
        expect(recent.first.table, isNull);
        expect(recent.first.type, OrderType.takeaway);
      });
    });

    group('order number sequencing', () {
      test('numbers run per register, prefixed from its name', () async {
        final o1 = await _create(
          items: [_draft('A')],
          posId: 'reg-1',
          posName: 'Kasir 1',
        );
        final o2 = await _create(
          items: [_draft('B')],
          posId: 'reg-1',
          posName: 'Kasir 1',
        );

        expect(o1.number, 'K1-0001');
        expect(o2.number, 'K1-0002');
        expect(o2.numberSeq, 2);
      });

      test('two tills do not march through the same numbers', () async {
        // The bug this replaced: a device-wide COUNT(*) meant the second till's
        // first sale of the day was numbered as though it followed the first
        // till's — two customers holding receipts with the same number.
        final kasir = await _create(
          items: [_draft('A')],
          posId: 'reg-1',
          posName: 'Kasir 1',
        );
        final takeaway = await _create(
          items: [_draft('B')],
          posId: 'reg-2',
          posName: 'Takeaway',
        );

        expect(kasir.number, 'K1-0001');
        expect(takeaway.number, 'TA-0001');
        expect(kasir.number, isNot(takeaway.number));
      });

      test('a voided sale does not free its number for reuse', () async {
        // MAX() rather than COUNT() is what guarantees this: a count would drop
        // back and hand the next sale a number already printed on a receipt.
        final first = await _create(
          items: [_draft('A')],
          posId: 'reg-1',
          posName: 'Kasir 1',
        );
        await OrderRepository.instance.voidOrder(
          orderId: first.id,
          authorizedBy: 'Manager',
          reason: 'test',
        );

        final next = await _create(
          items: [_draft('B')],
          posId: 'reg-1',
          posName: 'Kasir 1',
        );

        expect(next.number, 'K1-0002');
      });

      test('a till with no register still gets a printable number', () async {
        // Pre-v16 sessions carry no register, and the schema still allows it.
        final order = await _create(items: [_draft('A')]);

        expect(order.number, 'OR-0001');
      });
    });

    group('category snapshot — resolved inside create(), never via a provider', () {
      test('a product with a real category gets category_id/category_name '
          'stamped on its order_items row', () async {
        await db.insert('categories', {
          'id': 'cat_drinks',
          'name': 'Minuman',
          'sort_order': 0,
          'is_popular': 0,
        });
        await db.insert('products', {
          'id': 'p_kopi',
          'name': 'Kopi Susu',
          'category_id': 'cat_drinks',
          'price': 18000,
          'available': 1,
          'is_popular': 0,
          'sort_order': 0,
        });

        await OrderRepository.instance.create(
          type: OrderType.takeaway,
          items: [
            OrderItemDraft(
              productId: 'p_kopi',
              productName: 'Kopi Susu',
              unitPrice: 18000,
              quantity: 1,
            ),
          ],
          subtotal: 18000,
          discount: 0,
          tax: 0,
          total: 18000,
          amountPaid: 18000,
          paymentMethod: PaymentMethod.cash,
          cashierId: 'u_test',
          cashierName: 'Tester',
        );

        final row = (await db.query('order_items')).first;
        expect(row['category_id'], 'cat_drinks');
        expect(row['category_name'], 'Minuman');
      });

      test('a product with no category row (never existed / already deleted) '
          'stamps NULL rather than guessing', () async {
        // No insert into products/categories at all for this id — the same
        // shape as recent()'s existing "0 items" tests in this file.
        await _create(items: [_draft('ghost')]);

        final row = (await db.query('order_items')).first;
        expect(row['category_id'], isNull);
        expect(row['category_name'], isNull);
      });

      test('a category rename between two orders is reflected on the second, '
          'not retroactively on the first — because it is a snapshot', () async {
        await db.insert('categories', {
          'id': 'cat_drinks',
          'name': 'Minuman',
          'sort_order': 0,
          'is_popular': 0,
        });
        await db.insert('products', {
          'id': 'p_kopi',
          'name': 'Kopi Susu',
          'category_id': 'cat_drinks',
          'price': 18000,
          'available': 1,
          'is_popular': 0,
          'sort_order': 0,
        });
        final draft = OrderItemDraft(
          productId: 'p_kopi',
          productName: 'Kopi Susu',
          unitPrice: 18000,
          quantity: 1,
        );
        final first = await OrderRepository.instance.create(
          type: OrderType.takeaway,
          items: [draft],
          subtotal: 18000,
          discount: 0,
          tax: 0,
          total: 18000,
          amountPaid: 18000,
          paymentMethod: PaymentMethod.cash,
          cashierId: 'u_test',
          cashierName: 'Tester',
        );

        await db.update(
          'categories',
          {'name': 'Beverages'},
          where: 'id = ?',
          whereArgs: ['cat_drinks'],
        );

        final second = await OrderRepository.instance.create(
          type: OrderType.takeaway,
          items: [draft],
          subtotal: 18000,
          discount: 0,
          tax: 0,
          total: 18000,
          amountPaid: 18000,
          paymentMethod: PaymentMethod.cash,
          cashierId: 'u_test',
          cashierName: 'Tester',
        );

        final firstRow = (await db.query(
          'order_items',
          where: 'order_id = ?',
          whereArgs: [first.id],
        )).first;
        final secondRow = (await db.query(
          'order_items',
          where: 'order_id = ?',
          whereArgs: [second.id],
        )).first;
        expect(firstRow['category_name'], 'Minuman',
            reason: 'the snapshot from before the rename must not change');
        expect(secondRow['category_name'], 'Beverages');
      });
    });

    group('modifiers — persisted in create(), hydrated back by byId()', () {
      test('selected modifiers round-trip through create() -> byId()',
          () async {
        final created = await OrderRepository.instance.create(
          type: OrderType.takeaway,
          items: [
            OrderItemDraft(
              productId: 'p_kopi',
              productName: 'Kopi Susu',
              unitPrice: 26000,
              quantity: 1,
              modifiers: const [
                (groupName: 'Topping', optionName: 'Boba', priceDelta: 3000),
                (
                  groupName: 'Topping',
                  optionName: 'Cheese Foam',
                  priceDelta: 5000,
                ),
              ],
            ),
          ],
          subtotal: 26000,
          discount: 0,
          tax: 0,
          total: 26000,
          amountPaid: 26000,
          paymentMethod: PaymentMethod.cash,
          cashierId: 'u_test',
          cashierName: 'Tester',
        );

        final reloaded = await OrderRepository.instance.byId(created.id);
        expect(reloaded, isNotNull);
        expect(reloaded!.items, hasLength(1));
        final modifiers = reloaded.items.first.modifiers;
        expect(modifiers, hasLength(2));
        expect(modifiers.map((m) => m.optionName), ['Boba', 'Cheese Foam']);
        expect(modifiers.map((m) => m.priceDelta), [3000, 5000]);
      });

      test('a line with no modifiers hydrates to an empty list, not null',
          () async {
        final created = await _create(items: [_draft('plain')]);
        final reloaded = await OrderRepository.instance.byId(created.id);
        expect(reloaded!.items.single.modifiers, isEmpty);
      });

      test('two lines in one order keep their modifiers separate — no '
          'cross-contamination from the grouped hydration query', () async {
        final created = await OrderRepository.instance.create(
          type: OrderType.takeaway,
          items: [
            OrderItemDraft(
              productId: 'p_a',
              productName: 'A',
              unitPrice: 10000,
              quantity: 1,
              modifiers: const [
                (groupName: 'G', optionName: 'A-opt', priceDelta: 0),
              ],
            ),
            OrderItemDraft(
              productId: 'p_b',
              productName: 'B',
              unitPrice: 10000,
              quantity: 1,
              modifiers: const [
                (groupName: 'G', optionName: 'B-opt', priceDelta: 0),
              ],
            ),
          ],
          subtotal: 20000,
          discount: 0,
          tax: 0,
          total: 20000,
          amountPaid: 20000,
          paymentMethod: PaymentMethod.cash,
          cashierId: 'u_test',
          cashierName: 'Tester',
        );

        final reloaded = await OrderRepository.instance.byId(created.id);
        final itemA = reloaded!.items.firstWhere((i) => i.productId == 'p_a');
        final itemB = reloaded.items.firstWhere((i) => i.productId == 'p_b');
        expect(itemA.modifiers.single.optionName, 'A-opt');
        expect(itemB.modifiers.single.optionName, 'B-opt');
      });
    });
  });
}
