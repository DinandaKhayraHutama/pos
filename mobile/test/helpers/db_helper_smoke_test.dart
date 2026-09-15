import 'package:flutter_test/flutter_test.dart';

import 'db_helper.dart';

void main() {
  setUpAll(() async {
    await initFfi();
  });

  group('openInMemoryAppDb', () {
    test('round-trips a product row through the v4 schema', () async {
      final db = await openInMemoryAppDb(seed: false);
      addTearDown(db.close);

      // FKs are ON (PRAGMA foreign_keys = ON in _onConfigure), so insert a
      // category before the product references it.
      await db.insert('categories', {
        'id': 'cat_test',
        'name': 'Test Category',
        'icon_key': 'set_meal',
        'sort_order': 0,
        'is_popular': 0,
      });

      const productId = 'p_smoke';
      await db.insert('products', {
        'id': productId,
        'name': 'Smoke Product',
        'category_id': 'cat_test',
        'price': 12000,
        'description': 'round-trip check',
        'icon_key': 'restaurant',
        'available': 1,
        'is_popular': 0,
        'sort_order': 0,
      });

      final rows = await db.query('products', where: 'id = ?', whereArgs: [productId]);
      expect(rows, hasLength(1));

      final row = rows.first;
      expect(row['id'], productId);
      expect(row['name'], 'Smoke Product');
      expect(row['category_id'], 'cat_test');
      expect(row['price'], 12000);
      expect(row['description'], 'round-trip check');
      expect(row['icon_key'], 'restaurant');
      expect(row['available'], 1);
      expect(row['is_popular'], 0);
      expect(row['sort_order'], 0);
      // Columns added by v2/v4 must exist and default correctly.
      expect(row['image_url'], isNull);
      expect(row['emoji'], '🍽️'); // NOT NULL DEFAULT '🍽️'
    });

    test('seeded DB has categories, products, and tables', () async {
      final db = await openInMemoryAppDb(seed: true);
      addTearDown(db.close);

      final categories = await db.query('categories');
      final products = await db.query('products');
      final tables = await db.query('tables');

      expect(categories, hasLength(greaterThan(0)));
      expect(products, hasLength(greaterThan(0)));
      expect(tables, hasLength(greaterThan(0)));

      // v4 backfill: every seeded category has an icon_key.
      for (final c in categories) {
        expect(c['icon_key'], isNotNull, reason: 'v4 should have backfilled icon_key');
      }

      // Every product defaults to a non-null icon_key.
      for (final p in products) {
        expect(p['icon_key'], isNotNull);
      }
    });

    test('in-memory DB is isolated per open', () async {
      // Open one DB, write a row, close it.
      final first = await openInMemoryAppDb(seed: false);
      addTearDown(first.close);
      await first.insert('categories', {
        'id': 'cat_iso',
        'name': 'Iso',
        'sort_order': 0,
        'is_popular': 0,
      });
      await first.close();

      // Open a second in-memory DB — it should NOT see the first's data.
      final second = await openInMemoryAppDb(seed: false);
      addTearDown(second.close);
      final rows = await second.query('categories');
      expect(rows, isEmpty, reason: 'in-memory DBs must not share state');
    });
  });
}
