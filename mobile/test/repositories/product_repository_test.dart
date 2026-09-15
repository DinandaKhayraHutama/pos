import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/repositories/product_repository.dart';

import '../helpers/db_helper.dart';

/// The tests run against one branch. Multi-outlet scoping has its own
/// coverage; these are about the catalogue and the ledger, and threading a
/// second outlet through every case would only obscure that.
const _outlet = 'outlet-1';

/// Inserts a category row so products can satisfy the
/// `FOREIGN KEY (category_id) REFERENCES categories(id)` constraint
/// (PRAGMA foreign_keys = ON).
Future<void> _seedCategory(Database db, {String id = 'cat_food'}) async {
  await db.insert('categories', {
    'id': id,
    'name': 'Food',
    'icon_key': 'set_meal',
    'sort_order': 0,
    'is_popular': 0,
  });
}

const _seededProduct = Product(
  id: 'p_nasi_goreng',
  name: 'Nasi Goreng',
  categoryId: 'cat_food',
  price: 25000,
  iconKey: 'rice_bowl',
  sortOrder: 0,
);

void main() {
  setUpAll(() async {
    await initFfi();
  });

  group('ProductRepository', () {
    late Database db;

    setUp(() async {
      db = await openInMemoryAppDb(seed: false);
      await AppDatabase.instance.useTestDb(db);
      await _seedCategory(db);
    });
    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('upsert then all() contains the product', () async {
      await ProductRepository.instance.upsert(_seededProduct);

      final all = await ProductRepository.instance.all(outletId: _outlet);
      expect(all, hasLength(1));
      expect(all.first.id, _seededProduct.id);
      expect(all.first.name, _seededProduct.name);
      expect(all.first.price, _seededProduct.price);
      expect(all.first.categoryId, _seededProduct.categoryId);
    });

    test('upsert with same id replaces row (price update persists)', () async {
      const initial = Product(
        id: 'p_dup',
        name: 'Es Teh',
        categoryId: 'cat_food',
        price: 5000,
        iconKey: 'local_drink',
      );
      await ProductRepository.instance.upsert(initial);

      const updated = Product(
        id: 'p_dup',
        name: 'Es Teh',
        categoryId: 'cat_food',
        price: 7000, // bumped
        iconKey: 'local_drink',
      );
      await ProductRepository.instance.upsert(updated);

      final all = await ProductRepository.instance.all(outletId: _outlet);
      expect(all, hasLength(1));
      expect(all.first.id, 'p_dup');
      expect(all.first.price, 7000);
    });

    test('upsert with available:false is reflected via all(onlyAvailable:)',
        () async {
      const unavailable = Product(
        id: 'p_off',
        name: 'Es Jeruk',
        categoryId: 'cat_food',
        price: 8000,
        iconKey: 'local_drink',
        available: false,
      );
      await ProductRepository.instance.upsert(unavailable);

      // Default all() returns the row (no filter).
      final all = await ProductRepository.instance.all(outletId: _outlet);
      expect(all, hasLength(1));
      expect(all.first.available, isFalse);

      // onlyAvailable:true excludes it.
      final onlyAvailable =
          await ProductRepository.instance.all(outletId: _outlet, onlyAvailable: true);
      expect(onlyAvailable, isEmpty);
    });

    test('delete removes the product from all()', () async {
      await ProductRepository.instance.upsert(_seededProduct);
      expect(await ProductRepository.instance.all(outletId: _outlet), hasLength(1));

      await ProductRepository.instance.delete(_seededProduct.id);
      expect(await ProductRepository.instance.all(outletId: _outlet), isEmpty);
    });
  });
}
