import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/modifier_group.dart';

void main() {
  group('ModifierGroup', () {
    test('round-trips through toMap / fromMap', () {
      const group = ModifierGroup(
        id: 'mg_topping',
        name: 'Topping',
        selectionType: ModifierSelectionType.multiple,
        required: false,
        maxSelect: 3,
        sortOrder: 2,
        active: false,
      );

      final restored = ModifierGroup.fromMap(group.toMap());

      expect(restored.id, group.id);
      expect(restored.name, group.name);
      expect(restored.selectionType, ModifierSelectionType.multiple);
      expect(restored.required, isFalse);
      expect(restored.maxSelect, 3);
      expect(restored.sortOrder, 2);
      expect(restored.active, isFalse);
    });

    test('booleans survive as SQLite integers, not as Dart bools', () {
      const group = ModifierGroup(id: 'mg_spice', name: 'Level Pedas', required: true);
      final map = group.toMap();

      expect(map['required'], 1);
      expect(map['active'], 1);
    });

    test('maxSelect stays null when unset, unlike a plain int default', () {
      const group = ModifierGroup(id: 'mg_spice', name: 'Level Pedas');
      final map = group.toMap();

      expect(map['max_select'], isNull);
      expect(ModifierGroup.fromMap(map).maxSelect, isNull);
    });

    test('defaults to single-select, optional, and active', () {
      const group = ModifierGroup(id: 'mg_x', name: 'X');

      expect(group.selectionType, ModifierSelectionType.single);
      expect(group.required, isFalse);
      expect(group.active, isTrue);
    });

    test('a row missing the newer columns still reads', () {
      final restored = ModifierGroup.fromMap({'id': 'mg_x', 'name': 'X'});

      expect(restored.selectionType, ModifierSelectionType.single);
      expect(restored.required, isFalse);
      expect(restored.maxSelect, isNull);
      expect(restored.sortOrder, 0);
      expect(restored.active, isTrue);
    });

    test('copyWith changes only what it is given', () {
      const group = ModifierGroup(id: 'mg_x', name: 'X', maxSelect: 2);
      final edited = group.copyWith(name: 'Y', required: true);

      expect(edited.id, 'mg_x');
      expect(edited.name, 'Y');
      expect(edited.required, isTrue);
      expect(edited.maxSelect, 2, reason: 'untouched fields must be preserved');
    });

    test('copyWith(clearMaxSelect: true) is the only way back to unlimited', () {
      const group = ModifierGroup(id: 'mg_x', name: 'X', maxSelect: 2);
      final cleared = group.copyWith(clearMaxSelect: true);

      expect(cleared.maxSelect, isNull);
    });
  });
}
