import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/models/order_item.dart';

void main() {
  group('Order', () {
    final items = <OrderItem>[
      OrderItem(
        id: 'oi-1',
        orderId: 'ord-1',
        productId: 'prod-1',
        productName: 'Nasi Goreng',
        unitPrice: 32000,
        quantity: 2,
      ),
      OrderItem(
        id: 'oi-2',
        orderId: 'ord-1',
        productId: 'prod-2',
        productName: 'Es Teh',
        unitPrice: 8000,
        quantity: 1,
      ),
    ];

    final fixture = Order(
      id: 'ord-1',
      number: '#ORD-0023',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1718000000000),
      type: OrderType.dineIn,
      table: const TableAssignment(tableId: 'tbl-1', tableName: 'T-01'),
      customerName: 'Budi',
      note: 'Window seat',
      subtotal: 72000,
      discount: 2000,
      tax: 7200,
      serviceChargeAmount: 1500,
      pb1Rate: 10.0,
      serviceChargeRate: 5.0,
      total: 77200,
      amountPaid: 80000,
      paymentMethod: PaymentMethod.cash,
      status: OrderStatus.paid,
      cashierId: 'u-1',
      cashierName: 'Sari',
      items: items,
    );

    test('round-trip toMap() -> fromMapRow() preserves every field', () {
      final restored = Order.fromMapRow(fixture.toMap(), items: items);
      expect(restored.id, fixture.id);
      expect(restored.number, fixture.number);
      expect(restored.createdAt, fixture.createdAt);
      expect(restored.type, fixture.type);
      expect(restored.table?.tableId, fixture.table?.tableId);
      expect(restored.table?.tableName, fixture.table?.tableName);
      expect(restored.customerName, fixture.customerName);
      expect(restored.note, fixture.note);
      expect(restored.subtotal, fixture.subtotal);
      expect(restored.discount, fixture.discount);
      expect(restored.tax, fixture.tax);
      expect(restored.serviceChargeAmount, fixture.serviceChargeAmount);
      expect(restored.pb1Rate, fixture.pb1Rate);
      expect(restored.serviceChargeRate, fixture.serviceChargeRate);
      expect(restored.total, fixture.total);
      expect(restored.amountPaid, fixture.amountPaid);
      expect(restored.paymentMethod, fixture.paymentMethod);
      expect(restored.status, fixture.status);
      expect(restored.cashierId, fixture.cashierId);
      expect(restored.cashierName, fixture.cashierName);
      // no item_count in toMap() -> resolvedItemCount falls back to items.length
      expect(restored.itemCount, isNull);
      expect(restored.resolvedItemCount, items.length);
    });

    test(
      'a map missing pb1_rate/service_charge_rate/service_charge_amount '
      'entirely (a pre-v19 row) reads as amount 0, rates null',
      () {
        final m = fixture.toMap()
          ..remove('pb1_rate')
          ..remove('service_charge_rate')
          ..remove('service_charge_amount');
        final restored = Order.fromMapRow(m, items: items);
        expect(restored.serviceChargeAmount, 0);
        expect(restored.pb1Rate, isNull);
        expect(restored.serviceChargeRate, isNull);
      },
    );

    group('resolvedItemCount (LEFT JOIN COUNT gotcha)', () {
      test('no item_count key -> falls back to items.length', () {
        final o = Order.fromMapRow(fixture.toMap(), items: items);
        expect(o.resolvedItemCount, items.length);
        expect(o.itemCount, isNull);
      });

      test('item_count: 5 + empty items -> 5 (joined count wins)', () {
        final m = fixture.toMap()..['item_count'] = 5;
        final o = Order.fromMapRow(m, items: const []);
        expect(o.resolvedItemCount, 5);
      });

      test('item_count: 5 + 2 items -> 5 (item_count wins over items.length)',
          () {
        final m = fixture.toMap()..['item_count'] = 5;
        final o = Order.fromMapRow(m, items: items);
        expect(o.resolvedItemCount, 5);
        expect(o.items.length, items.length);
      });
    });

    group('change (amountPaid - total)', () {
      test('positive when overpaid', () {
        expect(fixture.change, 80000 - 77200);
        expect(fixture.change, 2800);
      });

      test('zero when exact amount', () {
        final exact = _rebuild(fixture, amountPaid: fixture.total);
        expect(exact.change, 0);
      });

      test('negative when underpaid', () {
        final under = _rebuild(fixture, amountPaid: 50000);
        expect(under.change, 50000 - 77200);
        expect(under.change, isNegative);
      });
    });

    group('TableAssignment', () {
      test('null table_id in map -> table is null (takeaway order)', () {
        final m = fixture.toMap()
          ..['type'] = OrderType.takeaway.wire
          ..['table_id'] = null
          ..['table_name'] = null;
        expect(Order.fromMapRow(m).table, isNull);
      });

      test('missing table_name falls back to empty string', () {
        final m = fixture.toMap()..remove('table_name');
        final o = Order.fromMapRow(m);
        expect(o.table?.tableId, 'tbl-1');
        expect(o.table?.tableName, '');
      });
    });

    group('enum wire round-trip', () {
      test('OrderType: each known value + unknown fallback', () {
        for (final v in OrderType.values) {
          expect(OrderTypeX.fromWire(v.wire), v);
        }
        expect(OrderTypeX.fromWire('bogus'), OrderType.dineIn);
      });

      test('PaymentMethod: each known value + unknown fallback', () {
        for (final v in PaymentMethod.values) {
          expect(PaymentMethodX.fromWire(v.wire), v);
        }
        expect(PaymentMethodX.fromWire('bogus'), PaymentMethod.cash);
      });

      test('OrderStatus: each known value + unknown fallback', () {
        for (final v in OrderStatus.values) {
          expect(OrderStatusX.fromWire(v.wire), v);
        }
        expect(OrderStatusX.fromWire('bogus'), OrderStatus.pending);
      });

      test('OrderStatus.isTerminal only true for paid and cancelled', () {
        expect(OrderStatus.paid.isTerminal, isTrue);
        expect(OrderStatus.cancelled.isTerminal, isTrue);
        expect(OrderStatus.pending.isTerminal, isFalse);
        expect(OrderStatus.served.isTerminal, isFalse);
      });
    });
  });
}

/// Order has no copyWith; rebuild a fixture with one field changed.
Order _rebuild(Order src, {int? amountPaid}) => Order(
      id: src.id,
      number: src.number,
      createdAt: src.createdAt,
      type: src.type,
      table: src.table,
      customerName: src.customerName,
      note: src.note,
      subtotal: src.subtotal,
      discount: src.discount,
      tax: src.tax,
      serviceChargeAmount: src.serviceChargeAmount,
      pb1Rate: src.pb1Rate,
      serviceChargeRate: src.serviceChargeRate,
      total: src.total,
      amountPaid: amountPaid ?? src.amountPaid,
      paymentMethod: src.paymentMethod,
      status: src.status,
      cashierId: src.cashierId,
      cashierName: src.cashierName,
      items: src.items,
    );
