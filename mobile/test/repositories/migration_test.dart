import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';

import '../helpers/db_helper.dart';

/// Dead seed image URL cleared by the v3 migration (one entry from
/// `AppDatabase._deadSeedImageIds`). The full URL is reconstructed with the
/// same prefix/suffix the migration uses so the `IN ($placeholders)` match
/// hits.
const _deadSeedImageUrl =
    'https://images.unsplash.com/photo-1495475758274-1020bbedaa89'
    '?auto=format&fit=crop&w=400&q=80';

/// A URL that is NOT in the dead list — v3 must leave it untouched.
const _liveImageUrl =
    'https://images.unsplash.com/photo-9999999999'
    '?auto=format&fit=crop&w=400&q=80';

/// The schema as it shipped at v1: `products` had no `image_url` / `icon_key`,
/// `categories` had no `icon_key`. The other tables are unchanged by any later
/// migration but are recreated here so the upgrade runs against a realistic
/// full-schema v1 DB (FKs, indexes, etc.).
void _createSchemaV1(Batch batch) {
  batch.execute('''
    CREATE TABLE categories (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      emoji TEXT NOT NULL DEFAULT '🍽️',
      sort_order INTEGER NOT NULL DEFAULT 0,
      is_popular INTEGER NOT NULL DEFAULT 0
    )
  ''');

  batch.execute('''
    CREATE TABLE products (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      category_id TEXT NOT NULL,
      price INTEGER NOT NULL,
      description TEXT,
      emoji TEXT NOT NULL DEFAULT '🍽️',
      available INTEGER NOT NULL DEFAULT 1,
      is_popular INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
    )
  ''');

  batch.execute('''
    CREATE TABLE tables (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      capacity INTEGER NOT NULL DEFAULT 2,
      status TEXT NOT NULL DEFAULT 'available',
      floor TEXT NOT NULL DEFAULT 'floor_1',
      sort_order INTEGER NOT NULL DEFAULT 0
    )
  ''');

  batch.execute('''
    CREATE TABLE orders (
      id TEXT PRIMARY KEY,
      number TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      type TEXT NOT NULL,
      table_id TEXT,
      table_name TEXT,
      customer_name TEXT,
      note TEXT,
      subtotal INTEGER NOT NULL,
      discount INTEGER NOT NULL DEFAULT 0,
      tax INTEGER NOT NULL DEFAULT 0,
      total INTEGER NOT NULL,
      amount_paid INTEGER NOT NULL DEFAULT 0,
      payment_method TEXT NOT NULL,
      status TEXT NOT NULL,
      cashier_id TEXT NOT NULL,
      cashier_name TEXT NOT NULL
    )
  ''');

  batch.execute('''
    CREATE TABLE order_items (
      id TEXT PRIMARY KEY,
      order_id TEXT NOT NULL,
      product_id TEXT NOT NULL,
      product_name TEXT NOT NULL,
      unit_price INTEGER NOT NULL,
      quantity INTEGER NOT NULL,
      note TEXT,
      FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
    )
  ''');

  batch.execute('CREATE INDEX idx_products_category ON products(category_id)');
  batch.execute('CREATE INDEX idx_orders_created ON orders(created_at DESC)');
  batch.execute('CREATE INDEX idx_order_items_order ON order_items(order_id)');
}

/// The v2 schema: `products.image_url` / `products.icon_key` were added, but
/// `categories.icon_key` did not yet exist (that is v4). Used to test the
/// v3 dead-URL cleanup as a v2 → v4 upgrade.
void _createSchemaV2(Batch batch) {
  _createSchemaV1(batch);
  // v2 migration was: ALTER TABLE products ADD COLUMN image_url / icon_key.
  // Recreated here as a single schema (columns nullable, matching the
  // ALTER TABLE semantics — no NOT NULL, no DEFAULT).
  batch.execute('ALTER TABLE products ADD COLUMN image_url TEXT;');
  batch.execute('ALTER TABLE products ADD COLUMN icon_key TEXT;');
}

Future<Database> _openAtVersion({
  required String path,
  required int version,
  required void Function(Batch) createSchema,
}) {
  return openDatabase(
    path,
    version: version,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON;');
    },
    onCreate: (db, v) async {
      final batch = db.batch();
      createSchema(batch);
      await batch.commit(noResult: true);
    },
  );
}

Future<String> _tempDbPath(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  return '${dir.path}/nti_pos.db';
}

Set<String> _columns(List<Map<String, Object?>> rows) {
  return rows.map((r) => r['name'] as String).toSet();
}

void main() {
  setUpAll(initFfi);

  group('DB migration chain', () {
    test('v26 to v27 preserves tables, promos and unsent sales', () async {
      final path = await _tempDbPath('migration_v26_v27_');
      addTearDown(() async {
        final dir = File(path).parent;
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final old = await AppDatabase.openForTest(
        path: path,
        version: 26,
        seed: false,
      );
      await old.execute('DROP TABLE promo_outlets');
      await old.execute('DROP TABLE table_status_events');
      await old.execute('ALTER TABLE promos DROP COLUMN all_outlets');
      for (final column in [
        'server_seq',
        'server_status',
        'contested',
        'pos_x',
        'pos_y',
      ]) {
        await old.execute('ALTER TABLE tables DROP COLUMN $column');
      }
      await old.insert('tables', {
        'id': 't1',
        'name': 'Meja 1',
        'status': 'occupied',
      });
      await old.insert('promos', {
        'id': 'p1',
        'name': 'Promo',
        'kind': 'percent',
        'value': 10,
      });
      await old.insert('_outbox', {
        'entity': 'orders',
        'entity_id': 'sale-1',
        'queued_at': 123,
        'attempts': 4,
      });
      await old.close();
      final db = await AppDatabase.openForTest(path: path, seed: false);
      addTearDown(db.close);
      expect((await db.query('tables')).single['status'], 'occupied');
      expect((await db.query('tables')).single['contested'], 0);
      expect((await db.query('promos')).single['all_outlets'], 1);
      expect((await db.query('_outbox')).single['attempts'], 4);
      expect(
        _columns(await db.rawQuery('PRAGMA table_info(table_status_events)')),
        containsAll(['client_seq', 'basis_seq', 'server_seq', 'outcome']),
      );
      expect(await db.query('promo_outlets'), isEmpty);
    });
    test('v1 → v4: v2 adds product columns, v4 adds category icon_key', () async {
      final path = await _tempDbPath('migration_v1_v4_');
      addTearDown(() async {
        final dir = File(path).parent;
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      // 1. Open a v1 DB and seed a product + category that the migration
      //    must preserve.
      final v1Db = await _openAtVersion(
        path: path,
        version: 1,
        createSchema: _createSchemaV1,
      );
      await v1Db.insert('categories', {
        'id': 'cat_food',
        'name': 'Food',
        'emoji': '🍱',
        'sort_order': 0,
        'is_popular': 0,
      });
      await v1Db.insert('products', {
        'id': 'p_nasi_goreng',
        'name': 'Nasi Goreng',
        'category_id': 'cat_food',
        'price': 25000,
        'emoji': '🍳',
        'available': 1,
        'is_popular': 1,
        'sort_order': 0,
      });

      // 2. Assert v1 schema: v2/v4-added columns absent.
      final v1ProductCols = _columns(
        await v1Db.rawQuery('PRAGMA table_info(products)'),
      );
      expect(
        v1ProductCols.contains('image_url'),
        isFalse,
        reason: 'image_url is a v2 column, must not exist at v1',
      );
      expect(
        v1ProductCols.contains('icon_key'),
        isFalse,
        reason: 'products.icon_key is a v2 column, must not exist at v1',
      );

      final v1CategoryCols = _columns(
        await v1Db.rawQuery('PRAGMA table_info(categories)'),
      );
      expect(
        v1CategoryCols.contains('icon_key'),
        isFalse,
        reason: 'categories.icon_key is a v4 column, must not exist at v1',
      );

      // user_version is 1.
      final v1Version = (await v1Db.rawQuery(
        'PRAGMA user_version',
      )).first['user_version'];
      expect(v1Version, 1);

      await v1Db.close();

      // 3. Re-open at v4 on the SAME path. sqflite sees user_version=1 < 4
      //    and runs the app's `_onUpgrade(db, 1, 4)`, which applies every
      //    step in sequence (v1→v2, v2→v3, v3→v4).
      final v4Db = await AppDatabase.openForTest(
        path: path,
        version: AppDatabase.currentVersion,
        seed: false,
      );
      addTearDown(v4Db.close);

      // 4. Schema-level assertions: every migration step's column exists.
      final v4ProductCols = _columns(
        await v4Db.rawQuery('PRAGMA table_info(products)'),
      );
      expect(
        v4ProductCols.contains('image_url'),
        isTrue,
        reason: 'v2 must have added products.image_url',
      );
      expect(
        v4ProductCols.contains('icon_key'),
        isTrue,
        reason: 'v2 must have added products.icon_key',
      );

      final v4CategoryCols = _columns(
        await v4Db.rawQuery('PRAGMA table_info(categories)'),
      );
      expect(
        v4CategoryCols.contains('icon_key'),
        isTrue,
        reason: 'v4 must have added categories.icon_key',
      );

      // user_version bumped to 4.
      final v4Version = (await v4Db.rawQuery(
        'PRAGMA user_version',
      )).first['user_version'];
      expect(v4Version, AppDatabase.currentVersion);

      // 5. Data preservation: the v1 rows survived the upgrade.
      final products = await v4Db.query('products');
      expect(products, hasLength(1));
      expect(products.first['id'], 'p_nasi_goreng');
      expect(products.first['name'], 'Nasi Goreng');
      expect(products.first['price'], 25000);
      // v5 backfill: `p_nasi_goreng` is a seed product id, so the v5 step fills
      // its NULL image_url with the sourced (HEAD-verified) Unsplash photo. A
      // legacy row whose id is NOT a seed id would stay NULL.
      expect(
        products.first['image_url'],
        'https://images.unsplash.com/photo-1680674774705-90b4904b3a7f?auto=format&fit=crop&w=400&q=80',
        reason: 'v5 backfill maps p_nasi_goreng to its sourced photo',
      );
      // products.icon_key is never backfilled by a migration (only categories
      // were, in v4) → stays NULL for legacy rows.
      expect(products.first['icon_key'], isNull);

      // 6. v4 backfill: `cat_food` is a seed category id, so the v4 step
      //    wrote its mapped icon_key ('set_meal') onto the legacy row.
      final categories = await v4Db.query('categories');
      expect(categories, hasLength(1));
      expect(categories.first['id'], 'cat_food');
      expect(
        categories.first['icon_key'],
        'set_meal',
        reason: 'v4 backfill maps cat_food → set_meal',
      );
    });

    test('v2 → v4: v3 nulls the dead seed image URLs', () async {
      final path = await _tempDbPath('migration_v2_v4_');
      addTearDown(() async {
        final dir = File(path).parent;
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      // 1. Open a v2 DB (products already have image_url + icon_key).
      final v2Db = await _openAtVersion(
        path: path,
        version: 2,
        createSchema: _createSchemaV2,
      );
      await v2Db.insert('categories', {
        'id': 'cat_food',
        'name': 'Food',
        'emoji': '🍱',
        'sort_order': 0,
        'is_popular': 0,
      });

      // One product with a known-dead seed URL (v3 must null it) and one
      // with a URL not on the dead list (v3 must leave it).
      await v2Db.insert('products', {
        'id': 'p_dead',
        'name': 'Dead URL',
        'category_id': 'cat_food',
        'price': 10000,
        'image_url': _deadSeedImageUrl,
        'icon_key': 'restaurant',
        'available': 1,
        'is_popular': 0,
        'sort_order': 0,
      });
      await v2Db.insert('products', {
        'id': 'p_live',
        'name': 'Live URL',
        'category_id': 'cat_food',
        'price': 10000,
        'image_url': _liveImageUrl,
        'icon_key': 'restaurant',
        'available': 1,
        'is_popular': 0,
        'sort_order': 1,
      });

      // Pre-condition: both URLs are intact at v2.
      final deadBefore = (await v2Db.query(
        'products',
        where: "id = 'p_dead'",
      )).first;
      expect(deadBefore['image_url'], _deadSeedImageUrl);

      await v2Db.close();

      // 2. Re-open at v4 — runs `_onUpgrade(db, 2, 4)`:
      //    v2→v3 (null dead URLs) then v3→v4 (categories.icon_key + backfill).
      final v4Db = await AppDatabase.openForTest(
        path: path,
        version: AppDatabase.currentVersion,
        seed: false,
      );
      addTearDown(v4Db.close);

      // 3. v3 effect: dead URL nulled, live URL preserved.
      final deadAfter = (await v4Db.query(
        'products',
        where: "id = 'p_dead'",
      )).first;
      expect(
        deadAfter['image_url'],
        isNull,
        reason: 'v3 must null the dead seed image URL',
      );

      final liveAfter = (await v4Db.query(
        'products',
        where: "id = 'p_live'",
      )).first;
      expect(
        liveAfter['image_url'],
        _liveImageUrl,
        reason: 'v3 must not touch URLs that are not on the dead list',
      );

      // Both rows survived (v3 is an UPDATE, not a DELETE).
      expect(await v4Db.query('products'), hasLength(2));
    });

    test(
      'v11 renames the seeded staff everywhere their name was copied',
      () async {
        final db = await openInMemoryAppDb();
        addTearDown(db.close);

        // A pre-v11 install: the manager under the old name, plus the three
        // places that snapshot a name instead of joining to it.
        await db.insert('employees', {
          'id': 'emp_manager',
          'name': 'Budi Santoso',
          'pin': '1234',
          'role': 'manager',
          'active': 1,
          'sort_order': 0,
        });
        await db.insert('orders', {
          'id': 'ord_old',
          'number': 'ORD-0001',
          'type': 'dine_in',
          'status': 'completed',
          'subtotal': 10000,
          'tax': 0,
          'discount': 0,
          'total': 10000,
          'payment_method': 'cash',
          'amount_paid': 10000,
          'cashier_id': 'emp_manager',
          'cashier_name': 'Budi Santoso',
          'authorized_by': 'Budi Santoso',
          'created_at': 1,
        });
        await db.insert('shifts', {
          'id': 'sh_old',
          'employee_id': 'emp_manager',
          'employee_name': 'Budi Santoso',
          'opened_at': 1,
          'opening_cash': 0,
        });
        await db.insert('stock_movements', {
          'id': 'sm_old',
          'product_id': 'p_x',
          'product_name': 'X',
          'delta': 1,
          'balance_after': 1,
          'reason': 'opening',
          'created_at': 1,
          'employee_id': 'emp_manager',
          'employee_name': 'Budi Santoso',
        });
        // Someone the user renamed themselves — same id family, different name.
        // The rename is scoped to the old name, so this must survive untouched.
        await db.insert('employees', {
          'id': 'emp_kasir_2',
          'name': 'Nama Pilihan Sendiri',
          'pin': '3456',
          'role': 'cashier',
          'active': 1,
          'sort_order': 2,
        });

        await AppDatabase.instance.renameSeedStaff(db);

        final manager = (await db.query(
          'employees',
          where: 'id = ?',
          whereArgs: ['emp_manager'],
        )).first;
        expect(manager['name'], 'Siwi Wiyono Raharjo');

        final order = (await db.query('orders')).first;
        expect(order['cashier_name'], 'Siwi Wiyono Raharjo');
        expect(
          order['authorized_by'],
          'Siwi Wiyono Raharjo',
          reason: 'the approver is recorded by name; it has to move too',
        );

        expect(
          (await db.query('shifts')).first['employee_name'],
          'Siwi Wiyono Raharjo',
        );
        expect(
          (await db.query('stock_movements')).first['employee_name'],
          'Siwi Wiyono Raharjo',
        );

        final renamed = (await db.query(
          'employees',
          where: 'id = ?',
          whereArgs: ['emp_kasir_2'],
        )).first;
        expect(
          renamed['name'],
          'Nama Pilihan Sendiri',
          reason: 'a name the user chose must not be overwritten',
        );
      },
    );

    test('v1 → v16: the whole chain lands on tills', () async {
      final path = await _tempDbPath('migration_v1_v16_');
      addTearDown(() async {
        final dir = File(path).parent;
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final v1Db = await _openAtVersion(
        path: path,
        version: 1,
        createSchema: _createSchemaV1,
      );
      await v1Db.insert('categories', {
        'id': 'cat_food',
        'name': 'Food',
        'emoji': '🍱',
        'sort_order': 0,
        'is_popular': 0,
      });
      await v1Db.close();

      // The oldest install runs every step in order. This is the case the
      // deferred-writer rule exists for: v6 broke it once and v12 broke it
      // again, both by writing rows against a schema that was still mid-chain.
      final db = await AppDatabase.openForTest(path: path, seed: false);
      addTearDown(() async {
        if (db.isOpen) await db.close();
      });

      final shiftCols = _columns(
        await db.rawQuery('PRAGMA table_info(shifts)'),
      );
      expect(
        shiftCols,
        containsAll(<String>[
          'pos_id',
          'pos_name',
          'outlet_id',
          'outlet_name',
          'closed_by_id',
          'closed_by_name',
        ]),
      );

      final orderCols = _columns(
        await db.rawQuery('PRAGMA table_info(orders)'),
      );
      expect(
        orderCols,
        containsAll(<String>['pos_id', 'pos_name', 'pos_session_id']),
      );

      final registers = await db.query('pos_registers');
      expect(
        registers,
        isNotEmpty,
        reason: 'every branch needs a till, or nobody can sign on to sell',
      );
      // Both kinds, in the first branch — the setting only means something
      // once two tills in one shop disagree about it.
      expect(registers.any((r) => r['table_service'] == 1), isTrue);
      expect(registers.any((r) => r['table_service'] == 0), isTrue);
    });

    test(
      'v15 → v16 leaves real sales without a till rather than guessing',
      () async {
        final path = await _tempDbPath('migration_v15_v16_');
        addTearDown(() async {
          final dir = File(path).parent;
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        // A v15 install: outlets and a floor plan exist, tills do not.
        //
        // `openForTest` always CREATES today's schema and only stamps the
        // version, so the register rows have to be stripped back out to reach
        // the state a real v15 install is in — history that exists, filed under
        // no till.
        final v15Db = await AppDatabase.openForTest(path: path, version: 15);
        await v15Db.delete('pos_registers');
        await v15Db.update('orders', {'pos_id': null, 'pos_name': null});
        final realOrderId = (await v15Db.query('orders', limit: 1)).first['id'];
        await v15Db.insert('shifts', {
          'id': 'legacy_open_shift',
          'employee_id': 'emp_kasir_1',
          'employee_name': 'Siti Rahayu',
          'opened_at': DateTime.now().millisecondsSinceEpoch,
          'opening_cash': 150000,
        });
        await v15Db.close();

        final db = await AppDatabase.openForTest(path: path, seed: false);
        addTearDown(() async {
          if (db.isOpen) await db.close();
        });

        expect(await db.query('pos_registers'), isNotEmpty);

        // The sales are real and were rung up before tills were modelled.
        // Stamping one on would be a name on history nobody can check.
        final order = (await db.query(
          'orders',
          where: 'id = ?',
          whereArgs: [realOrderId],
        )).first;
        expect(order['pos_id'], isNull);
        expect(order['pos_session_id'], isNull);

        // And a session that was still running stays open and untouched, so its
        // owner can adopt it at sign-in and close it normally.
        final shift = (await db.query(
          'shifts',
          where: 'id = ?',
          whereArgs: ['legacy_open_shift'],
        )).first;
        expect(
          shift['closed_at'],
          isNull,
          reason:
              'a live drawer must not be closed against a count nobody made',
        );
        expect(shift['pos_id'], isNull);
      },
    );

    test('a fresh seed files its demo sales under a till', () async {
      final db = await openInMemoryAppDb(seed: true);
      addTearDown(() async {
        if (db.isOpen) await db.close();
      });

      // The opposite of the upgrade case: these rows are fabricated anyway, so
      // leaving them with no till would make the feature undemonstrable.
      final unassigned = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM orders WHERE pos_id IS NULL'),
      );
      expect(unassigned, 0);

      // And a sale never lands on a till belonging to a different branch —
      // the two scopings have to agree or the per-outlet report and the
      // per-till drawer tell different stories.
      final mismatched = Sqflite.firstIntValue(
        await db.rawQuery(
          'SELECT COUNT(*) FROM orders o JOIN pos_registers r ON r.id = o.pos_id '
          'WHERE o.outlet_id != r.outlet_id',
        ),
      );
      expect(mismatched, 0);
    });

    test('one till cannot hold two open sessions', () async {
      final db = await openInMemoryAppDb(seed: true);
      addTearDown(() async {
        if (db.isOpen) await db.close();
      });
      final posId = (await db.query('pos_registers', limit: 1)).first['id'];

      Map<String, Object?> session(String id) => {
        'id': id,
        'employee_id': 'emp_$id',
        'employee_name': id,
        'pos_id': posId,
        'opened_at': DateTime.now().millisecondsSinceEpoch,
        'opening_cash': 0,
      };

      await db.insert('shifts', session('a'));
      // The partial unique index is the backstop under the repository check:
      // two drawers on one cash box cannot be reconciled afterwards, so the
      // database refuses even if a caller forgets to ask.
      await expectLater(
        db.insert('shifts', session('b')),
        throwsA(isA<DatabaseException>()),
      );

      // Closing the first releases the till, and the index lets the next
      // session in — this is "the POS is available again" at the SQL level.
      await db.update(
        'shifts',
        {'closed_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: ['a'],
      );
      await db.insert('shifts', session('c'));
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM shifts WHERE closed_at IS NULL',
          ),
        ),
        1,
      );
    });

    test('v1 → v17: modifier tables land, and seeding skips products that are '
        'not there — mirroring seedVariants', () async {
      final path = await _tempDbPath('migration_v1_v17_');
      addTearDown(() async {
        final dir = File(path).parent;
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      // No products inserted at all — this v1 install never had any of the
      // seeded ids `seedModifiers` attaches groups to.
      final v1Db = await _openAtVersion(
        path: path,
        version: 1,
        createSchema: _createSchemaV1,
      );
      await v1Db.close();

      final db = await AppDatabase.openForTest(path: path, seed: false);
      addTearDown(() async {
        if (db.isOpen) await db.close();
      });

      final orderItemCols = _columns(
        await db.rawQuery('PRAGMA table_info(order_items)'),
      );
      expect(
        orderItemCols,
        containsAll(<String>['category_id', 'category_name']),
      );

      // Groups and options are unconditional — they do not reference a
      // product — so they seed regardless of the catalogue.
      final groups = await db.query('modifier_groups');
      expect(groups, hasLength(4));
      expect(await db.query('modifier_options'), isNotEmpty);

      // But NOT ONE product-attachment row: every id `_seedModifierGroups`
      // names is absent from this install's `products` table, and
      // `product_modifier_groups.product_id` has an enforced FK — exactly
      // the SQLite-error-787 hazard `seedVariants` already guards against.
      expect(
        await db.query('product_modifier_groups'),
        isEmpty,
        reason:
            'seedModifiers must skip attaching a group to a product that '
            'does not exist, the same way seedVariants skips it',
      );
    });

    test('v16 → v17 backfills category_id/category_name on order lines whose '
        'product still exists, and leaves an orphaned line NULL', () async {
      final path = await _tempDbPath('migration_v16_v17_');
      addTearDown(() async {
        final dir = File(path).parent;
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final v16Db = await AppDatabase.openForTest(path: path, version: 16);
      // A line whose product is still in the catalogue — must be backfilled
      // from that product's live category.
      final product = (await v16Db.query('products', limit: 1)).first;
      await v16Db.insert('order_items', {
        'id': 'oi_live_product',
        'order_id': (await v16Db.query('orders', limit: 1)).first['id'],
        'product_id': product['id'],
        'product_name': product['name'],
        'unit_price': 10000,
        'quantity': 1,
      });
      // A line whose product has since been deleted — nothing left to
      // recover from, must stay NULL rather than invent a category.
      await v16Db.insert('order_items', {
        'id': 'oi_orphaned_product',
        'order_id': (await v16Db.query('orders', limit: 1)).first['id'],
        'product_id': 'p_long_gone',
        'product_name': 'Deleted Product',
        'unit_price': 10000,
        'quantity': 1,
      });
      await v16Db.close();

      final db = await AppDatabase.openForTest(path: path, seed: false);
      addTearDown(() async {
        if (db.isOpen) await db.close();
      });

      final live = (await db.query(
        'order_items',
        where: 'id = ?',
        whereArgs: ['oi_live_product'],
      )).first;
      expect(live['category_id'], product['category_id']);
      expect(live['category_name'], isNotNull);

      final orphaned = (await db.query(
        'order_items',
        where: 'id = ?',
        whereArgs: ['oi_orphaned_product'],
      )).first;
      expect(
        orphaned['category_id'],
        isNull,
        reason:
            'the product is gone, so there is nothing to recover the '
            'category from — must stay NULL, not guess',
      );
      expect(orphaned['category_name'], isNull);
    });

    test(
      'v17 → v18 backfills product_modifier_options from '
      'product_modifier_groups, using only currently-active options',
      () async {
        final path = await _tempDbPath('migration_v17_v18_');
        addTearDown(() async {
          final dir = File(path).parent;
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        // A v17 install: product_modifier_groups exists and is seeded, but
        // product_modifier_options — this migration's whole point — does
        // not yet, so it is stripped back out the same way v15→v16's test
        // strips pos_registers.
        final v17Db = await AppDatabase.openForTest(path: path, version: 17);
        await v17Db.delete('product_modifier_options');

        // Deactivate one option in a group that IS attached to a product —
        // the backfill must not offer a product something it could not
        // already show, so an inactive option must be excluded.
        final attachment = (await v17Db.query(
          'product_modifier_groups',
          limit: 1,
        )).first;
        final groupId = attachment['group_id'] as String;
        final productId = attachment['product_id'] as String;
        final groupOptions = await v17Db.query(
          'modifier_options',
          where: 'group_id = ?',
          whereArgs: [groupId],
        );
        expect(
          groupOptions,
          isNotEmpty,
          reason:
              'the seeded groups all have options; a group with none '
              'would not exercise this test',
        );
        final activeIds = groupOptions.map((o) => o['id'] as String).toSet();
        final deactivatedId = activeIds.first;
        activeIds.remove(deactivatedId);
        await v17Db.update(
          'modifier_options',
          {'active': 0},
          where: 'id = ?',
          whereArgs: [deactivatedId],
        );
        await v17Db.close();

        final db = await AppDatabase.openForTest(path: path, seed: false);
        addTearDown(() async {
          if (db.isOpen) await db.close();
        });

        final scopeRows = await db.query(
          'product_modifier_options',
          where: 'product_id = ?',
          whereArgs: [productId],
        );
        final scopedIds = scopeRows
            .map((r) => r['option_id'] as String)
            .toSet();

        expect(
          scopedIds,
          activeIds,
          reason:
              'every currently-active option in the attached group '
              'must be backfilled, so an existing attachment keeps '
              'behaving exactly as it did before per-product scoping '
              'existed',
        );
        expect(
          scopedIds.contains(deactivatedId),
          isFalse,
          reason:
              'an inactive option was never actually offered, so '
              'backfilling it into scope would not match prior behaviour',
        );

        // Idempotent: running it again must not duplicate rows or throw a
        // primary-key conflict.
        await AppDatabase.instance.backfillProductModifierOptionScope(db);
        final scopeRowsAgain = await db.query(
          'product_modifier_options',
          where: 'product_id = ?',
          whereArgs: [productId],
        );
        expect(scopeRowsAgain, hasLength(scopeRows.length));
      },
    );

    test('v18 → v19 adds pb1_rate / service_charge_rate / '
        'service_charge_amount, defaulting existing rows to NULL rate / 0 '
        'amount rather than backfilling a guess', () async {
      final path = await _tempDbPath('migration_v18_v19_');
      addTearDown(() async {
        final dir = File(path).parent;
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final v18Db = await AppDatabase.openForTest(path: path, version: 18);
      final existingOrderId = (await v18Db.query(
        'orders',
        limit: 1,
      )).first['id'];
      await v18Db.close();

      final db = await AppDatabase.openForTest(path: path, seed: false);
      addTearDown(() async {
        if (db.isOpen) await db.close();
      });

      final orderCols = _columns(
        await db.rawQuery('PRAGMA table_info(orders)'),
      );
      expect(
        orderCols,
        containsAll(<String>[
          'pb1_rate',
          'service_charge_rate',
          'service_charge_amount',
        ]),
      );

      final row = (await db.query(
        'orders',
        where: 'id = ?',
        whereArgs: [existingOrderId],
      )).first;
      expect(
        row['pb1_rate'],
        isNull,
        reason:
            'the PB1 rate in effect for a pre-v19 order is '
            'genuinely unrecoverable if the store rate ever changed — '
            'must stay NULL, not guess',
      );
      expect(row['service_charge_rate'], isNull);
      expect(
        row['service_charge_amount'],
        0,
        reason:
            'the feature did not exist yet, so 0 is a fact for a '
            'pre-v19 order, not a guess',
      );
    });

    test(
      'v20 → v21 adds tables.active, defaulting every existing table to '
      'active rather than guessing which ones should be turned off',
      () async {
        final path = await _tempDbPath('migration_v20_v21_');
        addTearDown(() async {
          final dir = File(path).parent;
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final v20Db = await AppDatabase.openForTest(path: path, version: 20);
        final existingTableId = (await v20Db.query(
          'tables',
          limit: 1,
        )).first['id'];
        await v20Db.close();

        final db = await AppDatabase.openForTest(path: path, seed: false);
        addTearDown(() async {
          if (db.isOpen) await db.close();
        });

        final tableCols = _columns(
          await db.rawQuery('PRAGMA table_info(tables)'),
        );
        expect(tableCols, contains('active'));

        final row = (await db.query(
          'tables',
          where: 'id = ?',
          whereArgs: [existingTableId],
        )).first;
        expect(
          row['active'],
          1,
          reason:
              'a table that already existed was already visible on the '
              'board — an upgrading install\'s floor plan must not change',
        );
      },
    );

    test('v23 → v24 leaves a DEMO store completely intact — the purge is for '
        'connected stores only', () async {
      final path = await _tempDbPath('migration_v23_v24_');
      addTearDown(() async {
        final dir = File(path).parent;
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      final v23Db = await AppDatabase.openForTest(path: path, version: 23);
      final before = <String, int>{
        for (final t in ['products', 'categories', 'employees', 'orders'])
          t: Sqflite.firstIntValue(
            await v23Db.rawQuery('SELECT COUNT(*) FROM $t'),
          )!,
      };
      await v23Db.close();

      final db = await AppDatabase.openForTest(path: path, seed: false);
      addTearDown(() async {
        if (db.isOpen) await db.close();
      });

      // v24 empties every business table — but ONLY when the app has been
      // pointed at a connected store. `openForTest` never sets that scope,
      // which is the same state the demo store (`nti_pos.db`) is always in.
      // If this ever fails, activating a device has started deleting the
      // user's demo data.
      for (final entry in before.entries) {
        final after = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM ${entry.key}'),
        );
        expect(
          after,
          entry.value,
          reason:
              '${entry.key} lost rows on upgrade — the v24 purge escaped '
              'its connected-store guard',
        );
      }

      // The two additive halves of v24 still apply everywhere.
      expect(
        _columns(await db.rawQuery('PRAGMA table_info(orders)')),
        contains('number_seq'),
      );
      final outbox = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='_outbox'",
      );
      expect(outbox, isNotEmpty);
    });

    test(
      'v24 → v25 keeps every queued entry and adds the v2 sync tables',
      () async {
        final path = await _tempDbPath('migration_v24_v25_');
        addTearDown(() async {
          final dir = File(path).parent;
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        // Rebuild the v24 shapes by hand: `openForTest` creates today's schema,
        // which already has the v25 columns and tables.
        final v24Db = await AppDatabase.openForTest(
          path: path,
          version: 24,
          seed: false,
        );
        await v24Db.execute('DROP TABLE _outbox');
        await v24Db.execute('''
          CREATE TABLE _outbox (
            entity TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            queued_at INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            PRIMARY KEY (entity, entity_id)
          )
        ''');
        for (final table in ['_push_revisions', '_dead_letter', '_sync_meta']) {
          await v24Db.execute('DROP TABLE $table');
        }
        await v24Db.execute('ALTER TABLE orders DROP COLUMN business_date');
        await v24Db.execute(
          'ALTER TABLE orders DROP COLUMN server_time_delta_ms',
        );
        await v24Db.insert('orders', {
          'id': 'order-1',
          'number': 'K1-0001',
          'created_at': 1757800000000,
          'type': 'takeaway',
          'subtotal': 15000,
          'total': 15000,
          'payment_method': 'cash',
          'status': 'paid',
          'cashier_id': 'e1',
          'cashier_name': 'Siti',
        });
        await v24Db.insert('_outbox', {
          'entity': 'orders',
          'entity_id': 'order-1',
          'queued_at': 1757800000001,
          'attempts': 4,
          'last_error': 'network',
        });
        await v24Db.close();

        final db = await AppDatabase.openForTest(path: path, seed: false);
        addTearDown(() async {
          if (db.isOpen) await db.close();
        });

        // The sale a v24 till still owed is still owed — with its history.
        final queued = await db.query('_outbox');
        expect(queued, hasLength(1));
        expect(queued.single['entity_id'], 'order-1');
        expect(queued.single['attempts'], 4);
        expect(queued.single['revision'], isNull);

        expect(
          _columns(await db.rawQuery('PRAGMA table_info(_outbox)')),
          containsAll(['revision', 'payload']),
        );
        expect(
          _columns(await db.rawQuery('PRAGMA table_info(orders)')),
          containsAll(['business_date', 'server_time_delta_ms']),
        );
        for (final table in ['_push_revisions', '_dead_letter', '_sync_meta']) {
          final found = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            [table],
          );
          expect(found, isNotEmpty, reason: '$table is missing after v25');
        }
        expect(await db.query('orders'), hasLength(1));
      },
    );

    test(
      'v25 → v26 adds the stock ledger columns and keeps every movement',
      () async {
        final path = await _tempDbPath('migration_v25_v26_');
        addTearDown(() async {
          final dir = File(path).parent;
          if (await dir.exists()) await dir.delete(recursive: true);
        });

        final v25Db = await AppDatabase.openForTest(
          path: path,
          version: 25,
          seed: false,
        );
        for (final column in [
          'counted_qty',
          'basis_seq',
          'server_seq',
          'origin',
        ]) {
          await v25Db.execute(
            'ALTER TABLE stock_movements DROP COLUMN $column',
          );
        }
        for (final column in ['server_qty', 'server_seq']) {
          await v25Db.execute('ALTER TABLE outlet_stock DROP COLUMN $column');
        }
        await v25Db.insert('outlet_stock', {
          'outlet_id': 'o1',
          'product_id': 'p1',
          'stock': 7,
        });
        await v25Db.insert('stock_movements', {
          'id': 'm1',
          'outlet_id': 'o1',
          'product_id': 'p1',
          'product_name': 'Es Teh',
          'delta': -1,
          'balance_after': 7,
          'reason': 'sale',
          'created_at': 1757800000000,
        });
        await v25Db.close();

        final db = await AppDatabase.openForTest(path: path, seed: false);
        addTearDown(() async {
          if (db.isOpen) await db.close();
        });

        expect(
          _columns(await db.rawQuery('PRAGMA table_info(stock_movements)')),
          containsAll(['counted_qty', 'basis_seq', 'server_seq', 'origin']),
        );
        expect(
          _columns(await db.rawQuery('PRAGMA table_info(outlet_stock)')),
          containsAll(['server_qty', 'server_seq']),
        );
        final movement = (await db.query('stock_movements')).single;
        expect(movement['origin'], 'device');
        expect(movement['server_seq'], isNull);
        expect((await db.query('outlet_stock')).single['stock'], 7);
      },
    );
  });
}
