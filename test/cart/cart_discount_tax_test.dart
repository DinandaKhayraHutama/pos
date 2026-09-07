import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/models/product_variant.dart';
import 'package:nti_pos/data/models/promo.dart';
import 'package:nti_pos/providers/cart_provider.dart';

Product _p(String id, int price, {double? pb1Rate}) =>
    Product(id: id, name: id, categoryId: 'c', price: price, pb1Rate: pb1Rate);

ProductVariant _v(String id, String name, int delta) =>
    ProductVariant(id: id, productId: 'x', name: name, priceDelta: delta);

void main() {
  group('variants', () {
    test('two sizes of one product are two lines, not one', () {
      final cart = CartNotifier();
      final coffee = _p('kopi', 18000);
      cart.add(coffee, variant: _v('v1', 'Regular', 0));
      cart.add(coffee, variant: _v('v2', 'Large', 5000));

      expect(cart.state.lines, hasLength(2));
      // 18.000 + 23.000. Merging them would have charged 36.000.
      expect(cart.state.subtotal, 41000);
      expect(cart.state.itemCount, 2);
    });

    test('the same size added twice stacks on one line', () {
      final cart = CartNotifier();
      final coffee = _p('kopi', 18000);
      cart.add(coffee, variant: _v('v2', 'Large', 5000));
      cart.add(coffee, variant: _v('v2', 'Large', 5000));

      expect(cart.state.lines, hasLength(1));
      expect(cart.state.lines.single.quantity, 2);
      expect(cart.state.subtotal, 46000);
    });

    test('a negative delta is honoured', () {
      final cart = CartNotifier();
      cart.add(_p('teh', 8000), variant: _v('v0', 'Small', -2000));
      expect(cart.state.subtotal, 6000);
    });

    test('stepping one size leaves the other alone', () {
      final cart = CartNotifier();
      final coffee = _p('kopi', 18000);
      final large = _v('v2', 'Large', 5000);
      cart.add(coffee, variant: _v('v1', 'Regular', 0));
      cart.add(coffee, variant: large, qty: 3);

      cart.decrement('kopi#v2');

      expect(cart.state.lines, hasLength(2));
      expect(
        cart.state.lines.firstWhere((l) => l.variant?.id == 'v1').quantity,
        1,
      );
      expect(
        cart.state.lines.firstWhere((l) => l.variant?.id == 'v2').quantity,
        2,
      );
    });

    test('displayName carries the variant, plain products do not', () {
      final cart = CartNotifier();
      cart.add(_p('kopi', 18000), variant: _v('v2', 'Large', 5000));
      cart.add(_p('nasi', 25000));
      expect(cart.state.lines[0].displayName, 'kopi (Large)');
      expect(cart.state.lines[1].displayName, 'nasi');
    });
  });

  group('discount source', () {
    test('a promo applies with no approver attached', () {
      final cart = CartNotifier();
      cart.add(_p('a', 50000));
      cart.applyPromo(
        const Promo(
          id: 'x',
          name: 'Happy Hour 15%',
          kind: PromoKind.percent,
          value: 15,
        ),
      );

      expect(cart.state.discountSource, DiscountSource.promo);
      expect(cart.state.discountAmount, 7500);
      expect(cart.state.discountLabel, 'Happy Hour 15%');
      expect(cart.state.discountAuthorizedBy, isNull);
    });

    test('a manual discount keeps the approver name', () {
      final cart = CartNotifier();
      cart.add(_p('a', 50000));
      cart.applyManualDiscount(authorizedBy: 'Siwi Wiyono Raharjo', percent: 20);

      expect(cart.state.discountSource, DiscountSource.manual);
      expect(cart.state.discountAmount, 10000);
      expect(cart.state.discountAuthorizedBy, 'Siwi Wiyono Raharjo');
    });

    test('switching from promo to manual clears the promo', () {
      // `copyWith` treats null as "leave alone" throughout this codebase, so
      // the switch has to rebuild the state — otherwise a stale promo would
      // still name the discount on the receipt.
      final cart = CartNotifier();
      cart.add(_p('a', 50000));
      cart.applyPromo(
        const Promo(id: 'x', name: 'HH', kind: PromoKind.percent, value: 15),
      );
      cart.applyManualDiscount(authorizedBy: 'Budi', amount: 3000);

      expect(cart.state.promo, isNull);
      expect(cart.state.discountAmount, 3000);
      expect(cart.state.discountLabel, isNull);
    });

    test('switching from manual to promo clears the approver', () {
      final cart = CartNotifier();
      cart.add(_p('a', 50000));
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: 20);
      cart.applyPromo(
        const Promo(id: 'x', name: 'HH', kind: PromoKind.percent, value: 10),
      );

      expect(cart.state.discountAuthorizedBy, isNull);
      expect(cart.state.manualDiscountPercent, 0);
      expect(cart.state.discountAmount, 5000);
    });

    test('clearDiscount removes every trace', () {
      final cart = CartNotifier();
      cart.add(_p('a', 50000));
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: 20);
      cart.clearDiscount();

      expect(cart.state.discountSource, DiscountSource.none);
      expect(cart.state.discountAmount, 0);
      expect(cart.state.discountAuthorizedBy, isNull);
      expect(cart.state.promo, isNull);
    });

    test('a discount larger than the bill clamps to it', () {
      final cart = CartNotifier();
      cart.add(_p('a', 12000));
      cart.applyManualDiscount(authorizedBy: 'Budi', amount: 99999);
      expect(cart.state.discountAmount, 12000);
      expect(cart.state.taxableBase, 0);
    });

    test('the discount survives adding another item, recomputed', () {
      final cart = CartNotifier();
      cart.add(_p('a', 50000));
      cart.applyPromo(
        const Promo(id: 'x', name: 'HH', kind: PromoKind.percent, value: 10),
      );
      expect(cart.state.discountAmount, 5000);

      cart.add(_p('b', 30000));
      // A percentage follows the basket rather than freezing at the amount it
      // happened to be when it was applied.
      expect(cart.state.discountAmount, 8000);
    });
  });

  group('per-product tax', () {
    test('a product with no rate of its own uses the store rate', () {
      final cart = CartNotifier();
      cart.add(_p('a', 100000));
      expect(cart.pb1Of(11), 11000);
    });

    test('a product rate overrides the store rate', () {
      final cart = CartNotifier();
      cart.add(_p('a', 100000, pb1Rate: 5));
      expect(cart.pb1Of(11), 5000);
    });

    test('a zero-rated product is not the same as an unset one', () {
      // This is the whole reason the column is nullable. A literal 0 has to
      // beat the store rate, or a zero-rated staple silently gets taxed.
      final cart = CartNotifier();
      cart.add(_p('a', 100000, pb1Rate: 0));
      expect(cart.pb1Of(11), 0);
    });

    test('mixed rates are summed per line, not averaged', () {
      final cart = CartNotifier();
      cart.add(_p('food', 100000, pb1Rate: 10));
      cart.add(_p('book', 100000, pb1Rate: 0));
      // 10.000 + 0. A single basket rate would have produced 11.000 at the
      // store's 11%, taxing the zero-rated item.
      expect(cart.pb1Of(11), 10000);
    });

    test('the discount is shared across lines before each is taxed', () {
      final cart = CartNotifier();
      cart.add(_p('food', 100000, pb1Rate: 10));
      cart.add(_p('book', 100000, pb1Rate: 0));
      cart.applyManualDiscount(authorizedBy: 'Budi', percent: 20);

      // Discount 40.000, split 20.000 / 20.000 by line share. Taxed base for
      // the food line is 80.000 at 10% = 8.000; the book contributes nothing.
      expect(cart.state.discountAmount, 40000);
      expect(cart.pb1Of(11), 8000);
      expect(
        cart.state.totalFor(pb1Rate: 11, serviceChargeRate: 0),
        160000 + 8000,
      );
    });

    test(
      'a zero-rated product still gets a service-charge share in its base, '
      'but PB1 stays zero — the rate short-circuits before the share matters',
      () {
        final cart = CartNotifier();
        cart.add(_p('food', 100000, pb1Rate: 10));
        cart.add(_p('book', 100000, pb1Rate: 0));
        // No discount here — isolates the service-charge-share interaction.
        // subtotal 200000, serviceChargeFor(10) = 20000, split 10000/10000.
        // food base = 100000 + 10000 = 110000 -> PB1 10% = 11000.
        // book base = 100000 + 10000 = 110000 -> PB1 rate 0 -> contributes 0.
        expect(cart.state.serviceChargeFor(10), 20000);
        expect(
          cart.state.pb1For(pb1Rate: 10, serviceChargeRate: 10),
          11000,
        );
      },
    );
  });
}

extension on CartNotifier {
  int pb1Of(double storePb1Rate) =>
      state.pb1For(pb1Rate: storePb1Rate, serviceChargeRate: 0);
}
