import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/table.dart';

void main() {
  group('RestaurantTable', () {
    final fixture = RestaurantTable(
      id: 'tbl-1',
      name: 'T-01',
      capacity: 4,
      status: TableStatus.occupied,
      floor: 'floor_2',
      sortOrder: 5,
    );

    test('round-trip toMap() -> fromMap() preserves every field', () {
      final restored = RestaurantTable.fromMap(fixture.toMap());
      expect(restored.id, fixture.id);
      expect(restored.name, fixture.name);
      expect(restored.capacity, fixture.capacity);
      expect(restored.status, fixture.status);
      expect(restored.floor, fixture.floor);
      expect(restored.sortOrder, fixture.sortOrder);
      expect(restored.active, fixture.active);
    });

    test('a deactivated table round-trips as inactive, not the default', () {
      final inactive = fixture.copyWith(active: false);
      final restored = RestaurantTable.fromMap(inactive.toMap());
      expect(restored.active, isFalse);
    });

    group('copyWith', () {
      test('updates only the passed fields, preserves the rest', () {
        final updated = fixture.copyWith(
          status: TableStatus.available,
          capacity: 6,
        );
        expect(updated.status, TableStatus.available);
        expect(updated.capacity, 6);
        // untouched
        expect(updated.id, fixture.id);
        expect(updated.name, fixture.name);
        expect(updated.floor, fixture.floor);
        expect(updated.sortOrder, fixture.sortOrder);
      });
    });

    group('edge cases', () {
      test('status wire round-trips for every TableStatus value', () {
        for (final s in TableStatus.values) {
          expect(TableStatusX.fromWire(s.wire), s);
        }
      });

      test('unknown status wire falls back to available', () {
        expect(TableStatusX.fromWire('nope'), TableStatus.available);
      });

      test('missing keys fall back to defaults', () {
        final m = <String, dynamic>{
          'id': 'tbl-2',
          'name': 'T-02',
        };
        final t = RestaurantTable.fromMap(m);
        expect(t.capacity, 2);
        expect(t.status, TableStatus.available);
        expect(t.floor, 'floor_1');
        expect(t.sortOrder, 0);
        expect(t.active, isTrue, reason: 'a pre-v21 row has no active column');
      });
    });
  });
}
