import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/modifier_group.dart';
import 'package:nti_pos/data/models/modifier_option.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/models/product_modifier_config.dart';
import 'package:nti_pos/features/pos/modifier_picker_sheet.dart';
import 'package:nti_pos/providers/cart_provider.dart';

void main() {
  const single = ModifierGroup(id: 'g', name: 'Spice', required: true);
  const a = ModifierOption(
    id: 'a',
    groupId: 'g',
    name: 'Mild',
    priceDelta: 1000,
  );
  const b = ModifierOption(
    id: 'b',
    groupId: 'g',
    name: 'Hot',
    priceDelta: 2000,
  );
  const inactive = ModifierOption(
    id: 'c',
    groupId: 'g',
    name: 'Old',
    active: false,
  );
  final offers = [
    (group: single, options: [a, b, inactive]),
  ];

  test(
    'default resolves only allowed active options and respects single cap',
    () {
      expect(
        resolveModifierSelection(
          single,
          [a, b, inactive],
          {'b', 'c', 'removed'},
        ),
        [b],
      );
      expect(resolveModifierSelection(single, [a, b], {'a', 'b'}), [a]);
      expect(
        resolveModifierSelection(single.copyWith(active: false), [a], {'a'}),
        isEmpty,
      );
    },
  );
  test('multiple selection is capped deterministically after group edits', () {
    final group = single.copyWith(
      selectionType: ModifierSelectionType.multiple,
      maxSelect: 2,
    );
    expect(resolveModifierSelection(group, [a, b, a], {'a', 'b'}), [a, b]);
    expect(
      resolveModifierSelection(
        group.copyWith(maxSelect: 1),
        [a, b],
        {'a', 'b'},
      ),
      [a],
    );
  });
  test('Add asks only for missing required selections', () {
    expect(
      needsModifierSelection(offers, selectionsForOffers(offers, {'a'})),
      false,
    );
    expect(needsModifierSelection(offers, []), true);
    expect(
      needsModifierSelection([
        (group: single, options: [inactive]),
      ], []),
      false,
    );
    expect(
      needsModifierSelection([
        (group: single.copyWith(required: false), options: [a]),
      ], []),
      false,
    );
  });
  test(
    'default and manual same selection merge; edits preserve quantity and price',
    () {
      const product = Product(
        id: 'p',
        name: 'Dish',
        categoryId: 'food',
        price: 10000,
      );
      final cart = CartNotifier();
      addTearDown(cart.dispose);
      cart.add(product, modifiers: selectionsForOffers(offers, {'a'}));
      cart.add(product, modifiers: [(group: single, option: a)]);
      expect(cart.state.lines.single.quantity, 2);
      expect(cart.state.subtotal, 22000);
      cart.updateLineSelections(
        cart.state.lines.single.key,
        modifiers: selectionsForOffers(offers, {'b'}),
      );
      expect(cart.state.lines.single.quantity, 2);
      expect(cart.state.subtotal, 24000);
    },
  );
  test('configuration owns immutable copies', () {
    final ids = {'a'};
    final config = ProductModifierConfig(optionIds: ids);
    ids.clear();
    expect(config.optionIds, {'a'});
    expect(() => config.optionIds.clear(), throwsUnsupportedError);
  });
}
