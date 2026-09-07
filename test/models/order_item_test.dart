import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/models/order_item.dart';

void main() {
  group('OrderItem', () {
    final fixture = OrderItem(
      id: 'oi-1',
      orderId: 'ord-1',
      productId: 'prod-1',
      productName: 'Nasi Goreng',
      unitPrice: 32000,
      quantity: 2,
      note: 'pedas',
    );

    test('lineTotal is unitPrice * quantity', () {
      expect(fixture.lineTotal, 64000);
    });

    test('round-trip toMap() -> fromMap() preserves every field', () {
      final restored = OrderItem.fromMap(fixture.toMap());
      expect(restored.id, fixture.id);
      expect(restored.orderId, fixture.orderId);
      expect(restored.productId, fixture.productId);
      expect(restored.productName, fixture.productName);
      expect(restored.unitPrice, fixture.unitPrice);
      expect(restored.quantity, fixture.quantity);
      expect(restored.note, fixture.note);
      expect(restored.lineTotal, fixture.lineTotal);
    });

    group('edge cases', () {
      test('note optional — null survives the round-trip', () {
        final noNote = OrderItem(
          id: 'oi-2',
          orderId: 'ord-1',
          productId: 'prod-2',
          productName: 'Es Teh',
          unitPrice: 8000,
          quantity: 1,
        );
        final restored = OrderItem.fromMap(noNote.toMap());
        expect(restored.note, isNull);
      });

      test('zero-quantity line totals to zero', () {
        final zero = OrderItem(
          id: 'oi-3',
          orderId: 'ord-1',
          productId: 'prod-3',
          productName: 'Gratis',
          unitPrice: 5000,
          quantity: 0,
        );
        expect(zero.lineTotal, 0);
      });

      test('map uses snake_case column names', () {
        final m = fixture.toMap();
        expect(m.keys, containsAll(<String>[
          'order_id', 'product_id', 'product_name', 'unit_price',
        ]));
        expect(m.containsKey('orderId'), isFalse);
      });
    });
  });
}
