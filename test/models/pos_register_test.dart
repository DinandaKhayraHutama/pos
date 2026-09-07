import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/data/models/pos_register.dart';

void main() {
  group('PosRegister', () {
    test('round-trips through toMap / fromMap', () {
      const register = PosRegister(
        id: 'pos_1',
        outletId: 'outlet-1',
        name: 'Kasir 1',
        tableService: false,
        active: false,
        sortOrder: 3,
      );

      final restored = PosRegister.fromMap(register.toMap());

      expect(restored.id, register.id);
      expect(restored.outletId, register.outletId);
      expect(restored.name, register.name);
      expect(restored.tableService, isFalse);
      expect(restored.active, isFalse);
      expect(restored.sortOrder, 3);
    });

    test('booleans survive as SQLite integers, not as Dart bools', () {
      const register = PosRegister(
        id: 'pos_1',
        outletId: 'outlet-1',
        name: 'Kasir 1',
      );
      final map = register.toMap();

      // sqflite has no boolean column type, so a `true` written straight
      // through would be stored as a string on some paths and read back as a
      // truthy non-bool on others.
      expect(map['table_service'], 1);
      expect(map['active'], 1);
    });

    test('defaults to a till that seats guests and is in service', () {
      const register = PosRegister(
        id: 'pos_1',
        outletId: 'outlet-1',
        name: 'Kasir 1',
      );
      // A till created without a thought has to behave the way the app always
      // has, or adding one silently takes the floor plan away.
      expect(register.tableService, isTrue);
      expect(register.active, isTrue);
    });

    test('a row missing the newer columns still reads', () {
      // What a hand-written INSERT or a partially-migrated row looks like.
      final restored = PosRegister.fromMap({
        'id': 'pos_1',
        'outlet_id': 'outlet-1',
        'name': 'Kasir 1',
      });
      expect(restored.tableService, isTrue);
      expect(restored.active, isTrue);
      expect(restored.sortOrder, 0);
    });

    test('copyWith changes only what it is given', () {
      const register = PosRegister(
        id: 'pos_1',
        outletId: 'outlet-1',
        name: 'Kasir 1',
      );
      final retired = register.copyWith(tableService: false, active: false);

      expect(retired.id, 'pos_1');
      expect(retired.outletId, 'outlet-1');
      expect(retired.name, 'Kasir 1');
      expect(retired.tableService, isFalse);
      expect(retired.active, isFalse);
    });
  });
}
