import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/data/models/modifier_option.dart';

void main() {
  group('ModifierOption', () {
    test('round-trips through toMap / fromMap', () {
      const option = ModifierOption(
        id: 'mg_topping_o1',
        groupId: 'mg_topping',
        name: 'Boba',
        priceDelta: 3000,
        sortOrder: 1,
        active: false,
      );

      final restored = ModifierOption.fromMap(option.toMap());

      expect(restored.id, option.id);
      expect(restored.groupId, option.groupId);
      expect(restored.name, option.name);
      expect(restored.priceDelta, 3000);
      expect(restored.sortOrder, 1);
      expect(restored.active, isFalse);
    });

    test('booleans survive as SQLite integers, not as Dart bools', () {
      const option = ModifierOption(id: 'o1', groupId: 'g1', name: 'Boba');
      expect(option.toMap()['active'], 1);
    });

    test('defaults to a free, active option', () {
      const option = ModifierOption(id: 'o1', groupId: 'g1', name: 'Boba');
      expect(option.priceDelta, 0);
      expect(option.active, isTrue);
    });

    test('a row missing the newer columns still reads', () {
      final restored = ModifierOption.fromMap({
        'id': 'o1',
        'group_id': 'g1',
        'name': 'Boba',
      });
      expect(restored.priceDelta, 0);
      expect(restored.sortOrder, 0);
      expect(restored.active, isTrue);
    });

    test('copyWith changes only what it is given', () {
      const option = ModifierOption(
        id: 'o1',
        groupId: 'g1',
        name: 'Boba',
        priceDelta: 3000,
      );
      final edited = option.copyWith(priceDelta: 5000);

      expect(edited.id, 'o1');
      expect(edited.name, 'Boba', reason: 'untouched fields must be preserved');
      expect(edited.priceDelta, 5000);
    });
  });
}
