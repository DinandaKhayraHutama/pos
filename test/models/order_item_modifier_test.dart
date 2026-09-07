import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/data/models/order_item_modifier.dart';

void main() {
  group('OrderItemModifier', () {
    test('round-trips through toMap / fromMap', () {
      const modifier = OrderItemModifier(
        id: 'oim_1',
        orderItemId: 'oi_1',
        groupName: 'Topping',
        optionName: 'Boba',
        priceDelta: 3000,
        sortOrder: 1,
      );

      final restored = OrderItemModifier.fromMap(modifier.toMap());

      expect(restored.id, modifier.id);
      expect(restored.orderItemId, modifier.orderItemId);
      expect(restored.groupName, modifier.groupName);
      expect(restored.optionName, modifier.optionName);
      expect(restored.priceDelta, 3000);
      expect(restored.sortOrder, 1);
    });

    test(
      'carries names, not group/option ids — a snapshot, never joined back',
      () {
        // The whole point of this model: no groupId/optionId field exists at
        // all, so there is nothing to accidentally join `modifier_groups`/
        // `modifier_options` back through after they have been renamed or
        // deleted. toMap()'s keys are the only contract that matters here.
        const modifier = OrderItemModifier(
          id: 'oim_1',
          orderItemId: 'oi_1',
          groupName: 'Topping',
          optionName: 'Boba',
        );
        final map = modifier.toMap();

        expect(map.containsKey('group_id'), isFalse);
        expect(map.containsKey('option_id'), isFalse);
        expect(map['group_name'], 'Topping');
        expect(map['option_name'], 'Boba');
      },
    );

    test('a row missing the newer columns still reads', () {
      final restored = OrderItemModifier.fromMap({
        'id': 'oim_1',
        'order_item_id': 'oi_1',
        'group_name': 'Topping',
        'option_name': 'Boba',
      });
      expect(restored.priceDelta, 0);
      expect(restored.sortOrder, 0);
    });
  });
}
