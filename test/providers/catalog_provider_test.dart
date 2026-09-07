import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/category.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/providers/catalog_provider.dart';

import '../helpers/db_helper.dart';
import '../helpers/provider_helpers.dart';

const _seedCategory = Category(
  id: 'cat_food',
  name: 'Food',
  emoji: '🍱',
  iconKey: 'set_meal',
  sortOrder: 0,
);

const _seedProduct = Product(
  id: 'p_nasi',
  name: 'Nasi Goreng',
  categoryId: 'cat_food',
  price: 25000,
  iconKey: 'rice_bowl',
);

Future<void> _seed(Database db) async {
  await db.insert('categories', _seedCategory.toMap());
  await db.insert('products', _seedProduct.toMap());
}

class Counter {
  int value = 0;
}

ProviderSubscription<T> _countRebuilds<T>(
  ProviderContainer container,
  ProviderListenable<T> provider,
  Counter counter,
) {
  return container.listen<T>(provider, (_, _) => counter.value++);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Database? db;
  late ProviderContainer container;

  setUp(() async {
    db = await openInMemoryAppDb(seed: false);
    await AppDatabase.instance.useTestDb(db!);
    await _seed(db!);
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    if (db != null && db!.isOpen) {
      await db!.close();
    }
  });

  group('productsProvider', () {
    test('build reads the seeded product', () async {
      final products = await container.read(productsProvider.future);
      expect(products, hasLength(1));
      expect(products.first.id, _seedProduct.id);
    });

    test('upsert refreshes the cache with the new product', () async {
      final counter = Counter();
      _countRebuilds<AsyncValue<List<Product>>>(
        container,
        productsProvider,
        counter,
      );
      await container.read(productsProvider.future);
      final baseline = counter.value;

      const newProduct = Product(
        id: 'p_mie',
        name: 'Mie Goreng',
        categoryId: 'cat_food',
        price: 22000,
        iconKey: 'ramen_dining',
      );

      await container.read(productsProvider.notifier).upsert(newProduct);

      final products = await container.read(productsProvider.future);
      expect(products, hasLength(2));
      expect(
        products.map((p) => p.id).toSet(),
        {'p_nasi', 'p_mie'},
      );

      // upsert wrote the row to the DB too.
      final raw = await db!.query('products');
      expect(raw.map((r) => r['id']).toSet(), contains('p_mie'));

      // refresh() inside upsert sets loading then data — counter moved.
      expect(counter.value, greaterThan(baseline));
    });

    test('upsert on an existing id replaces the row', () async {
      await container.read(productsProvider.future);

      final updated = _seedProduct.copyWith(
        name: 'Nasi Goreng Special',
        price: 27000,
      );
      await container.read(productsProvider.notifier).upsert(updated);

      final products = await container.read(productsProvider.future);
      expect(products, hasLength(1)); // replaced, not appended
      expect(products.first.name, 'Nasi Goreng Special');
      expect(products.first.price, 27000);
    });

    test('delete removes the row and refreshes the cache', () async {
      final counter = Counter();
      _countRebuilds<AsyncValue<List<Product>>>(
        container,
        productsProvider,
        counter,
      );
      await container.read(productsProvider.future);
      final baseline = counter.value;

      await container.read(productsProvider.notifier).delete('p_nasi');

      final products = await container.read(productsProvider.future);
      expect(products, isEmpty);

      final raw = await db!.query('products');
      expect(raw, isEmpty);

      expect(counter.value, greaterThan(baseline));
    });
  });

  group('categoriesProvider', () {
    test('build reads the seeded category', () async {
      final categories = await container.read(categoriesProvider.future);
      expect(categories, hasLength(1));
      expect(categories.first.id, _seedCategory.id);
    });

    test('upsert refreshes the cache with the new category', () async {
      final counter = Counter();
      _countRebuilds<AsyncValue<List<Category>>>(
        container,
        categoriesProvider,
        counter,
      );
      await container.read(categoriesProvider.future);
      final baseline = counter.value;

      const newCategory = Category(
        id: 'cat_drinks',
        name: 'Drinks',
        emoji: '🥤',
        iconKey: 'local_drink',
        sortOrder: 1,
      );

      await container.read(categoriesProvider.notifier).upsert(newCategory);

      final categories = await container.read(categoriesProvider.future);
      expect(categories, hasLength(2));
      expect(
        categories.map((c) => c.id).toSet(),
        {'cat_food', 'cat_drinks'},
      );

      final raw = await db!.query('categories');
      expect(raw.map((r) => r['id']).toSet(), contains('cat_drinks'));

      expect(counter.value, greaterThan(baseline));
    });

    test('delete removes the row and refreshes the cache', () async {
      // categories table has FK from products.category_id with ON DELETE
      // CASCADE, so deleting the category would also drop the seeded
      // product. Use a fresh category to avoid cascade noise.
      const extra = Category(
        id: 'cat_extra',
        name: 'Extra',
        emoji: '🍪',
        iconKey: 'cake',
        sortOrder: 5,
      );
      await db!.insert('categories', extra.toMap());

      await container.read(categoriesProvider.future);

      final counter = Counter();
      _countRebuilds<AsyncValue<List<Category>>>(
        container,
        categoriesProvider,
        counter,
      );
      // Reading again keeps the subscription but doesn't rebuild (state is
      // already data). The listen above fires immediately on subscribe.
      await container.read(categoriesProvider.future);
      final baseline = counter.value;

      await container.read(categoriesProvider.notifier).delete('cat_extra');

      final categories = await container.read(categoriesProvider.future);
      expect(categories.map((c) => c.id).toSet(), isNot(contains('cat_extra')));

      final raw = await db!.query('categories');
      // No rows match the deleted id.
      expect(
        raw.where((r) => r['id'] == 'cat_extra'),
        isEmpty,
      );

      expect(counter.value, greaterThan(baseline));
    });
  });
}
