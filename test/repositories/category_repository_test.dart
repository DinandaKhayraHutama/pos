import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/category.dart';
import 'package:nti_pos/data/repositories/category_repository.dart';

import '../helpers/db_helper.dart';

const _seededCategory = Category(
  id: 'cat_food',
  name: 'Food',
  emoji: '🍱',
  iconKey: 'set_meal',
  sortOrder: 0,
);

void main() {
  setUpAll(() async {
    await initFfi();
  });

  group('CategoryRepository', () {
    late Database db;

    setUp(() async {
      db = await openInMemoryAppDb(seed: false);
      await AppDatabase.instance.useTestDb(db);
    });
    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('upsert then all() round-trips the category', () async {
      await CategoryRepository.instance.upsert(_seededCategory);

      final all = await CategoryRepository.instance.all();
      expect(all, hasLength(1));
      expect(all.first.id, _seededCategory.id);
      expect(all.first.name, _seededCategory.name);
      expect(all.first.iconKey, _seededCategory.iconKey);
      expect(all.first.sortOrder, _seededCategory.sortOrder);
    });

    test('upsert with same id replaces row (name update persists)', () async {
      await CategoryRepository.instance.upsert(_seededCategory);
      final renamed = _seededCategory.copyWith(name: 'Makanan');
      await CategoryRepository.instance.upsert(renamed);

      final all = await CategoryRepository.instance.all();
      expect(all, hasLength(1));
      expect(all.first.id, _seededCategory.id);
      expect(all.first.name, 'Makanan');
    });

    test('byId returns the category', () async {
      await CategoryRepository.instance.upsert(_seededCategory);
      final fetched = await CategoryRepository.instance.byId(_seededCategory.id);
      expect(fetched.id, _seededCategory.id);
      expect(fetched.name, _seededCategory.name);
    });

    test('delete removes the category from all()', () async {
      await CategoryRepository.instance.upsert(_seededCategory);
      expect(await CategoryRepository.instance.all(), hasLength(1));

      await CategoryRepository.instance.delete(_seededCategory.id);
      expect(await CategoryRepository.instance.all(), isEmpty);
    });

    test(
        'delete cascades when products reference the category '
        '(FK ON DELETE CASCADE)', () async {
      await CategoryRepository.instance.upsert(_seededCategory);

      // Insert a product that references the category. Schema has
      // `FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE`.
      await db.insert('products', {
        'id': 'p_orphan',
        'name': 'Orphan Product',
        'category_id': _seededCategory.id,
        'price': 15000,
        'icon_key': 'restaurant',
        'available': 1,
        'is_popular': 0,
        'sort_order': 0,
      });
      expect(await db.query('products'), hasLength(1));

      await CategoryRepository.instance.delete(_seededCategory.id);

      // Category gone.
      expect(await CategoryRepository.instance.all(), isEmpty);
      // Cascade reached the product row.
      expect(await db.query('products'), isEmpty);
    });
  });
}
