import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/models/product.dart';

void main() {
  group('Product', () {
    final fixture = Product(
      id: 'prod-1',
      name: 'Nasi Goreng Spesial',
      categoryId: 'cat-food',
      price: 32000,
      description: 'With fried egg and crackers.',
      imageUrl: 'https://example.com/photo.jpg',
      iconKey: 'restaurant',
      available: true,
      isPopular: true,
      sortOrder: 3,
      emoji: '🍛',
    );

    test('round-trip toMap() -> fromMap() preserves every field', () {
      final restored = Product.fromMap(fixture.toMap());
      expect(restored.id, fixture.id);
      expect(restored.name, fixture.name);
      expect(restored.categoryId, fixture.categoryId);
      expect(restored.price, fixture.price);
      expect(restored.description, fixture.description);
      expect(restored.emoji, fixture.emoji);
      expect(restored.imageUrl, fixture.imageUrl);
      expect(restored.iconKey, fixture.iconKey);
      expect(restored.available, fixture.available);
      expect(restored.isPopular, fixture.isPopular);
      expect(restored.sortOrder, fixture.sortOrder);
    });

    group('copyWith', () {
      test('updates only the passed fields, preserves the rest', () {
        final updated = fixture.copyWith(
          price: 35000,
          available: false,
        );
        expect(updated.price, 35000);
        expect(updated.available, isFalse);
        // untouched
        expect(updated.id, fixture.id);
        expect(updated.name, fixture.name);
        expect(updated.categoryId, fixture.categoryId);
        expect(updated.description, fixture.description);
        expect(updated.imageUrl, fixture.imageUrl);
        expect(updated.iconKey, fixture.iconKey);
        expect(updated.isPopular, fixture.isPopular);
        expect(updated.sortOrder, fixture.sortOrder);
        expect(updated.emoji, fixture.emoji);
      });

      test('does not mutate the source', () {
        final before = fixture.price;
        fixture.copyWith(price: 999);
        expect(fixture.price, before);
      });
    });

    group('edge cases', () {
      test('null imageUrl is omitted from the map and restored as null', () {
        final noImage = Product(
          id: 'prod-2',
          name: 'Plain Item',
          categoryId: 'cat-x',
          price: 10000,
        );
        final m = noImage.toMap();
        expect(m.containsKey('image_url'), isFalse);
        final restored = Product.fromMap(m);
        expect(restored.imageUrl, isNull);
        expect(restored.description, isNull);
      });

      test('available and isPopular serialise to int 0/1', () {
        final unavailable = Product(
          id: 'prod-3',
          name: 'Hidden',
          categoryId: 'cat-x',
          price: 1000,
          available: false,
          isPopular: false,
        );
        final m = unavailable.toMap();
        expect(m['available'], 0);
        expect(m['is_popular'], 0);
        expect(Product.fromMap(m).available, isFalse);
      });

      test('missing optional keys fall back to defaults', () {
        final m = <String, dynamic>{
          'id': 'prod-4',
          'name': 'Minimal',
          'category_id': 'cat-x',
          'price': 5000,
        };
        final p = Product.fromMap(m);
        expect(p.iconKey, 'restaurant');
        expect(p.available, isTrue);
        expect(p.isPopular, isFalse);
        expect(p.sortOrder, 0);
      });
    });
  });
}
