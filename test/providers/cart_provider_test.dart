import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/modifier_group.dart';
import 'package:nti_pos/data/models/modifier_option.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/models/product_variant.dart';
import 'package:nti_pos/providers/cart_provider.dart';

const _product = Product(
  id: 'p_kopi_susu',
  name: 'Kopi Susu',
  categoryId: 'cat_drinks',
  price: 18000,
);

const _large = ProductVariant(id: 'v_large', productId: 'p_kopi_susu', name: 'Large', priceDelta: 5000);

const _toppingGroup = ModifierGroup(
  id: 'mg_topping',
  name: 'Topping',
);
const _boba = ModifierOption(id: 'o_boba', groupId: 'mg_topping', name: 'Boba', priceDelta: 3000);
const _cheeseFoam = ModifierOption(
  id: 'o_cheese',
  groupId: 'mg_topping',
  name: 'Cheese Foam',
  priceDelta: 5000,
);

SelectedModifier _selected(ModifierOption option) =>
    (group: _toppingGroup, option: option);

void main() {
  group('CartLine — pricing', () {
    test('unitPrice is just the base price with no variant or modifier', () {
      const line = CartLine(product: _product, quantity: 1);
      expect(line.unitPrice, 18000);
    });

    test('unitPrice adds the variant delta', () {
      const line = CartLine(product: _product, variant: _large, quantity: 1);
      expect(line.unitPrice, 23000);
    });

    test('unitPrice sums every selected modifier delta on top of the variant',
        () {
      final line = CartLine(
        product: _product,
        variant: _large,
        modifiers: [_selected(_boba), _selected(_cheeseFoam)],
        quantity: 1,
      );
      // 18000 (base) + 5000 (Large) + 3000 (Boba) + 5000 (Cheese Foam)
      expect(line.unitPrice, 31000);
    });

    test('lineTotal multiplies the fully-loaded unitPrice by quantity', () {
      final line = CartLine(
        product: _product,
        modifiers: [_selected(_boba)],
        quantity: 3,
      );
      expect(line.lineTotal, (18000 + 3000) * 3);
    });
  });

  group('CartLine — key (merge identity)', () {
    test('two lines with the same product and no variant/modifiers share a key',
        () {
      const a = CartLine(product: _product, quantity: 1);
      const b = CartLine(product: _product, quantity: 1);
      expect(a.key, b.key);
    });

    test('a variant changes the key', () {
      const plain = CartLine(product: _product, quantity: 1);
      const large = CartLine(product: _product, variant: _large, quantity: 1);
      expect(plain.key, isNot(large.key));
    });

    test('a modifier selection changes the key', () {
      const plain = CartLine(product: _product, quantity: 1);
      final withBoba = CartLine(
        product: _product,
        modifiers: [_selected(_boba)],
        quantity: 1,
      );
      expect(plain.key, isNot(withBoba.key));
    });

    test('two DIFFERENT modifier selections on the same product are two keys',
        () {
      final withBoba = CartLine(
        product: _product,
        modifiers: [_selected(_boba)],
        quantity: 1,
      );
      final withCheese = CartLine(
        product: _product,
        modifiers: [_selected(_cheeseFoam)],
        quantity: 1,
      );
      expect(
        withBoba.key,
        isNot(withCheese.key),
        reason: 'Extra Spicy and Mild nasi goreng are two lines, not one — '
            'the same has to hold for two different modifier picks',
      );
    });

    test('the SAME set of modifiers picked in either order is one key', () {
      final bobaFirst = CartLine(
        product: _product,
        modifiers: [_selected(_boba), _selected(_cheeseFoam)],
        quantity: 1,
      );
      final cheeseFirst = CartLine(
        product: _product,
        modifiers: [_selected(_cheeseFoam), _selected(_boba)],
        quantity: 1,
      );
      expect(bobaFirst.key, cheeseFirst.key,
          reason: 'the key sorts option ids, so selection order must not '
              'matter for merging');
    });

    test('variant AND modifiers both have to match for two lines to share a key',
        () {
      final largeWithBoba = CartLine(
        product: _product,
        variant: _large,
        modifiers: [_selected(_boba)],
        quantity: 1,
      );
      final regularWithBoba = CartLine(
        product: _product,
        modifiers: [_selected(_boba)],
        quantity: 1,
      );
      expect(largeWithBoba.key, isNot(regularWithBoba.key));
    });
  });

  group('CartNotifier.add — merge behaviour', () {
    test('adding the same product+modifiers twice merges into one line', () {
      final notifier = CartNotifier();
      notifier.add(_product, modifiers: [_selected(_boba)]);
      notifier.add(_product, modifiers: [_selected(_boba)]);

      expect(notifier.state.lines, hasLength(1));
      expect(notifier.state.lines.single.quantity, 2);
    });

    test('adding the same product with DIFFERENT modifiers creates two lines',
        () {
      final notifier = CartNotifier();
      notifier.add(_product, modifiers: [_selected(_boba)]);
      notifier.add(_product, modifiers: [_selected(_cheeseFoam)]);

      expect(notifier.state.lines, hasLength(2));
      expect(notifier.state.lines.every((l) => l.quantity == 1), isTrue);
    });
  });

  group('CartNotifier.updateLineSelections', () {
    test('changes the modifiers on a line while keeping its quantity', () {
      final notifier = CartNotifier();
      notifier.add(_product, qty: 2, modifiers: [_selected(_boba)]);
      final oldKey = notifier.state.lines.single.key;

      notifier.updateLineSelections(oldKey, modifiers: [_selected(_cheeseFoam)]);

      expect(notifier.state.lines, hasLength(1));
      final edited = notifier.state.lines.single;
      expect(edited.quantity, 2, reason: 'editing selections must not reset qty');
      expect(edited.modifiers.single.option.id, 'o_cheese');
    });

    test('editing a line to match an already-open line merges the two',
        () {
      final notifier = CartNotifier();
      notifier.add(_product, qty: 1, modifiers: [_selected(_boba)]);
      notifier.add(_product, qty: 1, modifiers: [_selected(_cheeseFoam)]);
      final cheeseKey = notifier.state.lines
          .firstWhere((l) => l.modifiers.single.option.id == 'o_cheese')
          .key;

      // Edit the Cheese Foam line to become Boba too — it should fold into
      // the existing Boba line rather than sit as a silent duplicate.
      notifier.updateLineSelections(cheeseKey, modifiers: [_selected(_boba)]);

      expect(notifier.state.lines, hasLength(1));
      expect(notifier.state.lines.single.quantity, 2);
    });

    test('an unknown key is a no-op', () {
      final notifier = CartNotifier();
      notifier.add(_product);
      final before = notifier.state.lines;

      notifier.updateLineSelections('not-a-real-key', modifiers: const []);

      expect(notifier.state.lines, same(before));
    });
  });

  group('CartState — order type', () {
    test('setType away from dine-in clears the table but keeps modifiers-bearing lines',
        () {
      final notifier = CartNotifier();
      notifier.add(_product, modifiers: [_selected(_boba)]);

      notifier.setType(OrderType.takeaway);

      expect(notifier.state.type, OrderType.takeaway);
      expect(notifier.state.table, isNull);
      expect(notifier.state.lines, hasLength(1),
          reason: 'switching order type must not touch existing cart lines');
    });
  });
}
