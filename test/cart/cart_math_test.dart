import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/models/table.dart';
import 'package:nti_pos/providers/cart_provider.dart';

Product _product({required String id, required int price}) => Product(
      id: id,
      name: 'P-$id',
      categoryId: 'cat-1',
      price: price,
    );

RestaurantTable _table(String id) => RestaurantTable(
      id: id,
      name: 'T-$id',
      capacity: 4,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mutations', () {
    test('add new line creates one line with given qty', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 2);
      expect(cart.state.lines.length, 1);
      expect(cart.state.lines.first.product.id, 'a');
      expect(cart.state.lines.first.quantity, 2);
      expect(cart.state.itemCount, 2);
      expect(cart.state.isEmpty, isFalse);
    });

    test('add existing line stacks qty on the existing line', () {
      final cart = CartNotifier();
      final p = _product(id: 'a', price: 1000);
      cart.add(p, qty: 1);
      cart.add(p, qty: 3);
      expect(cart.state.lines.length, 1);
      expect(cart.state.lines.first.quantity, 4);
      expect(cart.state.itemCount, 4);
    });

    test('decrement at qty>1 subtracts one', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 3);
      cart.decrement('a');
      expect(cart.state.lines.first.quantity, 2);
      expect(cart.state.itemCount, 2);
    });

    test('decrement at qty 1 removes the line', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 1);
      cart.decrement('a');
      expect(cart.state.lines, isEmpty);
      expect(cart.state.isEmpty, isTrue);
    });

    test('decrement on unknown id is a no-op', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 2);
      cart.decrement('missing');
      expect(cart.state.lines.first.quantity, 2);
    });

    test('setQuantity to 0 removes the line', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 2);
      cart.setQuantity('a', 0);
      expect(cart.state.lines, isEmpty);
    });

    test('setQuantity to negative removes the line', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 2);
      cart.setQuantity('a', -3);
      expect(cart.state.lines, isEmpty);
    });

    test('setQuantity to N sets the quantity', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 1);
      cart.setQuantity('a', 7);
      expect(cart.state.lines.first.quantity, 7);
      expect(cart.state.itemCount, 7);
    });

    test('setQuantity on unknown id is a no-op', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 1);
      cart.setQuantity('missing', 5);
      expect(cart.state.lines.first.quantity, 1);
    });

    test('setNote attaches a per-line note', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 1);
      cart.setNote('a', 'extra hot');
      expect(cart.state.lines.first.note, 'extra hot');
    });

    test('setNote on unknown id is a no-op', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 1);
      cart.setNote('missing', 'ignored');
      expect(cart.state.lines.first.note, isNull);
    });

    test('removeLine drops only the matching product', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 1);
      cart.add(_product(id: 'b', price: 2000), qty: 2);
      cart.removeLine('a');
      expect(cart.state.lines.length, 1);
      expect(cart.state.lines.first.product.id, 'b');
    });

    test('clear resets to an empty cart', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 1000), qty: 4);
      cart.setType(OrderType.takeaway);
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: 15);
      cart.clear();
      expect(cart.state.lines, isEmpty);
      expect(cart.state.isEmpty, isTrue);
      expect(cart.state.type, OrderType.dineIn);
      expect(cart.state.table, isNull);
      expect(cart.state.customerName, isNull);
      expect(cart.state.note, isNull);
      expect(cart.state.manualDiscountPercent, 0);
    });
  });

  group('order type and table', () {
    test('setType(takeaway) clears any table previously set', () {
      final cart = CartNotifier();
      final t = _table('t1');
      cart.setTable(t);
      expect(cart.state.table, isNotNull);
      cart.setType(OrderType.takeaway);
      expect(cart.state.type, OrderType.takeaway);
      expect(cart.state.table, isNull);
    });

    test('setType(delivery) clears any table previously set', () {
      final cart = CartNotifier();
      cart.setTable(_table('t1'));
      cart.setType(OrderType.delivery);
      expect(cart.state.type, OrderType.delivery);
      expect(cart.state.table, isNull);
    });

    test('setType(dineIn) preserves an already-set table', () {
      final cart = CartNotifier();
      final t = _table('t1');
      cart.setTable(t);
      cart.setType(OrderType.dineIn);
      expect(cart.state.type, OrderType.dineIn);
      expect(cart.state.table, same(t));
    });

    test('setType(dineIn) allows setting a table afterwards', () {
      final cart = CartNotifier();
      cart.setType(OrderType.takeaway); // clears table
      cart.setType(OrderType.dineIn);
      final t = _table('t2');
      cart.setTable(t);
      expect(cart.state.table, same(t));
    });

    test('setTable(t) sets the table on a dine-in cart', () {
      final cart = CartNotifier();
      final t = _table('t1');
      cart.setType(OrderType.dineIn);
      cart.setTable(t);
      expect(cart.state.table, same(t));
    });

    // Note: setTable(null) does NOT clear the table — CartState.copyWith
    // falls back to the existing value via `table ?? this.table`, so a null
    // argument is a no-op. Table clearing is driven exclusively by setType
    // (clearTable: true). This is production behavior; do not regress it.

    test('setTable(twice) replaces the table with the newer one', () {
      final cart = CartNotifier();
      final first = _table('t1');
      final second = _table('t2');
      cart.setTable(first);
      cart.setTable(second);
      expect(cart.state.table, same(second));
    });
  });

  group('discount clamp', () {
    test('negative percent clamps to 0', () {
      final cart = CartNotifier();
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: -5);
      expect(cart.state.manualDiscountPercent, 0);
    });

    test('percent above 100 clamps to 100', () {
      final cart = CartNotifier();
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: 150);
      expect(cart.state.manualDiscountPercent, 100);
    });

    test('percent within range is stored verbatim', () {
      final cart = CartNotifier();
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: 25);
      expect(cart.state.manualDiscountPercent, 25);
    });

    test('zero is stored verbatim', () {
      final cart = CartNotifier()
        ..applyManualDiscount(authorizedBy: 'Budi', percent: 30)
        ..applyManualDiscount(authorizedBy: 'Budi', percent: 0);
      expect(cart.state.manualDiscountPercent, 0);
    });
  });

  group('math', () {
    // Fixture: price 15000 qty 3 (lineTotal 45000), price 8000 qty 2 (lineTotal 16000).
    // subtotal = 61000. discountPercent 10 → discountAmount 6100, taxableBase 54900.
    // pb1For(pb1Rate: 11, serviceChargeRate: 0) = round(54900 * 11 / 100) = 6039.
    // totalFor(pb1Rate: 11, serviceChargeRate: 0) = 54900 + 6039 = 60939.
    // itemCount = 5.
    CartNotifier buildCart() {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 15000), qty: 3);
      cart.add(_product(id: 'b', price: 8000), qty: 2);
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: 10);
      return cart;
    }

    test('subtotal sums line totals', () {
      final cart = buildCart();
      expect(cart.state.subtotal, 45000 + 16000);
      expect(cart.state.subtotal, 61000);
    });

    test('itemCount sums quantities and isEmpty is false', () {
      final cart = buildCart();
      expect(cart.state.itemCount, 5);
      expect(cart.state.isEmpty, isFalse);
    });

    test('discountAmount uses integer division', () {
      final cart = buildCart();
      expect(cart.state.discountAmount, (61000 * 10) ~/ 100);
      expect(cart.state.discountAmount, 6100);
    });

    test('taxableBase subtracts discountAmount', () {
      final cart = buildCart();
      expect(cart.state.taxableBase, 61000 - 6100);
      expect(cart.state.taxableBase, 54900);
    });

    test('pb1For rounds half-up on a percent rate (service charge off)', () {
      final cart = buildCart();
      expect(
        cart.state.pb1For(pb1Rate: 11, serviceChargeRate: 0),
        (54900 * 11 / 100).round(),
      );
      expect(cart.state.pb1For(pb1Rate: 11, serviceChargeRate: 0), 6039);
    });

    test('totalFor adds taxableBase and pb1 (service charge off)', () {
      final cart = buildCart();
      expect(
        cart.state.totalFor(pb1Rate: 11, serviceChargeRate: 0),
        54900 + 6039,
      );
      expect(cart.state.totalFor(pb1Rate: 11, serviceChargeRate: 0), 60939);
    });

    test('rate 0 yields zero pb1 and total == taxableBase', () {
      final cart = buildCart();
      expect(cart.state.pb1For(pb1Rate: 0, serviceChargeRate: 0), 0);
      expect(
        cart.state.totalFor(pb1Rate: 0, serviceChargeRate: 0),
        cart.state.taxableBase,
      );
      expect(cart.state.totalFor(pb1Rate: 0, serviceChargeRate: 0), 54900);
    });

    test('rounding goes up at exactly .5 (e.g. taxableBase 54950 at 1%)', () {
      // Construct a cart whose taxableBase ends in 50 to exercise .round() up.
      // price 54950 qty 1, no discount: subtotal 54950, taxableBase 54950.
      // pb1For at 1% = round(54950 / 100) = round(549.5) = 550.
      final cart = CartNotifier();
      cart.add(_product(id: 'half', price: 54950), qty: 1);
      expect(cart.state.taxableBase, 54950);
      expect(cart.state.pb1For(pb1Rate: 1, serviceChargeRate: 0), 550);
    });
  });

  group('service charge', () {
    // Same fixture as 'math': subtotal 61000, discount 6100, taxableBase 54900.
    CartNotifier buildCart() {
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 15000), qty: 3);
      cart.add(_product(id: 'b', price: 8000), qty: 2);
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: 10);
      return cart;
    }

    test('serviceChargeFor is a single flat calculation on taxableBase', () {
      final cart = buildCart();
      expect(
        cart.state.serviceChargeFor(5),
        (54900 * 5 / 100).round(),
      );
      expect(cart.state.serviceChargeFor(5), 2745);
    });

    test('rate 0 or off yields zero service charge', () {
      final cart = buildCart();
      expect(cart.state.serviceChargeFor(0), 0);
    });

    test('service charge on, PB1 off: total is taxableBase plus service '
        'charge only', () {
      final cart = buildCart();
      final serviceCharge = cart.state.serviceChargeFor(5);
      expect(
        cart.state.pb1For(pb1Rate: 0, serviceChargeRate: 5),
        0,
        reason: 'PB1 rate 0 must stay 0 even though its base now includes '
            'the service charge',
      );
      expect(
        cart.state.totalFor(pb1Rate: 0, serviceChargeRate: 5),
        cart.state.taxableBase + serviceCharge,
      );
    });

    test(
      'core case: PB1 is computed on (taxableBase + serviceCharge), not on '
      'taxableBase alone — the confirmed compounding order',
      () {
        final cart = buildCart();
        // taxableBase 54900, serviceCharge 5% -> 2745. PB1 base is then
        // 54900 + 2745 = 57645, PB1 10% -> round(5764.5) = 5765 (half-up).
        final serviceCharge = cart.state.serviceChargeFor(5);
        expect(serviceCharge, 2745);
        final pb1 = cart.state.pb1For(pb1Rate: 10, serviceChargeRate: 5);
        expect(pb1, 5765);

        // Must be strictly greater than the naive (wrong) computation that
        // ignores the service charge in PB1's base — this is the assertion
        // that actually locks in the compounding order, not just a number.
        final naivePb1 = (cart.state.taxableBase * 10 / 100).round();
        expect(pb1, greaterThan(naivePb1));

        expect(
          cart.state.totalFor(pb1Rate: 10, serviceChargeRate: 5),
          cart.state.taxableBase + serviceCharge + pb1,
        );
        expect(
          cart.state.totalFor(pb1Rate: 10, serviceChargeRate: 5),
          54900 + 2745 + 5765,
        );
      },
    );

    test('rounding boundary: serviceChargeFor rounds half-up at exactly .5',
        () {
      // price 10050 qty 1, no discount: taxableBase 10050.
      // serviceChargeFor(5) = round(10050 * 5 / 100) = round(502.5) = 503.
      final cart = CartNotifier();
      cart.add(_product(id: 'half', price: 10050), qty: 1);
      expect(cart.state.taxableBase, 10050);
      expect(cart.state.serviceChargeFor(5), 503);
    });

    test('multi-line: discount share and service-charge share both apply '
        'to each line before PB1', () {
      // Two lines, no rounding surprises: 40000 and 20000 (subtotal 60000),
      // 10% discount -> discountAmount 6000, taxableBase 54000.
      // serviceChargeFor(10) = 5400.
      // Line a's share of subtotal is 40000/60000 = 2/3:
      //   discountShare = 6000 * 40000 ~/ 60000 = 4000
      //   serviceChargeShare = 5400 * 40000 ~/ 60000 = 3600
      //   base = 40000 - 4000 + 3600 = 39600 -> PB1 10% = 3960
      // Line b's share is 1/3:
      //   discountShare = 6000 * 20000 ~/ 60000 = 2000
      //   serviceChargeShare = 5400 * 20000 ~/ 60000 = 1800
      //   base = 20000 - 2000 + 1800 = 19800 -> PB1 10% = 1980
      // pb1For = 3960 + 1980 = 5940.
      final cart = CartNotifier();
      cart.add(_product(id: 'a', price: 40000), qty: 1);
      cart.add(_product(id: 'b', price: 20000), qty: 1);
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: 10);

      expect(cart.state.taxableBase, 54000);
      expect(cart.state.serviceChargeFor(10), 5400);
      expect(cart.state.pb1For(pb1Rate: 10, serviceChargeRate: 10), 5940);
    });
  });

  group('defaults and degenerate cases', () {
    test('empty cart has correct defaults', () {
      final cart = CartNotifier();
      expect(cart.state.lines, isEmpty);
      expect(cart.state.isEmpty, isTrue);
      expect(cart.state.itemCount, 0);
      expect(cart.state.subtotal, 0);
      expect(cart.state.discountAmount, 0);
      expect(cart.state.taxableBase, 0);
      expect(cart.state.serviceChargeFor(5), 0);
      expect(cart.state.pb1For(pb1Rate: 11, serviceChargeRate: 0), 0);
      expect(cart.state.totalFor(pb1Rate: 11, serviceChargeRate: 0), 0);
      expect(cart.state.manualDiscountPercent, 0);
      expect(cart.state.type, OrderType.dineIn);
      expect(cart.state.table, isNull);
      expect(cart.state.customerName, isNull);
      expect(cart.state.note, isNull);
    });

    test('single-line cart with no discount: pb1 and total derive from subtotal', () {
      final cart = CartNotifier();
      cart.add(_product(id: 'solo', price: 20000), qty: 1);
      expect(cart.state.subtotal, 20000);
      expect(cart.state.discountAmount, 0);
      expect(cart.state.taxableBase, 20000);
      // pb1For at 11% = round(20000 * 11 / 100) = round(2200.0) = 2200.
      expect(cart.state.pb1For(pb1Rate: 11, serviceChargeRate: 0), 2200);
      expect(cart.state.totalFor(pb1Rate: 11, serviceChargeRate: 0), 22200);
    });
  });
}
