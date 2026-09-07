import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/models/category.dart';

void main() {
  group('Category', () {
    final fixture = Category(
      id: 'cat-1',
      name: 'Makanan',
      emoji: '🍛',
      iconKey: 'restaurant',
      sortOrder: 2,
      isPopular: true,
    );

    test('round-trip toMap() -> fromMap() preserves every field', () {
      final restored = Category.fromMap(fixture.toMap());
      expect(restored.id, fixture.id);
      expect(restored.name, fixture.name);
      expect(restored.emoji, fixture.emoji);
      expect(restored.iconKey, fixture.iconKey);
      expect(restored.sortOrder, fixture.sortOrder);
      expect(restored.isPopular, fixture.isPopular);
    });

    group('copyWith', () {
      test('updates only the passed fields, preserves the rest', () {
        final updated = fixture.copyWith(
          name: 'Minuman',
          iconKey: 'local_cafe',
          isPopular: false,
        );
        expect(updated.name, 'Minuman');
        expect(updated.iconKey, 'local_cafe');
        expect(updated.isPopular, isFalse);
        // untouched
        expect(updated.id, fixture.id);
        expect(updated.emoji, fixture.emoji);
        expect(updated.sortOrder, fixture.sortOrder);
      });

      test('null iconKey is preserved through copyWith', () {
        final withNull = fixture.copyWith(iconKey: null);
        // null is treated as "use this.id fallback" by copyWith's ?? idiom,
        // so passing null cannot clear the field — assert current behaviour.
        expect(withNull.iconKey, fixture.iconKey);
      });
    });

    group('edge cases', () {
      test('isPopular serialises as int 0/1', () {
        final m = fixture.toMap();
        expect(m['is_popular'], 1);
        final notPopular = fixture.copyWith(isPopular: false);
        expect(notPopular.toMap()['is_popular'], 0);
      });

      test('iconKey is nullable end-to-end', () {
        final noIcon = Category(
          id: 'cat-2',
          name: 'Snack',
          emoji: '🍟',
        );
        final m = noIcon.toMap();
        expect(m['icon_key'], isNull);
        expect(Category.fromMap(m).iconKey, isNull);
      });
    });
  });
}
