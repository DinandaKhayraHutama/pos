import 'dart:math';

import 'package:flutter/foundation.dart' hide Category;
import 'package:sqflite/sqflite.dart';

import '../models/category.dart';
import '../models/employee.dart';
import '../models/enums.dart';
import '../models/product.dart';
import '../models/promo.dart';
import '../models/stock_movement.dart';
import '../models/table.dart';
import 'db_platform.dart';

/// One row of `AppDatabase._seedModifierGroups` — a group, its options, and
/// which seeded products it attaches to.
typedef _SeedModifierGroup = ({
  String id,
  String name,
  String selectionType,
  bool required,
  int? maxSelect,
  List<(String, int)> options,
  List<String> productIds,
});

/// Local SQLite database. This layer can be swapped with a REST API later by
/// replacing only the repository implementations - models & UI stay the same.
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;
  String? _connectedScope;

  Future<void> configureConnectedStore(String scope) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(scope)) {
      throw ArgumentError('Invalid storage scope');
    }
    if (_connectedScope == scope) return;
    if (_db != null && _db!.isOpen) await _db!.close();
    _db = null;
    _connectedScope = scope;
  }

  /// Opens the demo store at its own path, or null when the device has never
  /// run one.
  ///
  /// A SECOND connection, deliberately outside [db], so the demo store can be
  /// read while the singleton is pointed at a connected one.
  ///
  /// **Currently unused, and kept on purpose.** Its only caller was the
  /// adoption step that copied demo rows into a connected store, which was
  /// removed because it produced duplicated staff and a doubled catalogue (see
  /// `connected_storage.dart`). It stays because the planned move of the demo
  /// assets into the Backoffice needs exactly this: a way to read `nti_pos.db`
  /// alongside another database. Deleting ten lines only to write them again is
  /// churn.
  ///
  /// Opened at [currentVersion] so `_onUpgrade` brings an old install's schema
  /// up to today's before anything is read — a v18 store has no
  /// `service_charge_amount`, and reading columns that do not exist yet is how
  /// a bulk read of real history fails halfway through.
  ///
  /// `onCreate` is deliberately absent: existence is checked first, so this can
  /// only ever open something that is already there. Falling back to creating
  /// (and seeding) one would fabricate a demo month nobody asked for.
  Future<Database?> openLegacyStore() async {
    configureDatabaseFactory();
    final path = await resolveDatabasePath('nti_pos.db');
    if (!await databaseFactory.databaseExists(path)) return null;
    return openDatabase(
      path,
      version: _version,
      onConfigure: _onConfigure,
      onUpgrade: _onUpgrade,
    );
  }

  final int _version = currentVersion;

  /// Schema version the app currently targets. Exposed so tests can open an
  /// in-memory DB at the same version via [openForTest].
  static const int currentVersion = 33;

  /// Seed image ids that no longer resolve (all 404; `1605478371 size_400`
  /// was malformed with a literal space). Cleared in the v3 migration so
  /// existing installs stop refetching a dead image on every rebuild and fall
  /// back to the product icon instead.
  static const _deadSeedImageIds = <String>[
    '1495475758274-1020bbedaa89',
    '1496116218846-6895667ea7b1',
    '1509440159596-0caf90c66c99',
    '1517959105821-eaf2398ea6b1',
    '1529563091598-af63a26a7fa3',
    '1562003342-3abisgbmnffs',
    '1569718212165-3a8278d5f6cc',
    '1603133873492-3c26d6c4b67b',
    '1604908554049-2b81d33c3aaf',
    '1604908554049-2b81d33c3af3',
    '1605478371 size_400',
    '1626644152592-c3e0333ef2b5',
  ];

  Future<Database> get db async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = await _open();
    return _db!;
  }

  /// Test-only: injects a pre-opened database (typically an in-memory DB
  /// from `sqflite_common_ffi` opened via [openForTest]) so every repository
  /// singleton that reads `AppDatabase.instance.db` hits the test schema
  /// instead of the on-disk app database.
  ///
  /// Ownership transfers: the caller is responsible for `close()`ing [db]
  /// once the test is done, typically via `addTearDown(db.close)`. Any
  /// previously-cached database is closed first.
  ///
  /// Production never calls this. Behaviour-identical for production: this
  /// only reassigns the internal cache, the same field `db` itself writes
  /// to on first access.
  @visibleForTesting
  Future<void> useTestDb(Database db) async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
    }
    _db = db;
  }

  Future<Database> _open() async {
    configureDatabaseFactory();
    final path = await resolveDatabasePath(
      _connectedScope == null ? 'nti_pos.db' : 'connected_$_connectedScope.db',
    );
    return openDatabase(
      path,
      version: _version,
      onConfigure: _onConfigure,
      onCreate: _connectedScope == null
          ? _onCreate
          : (db, version) async {
              final batch = db.batch();
              _createSchemaV2(batch);
              await batch.commit(noResult: true);
            },
      onUpgrade: _onUpgrade,
    );
  }

  /// Opens a [Database] at [path] wired to the same schema callbacks the
  /// singleton uses. Intended for tests (e.g. an in-memory DB via
  /// `sqflite_common_ffi`); production code should keep using [db].
  ///
  /// [version] defaults to [currentVersion]. When [seed] is false the schema
  /// is created without demo data, so the caller can assert on an empty DB.
  /// Behavior is identical to [_open] when [seed] is true and [version] is
  /// [currentVersion] — the same `_onConfigure` / `_onCreate` / `_onUpgrade`
  /// callbacks run.
  static Future<Database> openForTest({
    required String path,
    int? version,
    bool seed = true,
  }) {
    final instance = AppDatabase.instance;
    return openDatabase(
      path,
      version: version ?? currentVersion,
      onConfigure: instance._onConfigure,
      onCreate: seed
          ? instance._onCreate
          : (db, v) async {
              final batch = db.batch();
              instance._createSchemaV2(batch);
              await batch.commit(noResult: true);
            },
      onUpgrade: instance._onUpgrade,
    );
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON;');
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    _createSchemaV2(batch);
    await batch.commit(noResult: true);
    await _seed(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE products ADD COLUMN image_url TEXT;');
      await db.execute('ALTER TABLE products ADD COLUMN icon_key TEXT;');
    }
    if (oldVersion < 3) {
      const prefix = 'https://images.unsplash.com/photo-';
      const suffix = '?auto=format&fit=crop&w=400&q=80';
      final dead = _deadSeedImageIds.map((id) => '$prefix$id$suffix').toList();
      final placeholders = List.filled(dead.length, '?').join(',');
      await db.rawUpdate(
        'UPDATE products SET image_url = NULL WHERE image_url IN ($placeholders)',
        dead,
      );
    }
    if (oldVersion < 4) {
      // v4: categories render a Material icon instead of an emoji, because
      // emoji do not resolve on every platform (notably the iOS Simulator).
      await db.execute('ALTER TABLE categories ADD COLUMN icon_key TEXT;');
      for (final e in _seedCategoryIconKeys.entries) {
        await db.update(
          'categories',
          {'icon_key': e.value},
          where: 'id = ?',
          whereArgs: [e.key],
        );
      }
    }
    if (oldVersion < 5) {
      // v5: 13 seed products shipped without a photo and fell back to their
      // icon. Backfill the freshly-sourced (HEAD-verified) Unsplash images, but
      // only where the row is still NULL so a user's own image edit is never
      // clobbered.
      const prefix = 'https://images.unsplash.com/photo-';
      const suffix = '?auto=format&fit=crop&w=400&q=80';
      for (final e in _seedProductImageBackfill.entries) {
        await db.update(
          'products',
          {'image_url': '$prefix${e.value}$suffix'},
          where: 'id = ? AND image_url IS NULL',
          whereArgs: [e.key],
        );
      }
    }
    // v6 seeded a week of demo sales here. Its call now runs at the END of
    // this method instead — see `backfillEmptyOrders`. A seeder has to write
    // against the FINAL schema: `seedOrders` gained the v10 void/refund
    // columns, and running it in v6 position on a v1 install failed with
    // "table orders has no column named authorized_by". Nothing else in the
    // chain depends on the orders existing at this point.
    if (oldVersion < 7) {
      // v7: per-product cost, SKU and stock. All nullable — an existing
      // catalogue keeps working untouched, and a NULL stock keeps meaning
      // "not counted" rather than "sold out".
      await db.execute('ALTER TABLE products ADD COLUMN cost INTEGER;');
      await db.execute('ALTER TABLE products ADD COLUMN sku TEXT;');
      await db.execute('ALTER TABLE products ADD COLUMN stock INTEGER;');
      await applySeedStock(db);
    }
    if (oldVersion < 8) {
      // v8: real employees. Before this the "login" compared against a single
      // constant and every order was attributed to a name typed in Settings.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS employees (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          pin TEXT NOT NULL DEFAULT '',
          role TEXT NOT NULL,
          active INTEGER NOT NULL DEFAULT 1,
          sort_order INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await seedEmployees(db);
    }
    if (oldVersion < 9) {
      // v9: till sessions. Cash accountability had no home before this.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS shifts (
          id TEXT PRIMARY KEY,
          employee_id TEXT NOT NULL,
          employee_name TEXT NOT NULL,
          opened_at INTEGER NOT NULL,
          opening_cash INTEGER NOT NULL,
          closed_at INTEGER,
          counted_cash INTEGER,
          expected_cash INTEGER,
          note TEXT
        )
      ''');
    }
    if (oldVersion < 10) {
      // v10: roles, variants, promos, per-product tax and a stock ledger.
      //
      // One migration rather than five because they land together and every
      // one of them is additive: new nullable columns and new tables. An
      // existing catalogue, order history and staff list all keep working
      // untouched — nothing here rewrites a row a user created.
      await db.execute('ALTER TABLE products ADD COLUMN tax_rate REAL;');
      await db.execute('ALTER TABLE order_items ADD COLUMN variant_name TEXT;');
      await db.execute('ALTER TABLE order_items ADD COLUMN unit_cost INTEGER;');
      await db.execute('ALTER TABLE orders ADD COLUMN promo_name TEXT;');
      await db.execute('ALTER TABLE orders ADD COLUMN authorized_by TEXT;');
      await db.execute('ALTER TABLE orders ADD COLUMN void_reason TEXT;');
      await db.execute(
        'ALTER TABLE orders ADD COLUMN refunded_amount INTEGER;',
      );
      await db.execute(_createProductVariantsSql);
      await db.execute(_createStockMovementsSql);
      await db.execute(_createPromosSql);
      await db.execute(_indexVariantsProductSql);
      await db.execute(_indexStockMovementsProductSql);
      await seedOwner(db);
      await seedVariants(db);
      await seedPromos(db);
      await applySeedCost(db);
      await seedOpeningStockMovements(db);
      await attributeSeedOrdersToStaff(db);
      await backfillOrderItemCost(db);
    }
    if (oldVersion < 11) {
      // v11: the demo staff got their real names.
      await renameSeedStaff(db);
    }

    if (oldVersion < 13) {
      // v13: the business can have more than one branch. Additive — the
      // outlet columns are nullable — but an install upgrading into this has
      // one shop's worth of history that all belongs to the first outlet, so
      // it is backfilled rather than left null. Null would read as "outlet
      // unknown" and quietly drop those sales out of every per-outlet total.
      await db.execute(_createOutletsSql);
      await _addColumnIfMissing(db, 'orders', 'outlet_id', 'TEXT');
      await _addColumnIfMissing(db, 'orders', 'outlet_name', 'TEXT');
      await seedOutlets(db);
    }

    if (oldVersion < 14) {
      // v14: stock stops being one number per product and becomes one number
      // per product PER OUTLET. This is the step that makes multi-outlet real
      // rather than cosmetic — a chain that cannot answer "sold out here, in
      // stock there" is not running branches, it is running one shop with two
      // names on the receipts.
      await db.execute(_createOutletStockSql);
      await _addColumnIfMissing(db, 'stock_movements', 'outlet_id', 'TEXT');
    }

    if (oldVersion < 15) {
      // v15: the floor plan belongs to a branch. Two shops do not share
      // tables, and a board showing every branch's covers at once is worse
      // than no board — a waiter would seat a guest at a table in another
      // city.
      await _addColumnIfMissing(db, 'tables', 'outlet_id', 'TEXT');
    }

    if (oldVersion < 16) {
      // v16: a branch has TILLS, and selling means being signed on to one.
      //
      // This is the step that turns `shifts` from an optional cash log into a
      // POS session: it already knew the cashier, the times and the money, and
      // only ever lacked which till and which branch it belonged to. Adding
      // those columns is cheaper and more honest than a second table that
      // would have to be kept in step with it.
      //
      // All additive: every column here is nullable, so an existing shift
      // history and every past order keep reading exactly as they did.
      await db.execute(_createPosRegistersSql);

      await _addColumnIfMissing(db, 'shifts', 'pos_id', 'TEXT');
      await _addColumnIfMissing(db, 'shifts', 'pos_name', 'TEXT');
      await _addColumnIfMissing(db, 'shifts', 'outlet_id', 'TEXT');
      await _addColumnIfMissing(db, 'shifts', 'outlet_name', 'TEXT');
      await _addColumnIfMissing(db, 'shifts', 'closed_by_id', 'TEXT');
      await _addColumnIfMissing(db, 'shifts', 'closed_by_name', 'TEXT');

      await _addColumnIfMissing(db, 'orders', 'pos_id', 'TEXT');
      await _addColumnIfMissing(db, 'orders', 'pos_name', 'TEXT');
      await _addColumnIfMissing(db, 'orders', 'pos_session_id', 'TEXT');

      await db.execute(_indexOpenSessionPerRegisterSql);
    }

    if (oldVersion < 17) {
      // v17: reusable modifier groups (spice level, toppings, sugar level,
      // ice level) attached to products, plus a category snapshot on order
      // lines for the sales-by-category report.
      //
      // All additive: four new tables and two nullable columns. The three
      // modifier tables have no data to backfill — a modifier that did not
      // exist before this version has no history to preserve.
      await db.execute(_createModifierGroupsSql);
      await db.execute(_createModifierOptionsSql);
      await db.execute(_createProductModifierGroupsSql);
      await db.execute(_createOrderItemModifiersSql);
      await db.execute(_indexOrderItemModifiersItemSql);

      await _addColumnIfMissing(db, 'order_items', 'category_id', 'TEXT');
      await _addColumnIfMissing(db, 'order_items', 'category_name', 'TEXT');
    }

    if (oldVersion < 18) {
      // v18: a product can now offer only SOME of an attached group's
      // options, not automatically all of them — "Topping" stays one
      // reusable group, but a food item and a coffee attached to it can
      // each be scoped to a different subset. Additive: one new table,
      // backfilled below so an existing attachment keeps behaving exactly
      // as it did (every currently-active option) until an admin narrows it.
      await db.execute(_createProductModifierOptionsSql);
      await db.execute(_indexProductModifierOptionsProductSql);
    }

    if (oldVersion < 19) {
      // v19: PB1 (Pajak Restoran, what the old flat "tax" already was) and
      // Service Charge become two independently configurable charges. All
      // additive, and none of it needs a backfill below: `pb1_rate` /
      // `service_charge_rate` stay NULL-by-absence on a pre-v19 row — the
      // exact PB1 rate in effect back then is genuinely unrecoverable if
      // the store's rate ever changed, the same reasoning that leaves
      // `order_items.category_id` NULL for an orphaned pre-migration row
      // rather than guessing. `service_charge_amount`'s `DEFAULT 0` is not
      // a guess for those same old rows — it is a fact, since the feature
      // did not exist yet, the historical service charge was genuinely
      // zero. `orders.tax` keeps its column name; its MEANING narrows to
      // "PB1 amount" without a rename, the same call made for
      // `products.tax_rate`.
      await _addColumnIfMissing(db, 'orders', 'pb1_rate', 'REAL');
      await _addColumnIfMissing(db, 'orders', 'service_charge_rate', 'REAL');
      await _addColumnIfMissing(
        db,
        'orders',
        'service_charge_amount',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }

    if (oldVersion < 20) {
      // Existing option scopes remain unchanged; no historical defaults guessed.
      await _addColumnIfMissing(
        db,
        'product_modifier_options',
        'is_default',
        'INTEGER NOT NULL DEFAULT 0',
      );
    }

    if (oldVersion < 21) {
      // v21: a table can be deactivated per outlet — Manager/Owner floor-plan
      // configuration is now real CRUD (add/edit/deactivate), not the fixed
      // seed the app shipped with. DEFAULT 1 needs no backfill: every table
      // that already exists was already visible on the board, so an
      // upgrading install's floor plan looks exactly as it did before.
      await _addColumnIfMissing(
        db,
        'tables',
        'active',
        'INTEGER NOT NULL DEFAULT 1',
      );
    }

    if (oldVersion < 22) {
      // v22: where each synced entity's cursor has got to. Empty on an
      // upgrading install, which is correct — a device that has never synced
      // is at 0 for everything and pulls the catalogue in full the first time.
      await _createSyncStateTable(db);
    }

    if (oldVersion < 23) {
      // v23: staff credentials can now arrive from the server as a bcrypt hash,
      // so a cashier signs in offline against something that is not readable
      // from the SQLite file.
      //
      // BOTH columns survive, and that is the whole point. `pin` was NOT NULL
      // and holds every existing account's plain-text PIN; dropping it — or
      // requiring a hash — would lock out every cashier on a device that has
      // not synced yet, which is exactly the till that most needs to keep
      // working. So: `pin` becomes nullable for accounts that arrive hashed,
      // `pin_hash` is added for them, and verification tries the hash first and
      // falls back to the legacy plain text. A device converges on hash-only as
      // its staff sync down, without a moment where nobody can sign in.
      //
      // An added column, NOT a table rebuild. `pin` keeps its NOT NULL and a
      // synced account stores '' there — a value no real PIN can take, since
      // PINs are 4-6 digits. Rebuilding to make `pin` nullable was tried first
      // and is the wrong trade: it has to DROP and recreate `employees`, which
      // depends on the table already existing at that point in the chain, and
      // this chain is walked from many different starting versions. An additive
      // column has no such ordering assumption.
      //
      // Guarded on the table existing at all, because it does not always: the
      // modifier tests build a partial v19/v20 schema with no `employees` in
      // it, and a real v1 install only gets one at v8. Nothing to widen is not
      // an error.
      if (await _tableExists(db, 'employees')) {
        await _addColumnIfMissing(db, 'employees', 'pin_hash', 'TEXT');
      }
    }

    if (oldVersion < 24) {
      // v24: a per-register receipt number, and the outbox that Phase 5 fills.
      // Both are additive and apply to every store, demo included.
      if (await _tableExists(db, 'orders')) {
        await _addColumnIfMissing(db, 'orders', 'number_seq', 'INTEGER');
      }
      await _createOutboxTable(db);

      // …and, ONLY in a connected store, a one-time purge. See
      // [_purgeAdoptedConnectedStore] for why this exists and why the demo
      // store must never reach it.
      if (_connectedScope != null) {
        await _purgeAdoptedConnectedStore(db);
      }
    }

    if (oldVersion < 25) {
      // v25: the v2 sync contract. Outbox entries become snapshots at a
      // revision, refused rows get somewhere to go instead of being deleted,
      // and every sale records its business day and the server clock offset
      // it was made with. All additive, every store: an entry a v24 build
      // queued keeps its place and is snapshotted before its first v2 push,
      // and a sale written before today gets its business day frozen then.
      await _createOutboxTable(db);
      await _addColumnIfMissing(db, '_outbox', 'revision', 'INTEGER');
      await _addColumnIfMissing(db, '_outbox', 'payload', 'TEXT');
      await db.execute(_pushRevisionsDdl);
      await db.execute(_deadLetterDdl);
      await db.execute(_syncMetaDdl);
      if (await _tableExists(db, 'orders')) {
        await _addColumnIfMissing(db, 'orders', 'business_date', 'TEXT');
        await _addColumnIfMissing(
          db,
          'orders',
          'server_time_delta_ms',
          'INTEGER',
        );
      }
    }

    if (oldVersion < 26) {
      // v26: the server stock ledger (Fase 5). Additive, every store. The demo
      // never fills these; an activated till writes them as it pulls snapshots
      // and has its movements acknowledged.
      if (await _tableExists(db, 'outlet_stock')) {
        await _addColumnIfMissing(db, 'outlet_stock', 'server_qty', 'INTEGER');
        await _addColumnIfMissing(db, 'outlet_stock', 'server_seq', 'INTEGER');
      }
      if (await _tableExists(db, 'stock_movements')) {
        await _addColumnIfMissing(
          db,
          'stock_movements',
          'counted_qty',
          'INTEGER',
        );
        await _addColumnIfMissing(
          db,
          'stock_movements',
          'basis_seq',
          'INTEGER',
        );
        await _addColumnIfMissing(
          db,
          'stock_movements',
          'server_seq',
          'INTEGER',
        );
        await _addColumnIfMissing(
          db,
          'stock_movements',
          'origin',
          "TEXT NOT NULL DEFAULT 'device'",
        );
      }
    }

    if (oldVersion < 27) {
      if (await _tableExists(db, 'promos')) {
        await _addColumnIfMissing(
          db,
          'promos',
          'all_outlets',
          'INTEGER NOT NULL DEFAULT 1',
        );
      }
      if (await _tableExists(db, 'tables')) {
        for (final column in ['server_seq', 'pos_x', 'pos_y']) {
          await _addColumnIfMissing(db, 'tables', column, 'INTEGER');
        }
        await _addColumnIfMissing(db, 'tables', 'server_status', 'TEXT');
        await _addColumnIfMissing(
          db,
          'tables',
          'contested',
          'INTEGER NOT NULL DEFAULT 0',
        );
      }
      await db.execute(_promoOutletsDdl);
      await db.execute(_tableStatusEventsDdl);
      await db.execute(_tableStatusSequenceIndex);
    }

    if (oldVersion < 28) {
      await db.execute(_tillStateDdl);
      await db.execute(_tillOpenDdl);
      await db.execute(_remoteOrdersDdl);
      if (await _tableExists(db, 'stock_movements')) {
        await _addColumnIfMissing(db, 'stock_movements', 'order_id', 'TEXT');
      }
    }

    if (oldVersion < 29) {
      // v29: manager-mediated recovery. Existing queue rows and till state are
      // preserved; the new identifiers only annotate evidence received from
      // the server after a forced takeover.
      await _addColumnIfMissing(db, '_dead_letter', 'recovery_id', 'TEXT');
      await _addColumnIfMissing(db, '_till_sessions', 'recovery_id', 'TEXT');
      await _addColumnIfMissing(
        db,
        '_till_sessions',
        'recovery_detected_at',
        'INTEGER',
      );
    }

    if (oldVersion < 30) {
      // v30 (paritas F1): transaction history gains periods, scopes and
      // filters, and the report screens gain a server cache.
      //
      // Additive for everything that holds money or owes the server work —
      // `_outbox`, `_dead_letter`, `_till_sessions`, `orders` and the stock
      // ledger are not touched at all. The one table REBUILT is
      // `_remote_orders`, and only because its primary key has to gain the
      // viewer: a cache keyed by receipt alone let a manager's wider fetch
      // overwrite a cashier's row. Its rows are copied across rather than
      // dropped, and every one of them is re-fetchable from the server anyway
      // — it is a read cache, never a source of truth.
      await _rebuildRemoteOrders(db);
      await db.execute(_remoteHistoryMetaDdl);
      await db.execute(_remoteReportsDdl);
    }

    if (oldVersion < 31) {
      await db.execute(_brandsDdl);
      await db.execute(_customersDdl);
      await _addColumnIfMissing(db, 'products', 'brand_id', 'TEXT');
      await _addColumnIfMissing(db, 'orders', 'customer_id', 'TEXT');
      await _addColumnIfMissing(db, 'order_items', 'brand_id', 'TEXT');
    }
    if (oldVersion < 32) {
      for (final ddl in _f3MasterDdl) {
        await db.execute(ddl);
      }
      await _addColumnIfMissing(db, 'employees', 'role_id', 'TEXT');
      for (final entry in _f3OrderColumns.entries) {
        await _addColumnIfMissing(db, 'orders', entry.key, entry.value);
      }
      for (final entry in _f3OrderItemColumns.entries) {
        await _addColumnIfMissing(db, 'order_items', entry.key, entry.value);
      }
    }
    if (oldVersion < 33) {
      // v33 (paritas F4): saved bills, kitchen dispatches and table
      // seatings. Additive: every existing receipt stays exactly the receipt
      // it was (bill_id NULL), and the queue, dead letters and ledger rows
      // are untouched — last_queued_at is NULL on an entry queued before,
      // which the stock barrier reads as its queued_at.
      for (final ddl in _f4Ddl) {
        await db.execute(ddl);
      }
      for (final table in _f4Columns.entries) {
        if (!await _tableExists(db, table.key)) continue;
        for (final column in table.value.entries) {
          await _addColumnIfMissing(db, table.key, column.key, column.value);
        }
      }
    }

    // ---- Deferred data steps -------------------------------------------
    //
    // Everything above this line changes the SCHEMA only. Everything below
    // WRITES ROWS, and every writer here builds them from today's models — so
    // each one must run against the finished schema, never mid-chain.
    //
    // This is the rule the v6 step learned the hard way and the v12 step then
    // broke again: `growFloorPlan` inserts `RestaurantTable.toMap()`, which
    // grew an `outlet_id` in v15, so from a v1 install it ran three versions
    // before that column existed and failed with "table tables has no column
    // named outlet_id" — taking the whole migration with it.
    //
    // Order matters: rows have to exist before they can be filed under a
    // branch, so the seeders come first and the outlet scoping comes last.
    if (oldVersion < 16) {
      // Before `backfillEmptyOrders`, not after. That step seeds a demo month
      // and then calls `applyOutletScoping`, which files those orders under a
      // till — so the tills have to exist by the time it runs, or a v1 install
      // ends up with a demo whose orders name no register while a fresh
      // install's do. The two paths are required to produce identical data.
      //
      // Safe this early: `seedPosRegisters` reads `outlets`, and the v13 block
      // above has already created and seeded that table.
      await seedPosRegisters(db);
    }
    if (oldVersion < 17) {
      // Pure seeder, same shape as `seedPosRegisters` above — reads
      // `products`, has no dependency on outlet scoping, so it can sit
      // anywhere in this cluster.
      await seedModifiers(db);
    }
    if (oldVersion < 18) {
      // After seedModifiers (and after any v17 product_modifier_groups an
      // older install already had): this reads that table, so an install
      // upgrading straight from v1 needs it populated first.
      await backfillProductModifierOptionScope(db);
    }
    if (oldVersion < 12) {
      // v12: the demo grew from a warung into a restaurant — a real floor
      // plan and a month of trading instead of eight tables and a quiet week.
      await growFloorPlan(db);
      await regrowSeedOrders(db);
    }
    if (oldVersion < 6) await backfillEmptyOrders(db);
    // After backfillEmptyOrders, not before: an install that just got its
    // first order_items rows seeded above needs those SAME rows backfilled
    // too, not just whatever pre-dated this version.
    if (oldVersion < 17) await backfillOrderItemCategory(db);
    if (oldVersion < 14) await seedOutletStock(db);
    if (oldVersion < 15) {
      // Note what is NOT called here: `distributeSeedOrdersAcrossOutlets`.
      // An upgrading install's sales are real and all happened at the one shop
      // it had, so they are filed under the first outlet. Splitting them 60/40
      // across two seeded branches would invent a history the owner never had
      // — and they would notice, because yesterday's totals would move.
      //
      // A fresh seed reaches the same steps through `applyOutletScoping`,
      // which does distribute, because there the rows are fabricated anyway.
      await assignLegacyRowsToFirstOutlet(db);
      await assignLegacyTablesToFirstOutlet(db);
      await seedFloorPlansForOtherOutlets(db);
      await realignSeedOrderTables(db);
      await backfillStockMovementOutlets(db);
    }
    // v16 writes nothing else, and the two things it deliberately does NOT do
    // are the same refusal to invent a till nobody stood at:
    //
    // `distributeSeedOrdersAcrossRegisters` is not called for an upgrade — the
    // reason v15 does not distribute its orders across outlets either. An
    // upgrading install's sales are real and were rung up before tills were
    // modelled; a NULL `pos_id` reads honestly as that, where a stamped one
    // would be a name on history nobody can check. A fresh seed reaches that
    // step through `applyOutletScoping`, where the rows are fabricated anyway.
    //
    // OPEN shifts are not backfilled onto a register. A session that is still
    // running keeps `pos_id` NULL and stays sellable exactly as it was; its
    // owner adopts it again at sign-in (see `SettingsNotifier`'s session
    // resolution) and closes it normally, after which everything is
    // register-bound. The alternatives were both worse: guessing a till, or
    // force-closing a drawer against a count nobody made.
  }

  /// Gives every branch at least one till, and the first branch two.
  ///
  /// Two at the first branch on purpose. One register per outlet would
  /// demonstrate nothing — it is indistinguishable from the implicit single
  /// till the app had before — and every bug in per-register scoping only
  /// appears once there is a second register for state to leak between. The
  /// pair is also the product point in one screen: "Kasir 1" runs the floor
  /// plan, "Takeaway" does not, and they sit in the same shop.
  ///
  /// Guarded on the table being empty, so a business that has already named
  /// its own tills never has these appear underneath them.
  @visibleForTesting
  Future<void> seedPosRegisters(Database db) async {
    final existing =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM pos_registers'),
        ) ??
        0;
    if (existing > 0) return;

    final outlets = await db.query(
      'outlets',
      columns: ['id'],
      orderBy: 'sort_order ASC, name ASC',
    );
    if (outlets.isEmpty) return;

    final batch = db.batch();
    for (var i = 0; i < outlets.length; i++) {
      final outletId = outlets[i]['id'] as String;
      batch.insert('pos_registers', {
        'id': '${outletId}_pos1',
        'outlet_id': outletId,
        'name': 'Kasir 1',
        'table_service': 1,
        'active': 1,
        'sort_order': 0,
      });
      if (i == 0) {
        batch.insert('pos_registers', {
          'id': '${outletId}_pos2',
          'outlet_id': outletId,
          'name': 'Takeaway',
          // The whole reason this setting is per-till: a counter that hands
          // food over has no table to seat anyone at, and asking is a step
          // with no answer.
          'table_service': 0,
          'active': 1,
          'sort_order': 1,
        });
      }
    }
    await batch.commit(noResult: true);
  }

  /// Spreads the demo's month of trading across the seeded tills.
  ///
  /// Seeding paths only, never a real history — see the note in the v16
  /// deferred block for why an upgrading install is left alone.
  ///
  /// Each order lands on a till belonging to the branch that already owns it,
  /// so the two scopings never contradict each other: an order filed under
  /// Kemang cannot end up on a Bintaro register. Split by rowid, which is
  /// deterministic — "Reset demo data" has to produce the same restaurant
  /// every time.
  ///
  /// No `pos_session_id` is written. A session is live state with a drawer
  /// count attached, and fabricating closed ones would put variances on staff
  /// records for shifts nobody worked.
  @visibleForTesting
  Future<void> distributeSeedOrdersAcrossRegisters(Database db) async {
    final registers = await db.query(
      'pos_registers',
      columns: ['id', 'name', 'outlet_id'],
      where: 'active = 1',
      orderBy: 'outlet_id ASC, sort_order ASC, name ASC',
    );
    if (registers.isEmpty) return;

    final byOutlet = <String, List<Map<String, Object?>>>{};
    for (final r in registers) {
      (byOutlet[r['outlet_id'] as String] ??= []).add(r);
    }

    for (final entry in byOutlet.entries) {
      final tills = entry.value;
      for (var i = 0; i < tills.length; i++) {
        await db.rawUpdate(
          'UPDATE orders SET pos_id = ?, pos_name = ? '
          'WHERE outlet_id = ? AND (rowid % ?) = ?',
          [tills[i]['id'], tills[i]['name'], entry.key, tills.length, i],
        );
      }
    }
  }

  /// Files tables that predate outlets under the first branch.
  @visibleForTesting
  Future<void> assignLegacyTablesToFirstOutlet(Database db) async {
    final rows = await db.query(
      'outlets',
      columns: ['id'],
      orderBy: 'sort_order ASC, name ASC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    await db.update('tables', {
      'outlet_id': rows.first['id'],
    }, where: 'outlet_id IS NULL');
  }

  /// Gives every branch after the first its own, smaller floor.
  ///
  /// Smaller on purpose: branches are not copies of each other, and a second
  /// board identical to the first is the tell that the feature is a filter
  /// rather than a real separation.
  ///
  /// Guarded per outlet on having no tables, so a business that has drawn its
  /// own floor plan never has these appear underneath it.
  @visibleForTesting
  Future<void> seedFloorPlansForOtherOutlets(Database db) async {
    final outlets = await db.query(
      'outlets',
      columns: ['id'],
      orderBy: 'sort_order ASC, name ASC',
    );
    if (outlets.length < 2) return;

    for (var i = 1; i < outlets.length; i++) {
      final outletId = outlets[i]['id'] as String;
      final existing =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM tables WHERE outlet_id = ?',
              [outletId],
            ),
          ) ??
          0;
      if (existing > 0) continue;

      final batch = db.batch();
      // Twelve covers over two floors: a real second branch, visibly not a
      // duplicate of the thirty-one at the first.
      for (var n = 1; n <= 12; n++) {
        batch.insert('tables', {
          'id': '$outletId-t$n',
          'name': 'Meja $n',
          'capacity': n <= 6 ? 2 : (n <= 10 ? 4 : 8),
          'status': TableStatus.available.wire,
          'floor': n <= 8 ? 'floor_1' : 'floor_2',
          'sort_order': n,
          'outlet_id': outletId,
        });
      }
      await batch.commit(noResult: true);
    }
  }

  /// Moves seeded dine-in orders onto a table their own branch actually has.
  ///
  /// The demo's month of trading is split across branches by rowid, which
  /// knows nothing about tables — so before this ran, a Kemang order pointed
  /// at a Bintaro table and the two boards disagreed with the order history.
  ///
  /// Only touches orders whose table belongs to a DIFFERENT outlet, so a real
  /// sale, which was always rung up at its own branch, is never rewritten.
  /// The table name is a snapshot on the order and is rewritten with the id —
  /// leaving the old name would make a receipt name a table in another city.
  @visibleForTesting
  Future<void> realignSeedOrderTables(Database db) async {
    final mismatched = await db.rawQuery(
      'SELECT o.id AS order_id, o.outlet_id AS outlet_id, o.status AS status '
      'FROM orders o JOIN tables t ON t.id = o.table_id '
      'WHERE o.outlet_id IS NOT NULL AND t.outlet_id IS NOT NULL '
      '  AND o.outlet_id != t.outlet_id '
      'ORDER BY o.rowid',
    );
    if (mismatched.isEmpty) return;

    final byOutlet = <String, List<Map<String, Object?>>>{};
    for (final t in await db.query(
      'tables',
      columns: ['id', 'name', 'outlet_id'],
      orderBy: 'sort_order ASC, name ASC',
    )) {
      final outletId = t['outlet_id'] as String?;
      if (outletId != null) (byOutlet[outletId] ??= []).add(t);
    }

    final occupy = <String>{};
    final batch = db.batch();
    for (var i = 0; i < mismatched.length; i++) {
      final row = mismatched[i];
      final tables = byOutlet[row['outlet_id'] as String];
      if (tables == null || tables.isEmpty) continue;
      final table = tables[i % tables.length];
      batch.update(
        'orders',
        {'table_id': table['id'], 'table_name': table['name']},
        where: 'id = ?',
        whereArgs: [row['order_id']],
      );
      // A table holding food that is still coming must not read as free.
      if (!OrderStatusX.fromWire(row['status'] as String).isTerminal) {
        occupy.add(table['id'] as String);
      }
    }
    await batch.commit(noResult: true);
    // Occupy is derived below rather than from `occupy`, which only knows
    // about the orders that moved.
    occupy.clear();

    // Re-derive the whole board. Moving an order to another branch leaves the
    // table it used to sit at marked occupied with nothing on it, and a board
    // showing covers that do not exist is the failure the status is for.
    //
    // Safe to do wholesale: this only runs when an order pointed at another
    // branch's table, which cannot happen to a real sale — those were always
    // rung up where they were served.
    final nonTerminal = OrderStatus.values.where((s) => !s.isTerminal).toList();
    final placeholders = nonTerminal.map((_) => '?').join(', ');
    final held = {
      for (final r in await db.rawQuery(
        'SELECT DISTINCT table_id FROM orders '
        'WHERE table_id IS NOT NULL AND status IN ($placeholders)',
        [for (final st in nonTerminal) st.wire],
      ))
        r['table_id'] as String,
    };

    final rebuild = db.batch();
    rebuild.rawUpdate("UPDATE tables SET status = ? WHERE status = ?", [
      TableStatus.available.wire,
      TableStatus.occupied.wire,
    ]);
    for (final id in held) {
      rebuild.update(
        'tables',
        {'status': TableStatus.occupied.wire},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    await rebuild.commit(noResult: true);
  }

  /// Adds a column only when the table does not already have it.
  ///
  /// An upgrade step cannot assume the table it is altering is old. A v1
  /// install runs the whole chain in order, and by the time a later step is
  /// reached the earlier step may have CREATEd the table from today's schema —
  /// which already includes the column. A bare `ALTER TABLE ADD COLUMN` then
  /// fails with "duplicate column name" and takes the entire migration with
  /// it, on exactly the oldest installs that can least afford it.
  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String type,
  ) async {
    // Some repository migration fixtures intentionally contain only the
    // subsystem under test. A later additive migration must leave those
    // partial legacy stores usable instead of issuing ALTER TABLE on a table
    // that was never part of the fixture.
    if (!await _tableExists(db, table)) return;
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    if (columns.any((c) => c['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  /// Whether [table] exists yet.
  ///
  /// The chain is walked from many starting versions, and a table only exists
  /// from the step that created it onward — so a later step widening it has to
  /// ask rather than assume.
  Future<bool> _tableExists(Database db, String table) async {
    final rows = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      [table],
    );
    return rows.isNotEmpty;
  }

  /// The branches the business trades from.
  ///
  /// [active] rather than a delete, for the same reason employees have it: a
  /// closed branch still has years of sales pointing at it, and orders carry
  /// the name as a snapshot so a reprint stays truthful after a rename.
  static const String _createOutletsSql = '''
    CREATE TABLE IF NOT EXISTS outlets (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      address TEXT,
      active INTEGER NOT NULL DEFAULT 1,
      sort_order INTEGER NOT NULL DEFAULT 0
    )
  ''';

  /// The tills each branch trades from.
  ///
  /// [table_service] is the operational setting that makes this a row rather
  /// than a count: one till can run the floor plan while the one beside it
  /// takes takeaway orders, and the sell screen reads whichever one the
  /// cashier is signed on to.
  ///
  /// No foreign key on `outlet_id`, matching `outlet_stock` and unlike
  /// `product_variants`: a register is read on the path into a sale, and an FK
  /// failure there would block a till over a bookkeeping row. The management
  /// screen refuses to delete an outlet that still has sales, which is the
  /// gate that actually matters.
  static const String _createPosRegistersSql = '''
    CREATE TABLE IF NOT EXISTS pos_registers (
      id TEXT PRIMARY KEY,
      outlet_id TEXT NOT NULL,
      name TEXT NOT NULL,
      -- Whether this till runs the floor-plan flow. Per register, not per
      -- store: a restaurant can seat guests at one counter and hand food over
      -- at the next.
      table_service INTEGER NOT NULL DEFAULT 1,
      active INTEGER NOT NULL DEFAULT 1,
      sort_order INTEGER NOT NULL DEFAULT 0
    )
  ''';

  /// One open session per till, enforced by the database rather than by a
  /// check in the UI.
  ///
  /// A UI check loses the race between two cashiers tapping Open at the same
  /// moment, and the loser gets a second drawer on a till that already has
  /// one — two expected balances for one physical cash box, which is
  /// unreconcilable after the fact.
  ///
  /// Partial on `pos_id IS NOT NULL` so shifts opened before v16 (which have
  /// no register) are exempt: several of those may legitimately be open at
  /// once, and the index must not refuse to be created on an install that has
  /// them.
  static const String _indexOpenSessionPerRegisterSql =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_shifts_open_pos '
      'ON shifts(pos_id) WHERE closed_at IS NULL AND pos_id IS NOT NULL';

  /// A reusable set of choices a product can offer on top of its variant —
  /// spice level, toppings, sugar level, ice level.
  static const String _createModifierGroupsSql = '''
    CREATE TABLE IF NOT EXISTS modifier_groups (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      selection_type TEXT NOT NULL DEFAULT 'single',
      required INTEGER NOT NULL DEFAULT 0,
      -- NULL = no upper bound. Only meaningful when selection_type is
      -- 'multiple' — a single group is implicitly capped at one.
      max_select INTEGER,
      sort_order INTEGER NOT NULL DEFAULT 0,
      active INTEGER NOT NULL DEFAULT 1
    )
  ''';

  /// One choice within a group — "Extra Spicy", "Boba". `price_delta` is
  /// kept non-negative by the form that writes it (unlike
  /// `product_variants.price_delta`, which genuinely needs negative values).
  static const String _createModifierOptionsSql = '''
    CREATE TABLE IF NOT EXISTS modifier_options (
      id TEXT PRIMARY KEY,
      group_id TEXT NOT NULL,
      name TEXT NOT NULL,
      price_delta INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0,
      active INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY (group_id) REFERENCES modifier_groups(id) ON DELETE CASCADE
    )
  ''';

  /// Which groups a product offers — reusable, many-to-many. A group like
  /// "Toppings" is defined once and attached to every coffee on the menu.
  static const String _createProductModifierGroupsSql = '''
    CREATE TABLE IF NOT EXISTS product_modifier_groups (
      product_id TEXT NOT NULL,
      group_id TEXT NOT NULL,
      PRIMARY KEY (product_id, group_id),
      FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
      FOREIGN KEY (group_id) REFERENCES modifier_groups(id) ON DELETE CASCADE
    )
  ''';

  /// Which of an attached group's options a product actually offers — a
  /// further narrowing UNDER `product_modifier_groups`, added in v18 so
  /// "Topping" stays one reusable group while a food item and a coffee
  /// attached to it can each show a different subset (and two products can
  /// offer a different NUMBER of "Level Pedas" choices for the same reason).
  /// Keyed by option id alone (already unique to one group), not by
  /// group+option — a product either offers a given option or it does not.
  static const String _createProductModifierOptionsSql = '''
    CREATE TABLE IF NOT EXISTS product_modifier_options (
      product_id TEXT NOT NULL,
      option_id TEXT NOT NULL,
      is_default INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (product_id, option_id),
      FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
      FOREIGN KEY (option_id) REFERENCES modifier_options(id) ON DELETE CASCADE
    )
  ''';

  static const String _indexProductModifierOptionsProductSql =
      'CREATE INDEX IF NOT EXISTS idx_product_modifier_options_product '
      'ON product_modifier_options(product_id)';

  /// The modifiers actually picked on one order line — a snapshot, not a
  /// reference. SENGAJA tanpa FK ke modifier_groups/modifier_options,
  /// matching outlet_stock/pos_registers: this table is written inside the
  /// checkout transaction, and an FK failure there would abort a customer's
  /// sale over a catalogue row. The only enforced FK is to order_items
  /// itself, same as order_items -> orders.
  static const String _createOrderItemModifiersSql = '''
    CREATE TABLE IF NOT EXISTS order_item_modifiers (
      id TEXT PRIMARY KEY,
      order_item_id TEXT NOT NULL,
      group_name TEXT NOT NULL,
      option_name TEXT NOT NULL,
      price_delta INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (order_item_id) REFERENCES order_items(id) ON DELETE CASCADE
    )
  ''';

  static const String _indexOrderItemModifiersItemSql =
      'CREATE INDEX IF NOT EXISTS idx_order_item_modifiers_item '
      'ON order_item_modifiers(order_item_id)';

  /// Gives the demo a small chain, so the manager screen is never an empty
  /// list with no way to understand what it wants — and so a prospective
  /// client can see the thing they asked about actually working.
  ///
  /// Two branches, not one: a single row would demonstrate nothing, and every
  /// bug in per-outlet scoping only appears once there is a second outlet for
  /// data to leak between.
  ///
  /// Guarded on the table being empty, so a business that has already named
  /// its own branches never has these appended underneath them.
  @visibleForTesting
  Future<void> seedOutlets(Database db) async {
    final existing =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM outlets'),
        ) ??
        0;
    if (existing > 0) return;

    const seeds = [
      ('outlet-1', 'Bintaro', 'Jl. Bintaro Utama 9, Tangerang Selatan', 0),
      ('outlet-2', 'Kemang', 'Jl. Kemang Raya 12, Jakarta Selatan', 1),
    ];
    final batch = db.batch();
    for (final (id, name, address, order) in seeds) {
      batch.insert('outlets', {
        'id': id,
        'name': name,
        'address': address,
        'active': 1,
        'sort_order': order,
      });
    }
    await batch.commit(noResult: true);
  }

  /// Files everything that existed before outlets under the first one.
  ///
  /// An upgrading install has a real history that happened somewhere, and
  /// leaving it null would drop it out of every per-outlet total — the numbers
  /// would silently stop matching the numbers the owner saw yesterday.
  @visibleForTesting
  Future<void> assignLegacyRowsToFirstOutlet(Database db) async {
    final rows = await db.query(
      'outlets',
      columns: ['id', 'name'],
      where: 'active = 1',
      orderBy: 'sort_order ASC, name ASC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    await db.update('orders', {
      'outlet_id': rows.first['id'],
      'outlet_name': rows.first['name'],
    }, where: 'outlet_id IS NULL');
  }

  /// On-hand count per product PER OUTLET.
  ///
  /// `products.stock` stays in the schema as the catalogue's opening count —
  /// the number a product is created with, before any branch has counted it —
  /// but it is no longer the truth about any shelf. Every read goes through
  /// this table, falling back to the catalogue count only for a branch that
  /// has never seen the item, so adding a product does not make it invisible
  /// everywhere until someone books it in.
  ///
  /// No foreign keys, deliberately, unlike `product_variants`: this table is
  /// written from inside the sale transaction, and an FK failure there would
  /// abort a customer's order over a bookkeeping row.
  static const String _createOutletStockSql = '''
    CREATE TABLE IF NOT EXISTS outlet_stock (
      outlet_id TEXT NOT NULL,
      product_id TEXT NOT NULL,
      stock INTEGER NOT NULL,
      -- The server's count and the projection sequence it was read at (v26).
      -- NULL until an activated till pulls one; `stock` is then derived as
      -- server_qty plus this till's movements the snapshot does not include.
      server_qty INTEGER,
      server_seq INTEGER,
      PRIMARY KEY (outlet_id, product_id)
    )
  ''';

  /// Gives every branch its own opening shelf.
  ///
  /// The first outlet inherits the catalogue count exactly — on a real install
  /// upgrading into this, that history is literally the one shop's stock, and
  /// changing it would be inventing numbers. Later branches get a fraction of
  /// it, because two branches holding identical counts of all 26 products is
  /// the tell that a demo is fabricated, and because a visible difference is
  /// the whole point being demonstrated.
  ///
  /// Per outlet, guarded on that outlet having no rows yet, so re-running this
  /// never overwrites a count somebody has actually adjusted.
  @visibleForTesting
  Future<void> seedOutletStock(Database db) async {
    final outlets = await db.query(
      'outlets',
      columns: ['id'],
      orderBy: 'sort_order ASC, name ASC',
    );
    if (outlets.isEmpty) return;

    final products = await db.query(
      'products',
      columns: ['id', 'stock'],
      where: 'stock IS NOT NULL',
    );
    if (products.isEmpty) return;

    // Index 0 keeps the catalogue count; the rest are scaled down and never
    // to zero, so a seeded branch never opens sold out.
    const factors = [1.0, 0.7, 0.55];

    for (var i = 0; i < outlets.length; i++) {
      final outletId = outlets[i]['id'] as String;
      final existing =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM outlet_stock WHERE outlet_id = ?',
              [outletId],
            ),
          ) ??
          0;
      if (existing > 0) continue;

      final factor = factors[i < factors.length ? i : factors.length - 1];
      final batch = db.batch();
      for (final p in products) {
        final base = (p['stock'] as num).toInt();
        // A product the catalogue already has none of stays at none — scaling
        // it up to one would invent stock. Everything else keeps at least one,
        // so a seeded branch never opens sold out.
        final scaled = base <= 0
            ? base
            : (base * factor).round().clamp(1, base);
        batch.insert('outlet_stock', {
          'outlet_id': outletId,
          'product_id': p['id'],
          'stock': i == 0 ? base : scaled,
        });
      }
      await batch.commit(noResult: true);
    }
  }

  /// Files ledger rows written before outlets existed under the first one.
  ///
  /// Same reasoning as the orders backfill: a movement with no outlet drops
  /// out of every per-branch stock history, and a history with holes in it
  /// cannot settle the argument it exists to settle.
  @visibleForTesting
  Future<void> backfillStockMovementOutlets(Database db) async {
    final rows = await db.query(
      'outlets',
      columns: ['id'],
      orderBy: 'sort_order ASC, name ASC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    await db.update('stock_movements', {
      'outlet_id': rows.first['id'],
    }, where: 'outlet_id IS NULL');
  }

  /// Spreads the demo's month of trading across the seeded branches.
  ///
  /// Only ever called from a seeding path, never on a real history — see
  /// [assignLegacyRowsToFirstOutlet] for that, which files everything under
  /// the one shop it actually happened in.
  ///
  /// A demo where the second branch has no sales demonstrates nothing: the
  /// per-outlet report opens on a column of zeroes, which reads as the feature
  /// being broken rather than as an empty branch. The split is 60/40 by rowid
  /// — deterministic, because "Reset demo data" has to produce the same chain
  /// every time or two screenshots of one install disagree — and uneven,
  /// because two branches with identical takings look fabricated.
  @visibleForTesting
  Future<void> distributeSeedOrdersAcrossOutlets(Database db) async {
    final outlets = await db.query(
      'outlets',
      columns: ['id', 'name'],
      where: 'active = 1',
      orderBy: 'sort_order ASC, name ASC',
    );
    if (outlets.isEmpty) return;
    if (outlets.length == 1) {
      await assignLegacyRowsToFirstOutlet(db);
      return;
    }
    final first = outlets[0];
    final second = outlets[1];
    await db.rawUpdate(
      'UPDATE orders SET outlet_id = ?, outlet_name = ? WHERE (rowid % 5) < 3',
      [first['id'], first['name']],
    );
    await db.rawUpdate(
      'UPDATE orders SET outlet_id = ?, outlet_name = ? WHERE (rowid % 5) >= 3',
      [second['id'], second['name']],
    );
  }

  /// Gives an install with no sales at all a demo history (the old v6 step).
  ///
  /// Guarded on the table being empty, so a user's own transactions are never
  /// mixed with fabricated ones — and so it does nothing on an install that
  /// v12 has already regrown.
  @visibleForTesting
  Future<void> backfillEmptyOrders(Database db) async {
    final existing =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM orders'),
        ) ??
        0;
    if (existing > 0) return;
    await seedOrders(db);
    await attributeSeedOrdersToStaff(db);
    await applyOutletScoping(db);
    await backfillOrderItemCost(db);
  }

  /// Files freshly seeded demo rows under a branch.
  ///
  /// Shared by the fresh-install seed and the upgrade backfill rather than
  /// spelled out in both. The two paths have to end up with identical data —
  /// that is the rule the whole seeding section is built on — and they have
  /// already drifted once: the outlet steps landed only in the backfill, so a
  /// fresh install produced a floor plan belonging to no branch and the board
  /// came back empty.
  @visibleForTesting
  Future<void> applyOutletScoping(Database db) async {
    await distributeSeedOrdersAcrossOutlets(db);
    await assignLegacyTablesToFirstOutlet(db);
    await seedFloorPlansForOtherOutlets(db);
    await realignSeedOrderTables(db);
    await backfillStockMovementOutlets(db);
    // Last: a till belongs to a branch, so an order has to know its branch
    // before it can be filed under one of that branch's tills.
    await distributeSeedOrdersAcrossRegisters(db);
  }

  /// Adds the tables introduced in v12 without touching the original eight.
  ///
  /// Guarded per id rather than on the table being empty: an install where
  /// someone added their own tables in Settings must keep them, and re-running
  /// must not duplicate anything.
  @visibleForTesting
  Future<void> growFloorPlan(Database db) async {
    final existing = {
      for (final r in await db.query('tables', columns: ['id']))
        r['id'] as String,
    };
    final batch = db.batch();
    var added = 0;
    for (final t in _seedTables()) {
      if (existing.contains(t.id)) continue;
      batch.insert('tables', t.toMap());
      added++;
    }
    if (added == 0) return;
    await batch.commit(noResult: true);
  }

  /// Replaces the original seeded sales with the larger generated history.
  ///
  /// Scoped strictly to `seed_ord_%`, the id prefix only this seeder writes —
  /// a real sale is created with a UUID and is never matched, which is the
  /// whole reason the prefix exists. `order_items` follows via the FK's
  /// `ON DELETE CASCADE`.
  ///
  /// Replace rather than append: the old set was a quiet week of two-person
  /// orders, and leaving it in place would put a visible trough at the end of
  /// every chart. Anyone who voided a seeded order to demo the flow loses that
  /// edit — it is fabricated data, and the alternative is a demo whose own
  /// history contradicts itself.
  ///
  /// No-ops when nothing seeded is present, so an install whose demo data was
  /// already cleared out is left alone.
  @visibleForTesting
  Future<void> regrowSeedOrders(Database db) async {
    // Matched on the id LENGTH, not just the prefix. The original seeder
    // numbered to two digits (`seed_ord_01`); this one numbers to five. An
    // install that reached v12 by way of the v6 step already holds the new
    // history, and re-seeding it would be a second full month of inserts for
    // no change.
    final legacy = Sqflite.firstIntValue(
      await db.rawQuery(
        "SELECT COUNT(*) FROM orders "
        "WHERE id LIKE 'seed_ord_%' AND length(id) < 14",
      ),
    );
    if ((legacy ?? 0) == 0) return;

    await db.delete('orders', where: "id LIKE 'seed_ord_%'");
    await seedOrders(db);
    await attributeSeedOrdersToStaff(db);
    await backfillOrderItemCost(db);

    // Rebuild occupancy from the orders that actually exist now, rather than
    // trusting the statuses left behind by the deleted ones. Derived from
    // every open order, seeded or real, so a table a customer is sitting at
    // right now is not quietly freed by a migration.
    final open = OrderStatus.values.where((s) => !s.isTerminal).toList();
    final placeholders = List.filled(open.length, '?').join(', ');
    await db.rawUpdate(
      '''
      UPDATE tables SET status = CASE WHEN id IN (
        SELECT table_id FROM orders
         WHERE table_id IS NOT NULL AND status IN ($placeholders)
      ) THEN ? ELSE ? END
      ''',
      [
        ...open.map((s) => s.wire),
        TableStatus.occupied.wire,
        TableStatus.available.wire,
      ],
    );
    // Reserved is not derivable from an order — a booking has no row yet.
    await db.update(
      'tables',
      {'status': TableStatus.reserved.wire},
      where:
          'id IN (${_seedReservedTables.map((_) => '?').join(', ')}) '
          'AND status = ?',
      whereArgs: [..._seedReservedTables, TableStatus.available.wire],
    );
  }

  /// Renames the seeded staff wherever their name was written down.
  ///
  /// `orders.cashier_name`, `orders.authorized_by`, `shifts.employee_name` and
  /// `stock_movements.employee_name` are snapshots, not joins — updating the
  /// `employees` row alone would leave yesterday's receipts, shifts and stock
  /// entries signed by someone the staff list no longer contains.
  ///
  /// Every update is scoped to the exact previous name, so a staff member the
  /// user renamed themselves in Settings keeps the name they chose.
  @visibleForTesting
  Future<void> renameSeedStaff(Database db) async {
    for (final (id, from, to) in _seedStaffRenames) {
      await db.update(
        'employees',
        {'name': to},
        where: 'id = ? AND name = ?',
        whereArgs: [id, from],
      );
      await db.update(
        'orders',
        {'cashier_name': to},
        where: 'cashier_id = ? AND cashier_name = ?',
        whereArgs: [id, from],
      );
      // The approver is recorded by name only — there is no `authorized_by_id`
      // to scope against, so the name itself is the key.
      await db.update(
        'orders',
        {'authorized_by': to},
        where: 'authorized_by = ?',
        whereArgs: [from],
      );
      await db.update(
        'shifts',
        {'employee_name': to},
        where: 'employee_id = ? AND employee_name = ?',
        whereArgs: [id, from],
      );
      await db.update(
        'stock_movements',
        {'employee_name': to},
        where: 'employee_id = ? AND employee_name = ?',
        whereArgs: [id, from],
      );
    }
  }

  /// `(employee id, previous name, current name)` for the v11 rename. Kept as
  /// data so the migration and its test read from the same list.
  static const _seedStaffRenames = <(String, String, String)>[
    ('emp_owner', 'Dewi Lestari', 'Farhan Sabili'),
    ('emp_manager', 'Budi Santoso', 'Siwi Wiyono Raharjo'),
    ('emp_kasir_2', 'Andi Wijaya', 'Dani Rycki Dinata'),
  ];

  /// Gives the seeded catalogue a cost of goods.
  ///
  /// Demo figures, not real ones: a per-category ratio of the selling price,
  /// rounded to the nearest 500. Real costs are entered per product in the
  /// form — this exists so the profit report opens with a plausible margin
  /// instead of a column of zeroes, which reads as a broken report.
  ///
  /// Guarded per row on `cost IS NULL`, so a cost the user typed is never
  /// overwritten.
  @visibleForTesting
  Future<void> applySeedCost(Database db) async {
    final rows = await db.query(
      'products',
      columns: ['id', 'price', 'category_id'],
      where: 'cost IS NULL',
    );
    if (rows.isEmpty) return;
    final batch = db.batch();
    for (final r in rows) {
      final ratio = _seedCostRatio[r['category_id'] as String] ?? 0.4;
      final price = (r['price'] as num).toInt();
      final cost = ((price * ratio) / 500).round() * 500;
      batch.update(
        'products',
        {'cost': cost},
        where: 'id = ?',
        whereArgs: [r['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Cost as a share of selling price, per category. Drinks and coffee carry
  /// the fattest margins in a restaurant; cooked food the thinnest.
  static const _seedCostRatio = <String, double>{
    'cat_food': 0.42,
    'cat_drinks': 0.28,
    'cat_snacks': 0.38,
    'cat_dessert': 0.35,
    'cat_coffee': 0.30,
  };

  /// Writes one `opening` row per stock-tracked product.
  ///
  /// Without it the stock ledger opens empty, and a balance with no first
  /// entry cannot be reconciled — every later movement would appear to come
  /// from nowhere.
  @visibleForTesting
  Future<void> seedOpeningStockMovements(Database db) async {
    final existing = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM stock_movements'),
    );
    if ((existing ?? 0) > 0) return;

    final rows = await db.query(
      'products',
      columns: ['id', 'name', 'stock'],
      where: 'stock IS NOT NULL',
      orderBy: 'sort_order ASC',
    );
    final at = DateTime.now()
        .subtract(const Duration(days: 7))
        .millisecondsSinceEpoch;
    final batch = db.batch();
    for (final r in rows) {
      final stock = (r['stock'] as num).toInt();
      // A product that starts at zero has nothing to open with. The row would
      // read "0" against an out-arrow, which explains nothing and pushes the
      // rows that do explain something further down the list.
      if (stock == 0) continue;
      batch.insert('stock_movements', {
        'id': 'sm_open_${r['id']}',
        'product_id': r['id'],
        'product_name': r['name'],
        'delta': stock,
        'balance_after': stock,
        'reason': StockReason.opening.wire,
        'created_at': at,
        'employee_id': 'emp_owner',
        'employee_name': 'Farhan Sabili',
        'note': null,
      });
    }
    await batch.commit(noResult: true);
  }

  /// Copies each product's cost onto the order lines that predate the column.
  ///
  /// An approximation, and knowingly so: it uses today's cost rather than the
  /// cost at the time of sale, which nobody recorded. Applied only to the
  /// seeded history, so the profit report has a full range to draw instead of
  /// a flat line that jumps the moment the first real sale lands.
  @visibleForTesting
  Future<void> backfillOrderItemCost(Database db) async {
    await db.rawUpdate('''
      UPDATE order_items
         SET unit_cost = (
           SELECT p.cost FROM products p WHERE p.id = order_items.product_id
         )
       WHERE unit_cost IS NULL
    ''');
  }

  /// Fills in `category_id`/`category_name` on order lines written before
  /// v17, from whichever product/category rows are still around.
  ///
  /// Two passes rather than one join, because the second depends on the
  /// first: `category_name` is resolved from the `category_id` this same
  /// call just wrote, not from `order_items.product_id` directly. Rows
  /// whose product is already gone by the time this runs stay NULL — that
  /// information genuinely no longer exists, and the report reads a NULL
  /// `category_id` as "Uncategorized" rather than inventing one.
  @visibleForTesting
  Future<void> backfillOrderItemCategory(Database db) async {
    await db.rawUpdate('''
      UPDATE order_items
         SET category_id = (
           SELECT p.category_id FROM products p WHERE p.id = order_items.product_id
         )
       WHERE category_id IS NULL
    ''');
    await db.rawUpdate('''
      UPDATE order_items
         SET category_name = (
           SELECT c.name FROM categories c WHERE c.id = order_items.category_id
         )
       WHERE category_name IS NULL AND category_id IS NOT NULL
    ''');
  }

  /// Adds the owner account to an install that predates the third role.
  ///
  /// Separate from [seedEmployees], which no-ops as soon as anyone exists —
  /// on an upgrade the manager and both cashiers are already there, so that
  /// guard would skip the owner and leave the install with no one who can
  /// reach the catalogue or the reports.
  @visibleForTesting
  Future<void> seedOwner(Database db) async {
    final existing = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM employees WHERE role = ?', [
        EmployeeRole.owner.wire,
      ]),
    );
    if ((existing ?? 0) > 0) return;
    await db.insert(
      'employees',
      // Columns spelled out rather than `Employee.toMap()`. This runs at v10,
      // and the model has grown columns since — `pin_hash` in v23 — so a map
      // built from today's model names a column that does not exist yet at this
      // point in the chain, and takes the whole migration down with it. The
      // deferred section below documents the same trap for `growFloorPlan`;
      // this writer sits too early to move there, so it is pinned to the shape
      // the schema actually has at v10 instead.
      _seedEmployeeRow(
        id: 'emp_owner',
        name: 'Farhan Sabili',
        pin: '9999',
        role: EmployeeRole.owner,
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// One employee row in the shape the schema had when the seeders run.
  ///
  /// Deliberately NOT `Employee.toMap()`: these are called from inside the
  /// migration chain, where the table is whatever version the step created —
  /// never today's.
  static Map<String, Object?> _seedEmployeeRow({
    required String id,
    required String name,
    required String pin,
    required EmployeeRole role,
    int sortOrder = 0,
  }) => {
    'id': id,
    'name': name,
    'pin': pin,
    'role': role.wire,
    'active': 1,
    'sort_order': sortOrder,
  };

  /// Gives the seeded orders real cashiers.
  ///
  /// They shipped attributed to a placeholder `cashier_id` of `'cashier'`,
  /// which made two role features read as broken: the per-cashier breakdown in
  /// the report showed a single fictional "Kasir Demo", and a signed-in cashier
  /// filtering to their own sales saw nothing at all. Rotating them across the
  /// three seeded staff gives both screens something true to show.
  ///
  /// Scoped to the placeholder id so a real sale is never reattributed.
  @visibleForTesting
  Future<void> attributeSeedOrdersToStaff(Database db) async {
    final rows = await db.query(
      'orders',
      columns: ['id'],
      where: 'cashier_id = ?',
      whereArgs: ['cashier'],
      orderBy: 'created_at ASC',
    );
    if (rows.isEmpty) return;
    final batch = db.batch();
    for (var i = 0; i < rows.length; i++) {
      final staff = _seedOrderStaff[i % _seedOrderStaff.length];
      batch.update(
        'orders',
        {'cashier_id': staff.$1, 'cashier_name': staff.$2},
        where: 'id = ?',
        whereArgs: [rows[i]['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Who the seeded sales are attributed to, in rotation. Ids match
  /// [seedEmployees]; the names are copied because `orders.cashier_name` is a
  /// snapshot, not a join.
  static const _seedOrderStaff = <(String, String)>[
    ('emp_kasir_1', 'Siti Rahayu'),
    ('emp_kasir_2', 'Dani Rycki Dinata'),
    ('emp_manager', 'Siwi Wiyono Raharjo'),
  ];

  /// Seeds the staff list.
  ///
  /// The manager keeps PIN 1234 so every existing demo script, screenshot and
  /// the E2E test still sign in unchanged. The two cashiers exist so "who sold
  /// this?" has more than one possible answer, which is the whole point of
  /// per-employee sign-in.
  ///
  /// No-ops when anyone already exists, so it is safe from both `_onCreate`
  /// and the v8 upgrade.
  @visibleForTesting
  Future<void> seedEmployees(Database db) async {
    final existing =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM employees'),
        ) ??
        0;
    if (existing > 0) return;

    // Explicit column maps, not `Employee.toMap()` — see [_seedEmployeeRow].
    // This runs from the v8 migration step, long before v23 added `pin_hash`.
    final batch = db.batch();
    for (final row in [
      _seedEmployeeRow(
        id: 'emp_owner',
        name: 'Farhan Sabili',
        pin: '9999',
        role: EmployeeRole.owner,
      ),
      _seedEmployeeRow(
        id: 'emp_manager',
        name: 'Siwi Wiyono Raharjo',
        pin: '1234',
        role: EmployeeRole.manager,
      ),
      _seedEmployeeRow(
        id: 'emp_kasir_1',
        name: 'Siti Rahayu',
        pin: '2345',
        role: EmployeeRole.cashier,
        sortOrder: 1,
      ),
      _seedEmployeeRow(
        id: 'emp_kasir_2',
        name: 'Dani Rycki Dinata',
        pin: '3456',
        role: EmployeeRole.cashier,
        sortOrder: 2,
      ),
    ]) {
      batch.insert('employees', row);
    }
    await batch.commit(noResult: true);
  }

  /// Gives the packaged seed products an opening stock count.
  ///
  /// Only items a restaurant actually counts are tracked: bottled drinks, snacks,
  /// desserts. Food cooked to order stays NULL, which is the honest modelling
  /// and also demonstrates both states side by side on the sell screen.
  ///
  /// Guarded per row on `stock IS NULL` so re-running never overwrites a count
  /// the user has since corrected.
  @visibleForTesting
  Future<void> applySeedStock(Database db) async {
    final batch = db.batch();
    for (final e in _seedProductStock.entries) {
      batch.update(
        'products',
        {'stock': e.value},
        where: 'id = ? AND stock IS NULL',
        whereArgs: [e.key],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Opening stock per packaged product. Two are deliberately scarce so the
  /// low-stock and out-of-stock states are visible without editing anything.
  static const _seedProductStock = <String, int>{
    'p_es_teh': 60,
    'p_es_jeruk': 42,
    'p_air_mineral': 120,
    'p_lemon_tea': 30,
    'p_soft_drink': 24,
    'p_jus_alpukat': 12,
    'p_kentang': 18,
    'p_pisang_goreng': 9,
    'p_roti_bakar': 14,
    'p_dimsum': 20,
    'p_risol': 4, // low-stock warning
    'p_es_krim': 16,
    'p_pudding': 11,
    'p_brownies': 0, // sold out
    'p_kopi_hitam': 50,
    'p_kopi_susu': 35,
    'p_cappuccino': 28,
    'p_latte': 26,
  };

  /// Photos added in v5 for products that seeded without one. Keyed by product
  /// id → Unsplash photo slug. Also used by the v5 migration to backfill
  /// existing installs (only where `image_url` is still NULL). Keep in sync with
  /// the `imageUrl` values in [_seed]; every slug was HEAD-verified to return
  /// 200 before landing here (dead Unsplash links fail silently in the app).
  static const _seedProductImageBackfill = <String, String>{
    'p_nasi_goreng': '1680674774705-90b4904b3a7f',
    'p_mie_goreng': '1680675494363-75bbf9838a09',
    'p_ayam_geprek': '1696340034876-6245523babfa',
    'p_ayam_goreng': '1569058242253-92a9c755a0ec',
    'p_mie_ayam': '1470324161839-ce2bb6fa6bc3',
    'p_nasi_padang': '1685186114062-68d0cb6b9e86',
    'p_sate_ayam': '1751212352288-d5811798804c',
    'p_lemon_tea': '1656936637945-571e3f0893f9',
    'p_pisang_goreng': '1563336522-c3bd728d3b45',
    'p_roti_bakar': '1631294012419-2d5ee9da5f5c',
    'p_dimsum': '1604632910793-c0601f361b34',
    'p_risol': '1769254870299-338bfd99aabd',
    'p_kopi_hitam': '1514432324607-a09d9b4aefdd',
  };

  /// Icon assigned to each seeded category, also used by the v4 migration to
  /// backfill installs created before categories had an `icon_key`.
  static const _seedCategoryIconKeys = <String, String>{
    'cat_food': 'set_meal',
    'cat_drinks': 'local_drink',
    'cat_snacks': 'fastfood',
    'cat_dessert': 'cake',
    'cat_coffee': 'local_cafe',
  };

  /// Where each synced entity's cursor has got to.
  ///
  /// One row per entity, holding the highest `sync_seq` this device has applied.
  /// The next pull asks for everything above it, so a device that has been off
  /// for a week catches up in pages rather than re-downloading the catalogue.
  ///
  /// Underscore-prefixed because it is device bookkeeping, not business data:
  /// nothing here belongs to the merchant, and nothing here is ever pushed up.
  static const _syncStateDdl = '''
    CREATE TABLE IF NOT EXISTS _sync_state (
      entity TEXT PRIMARY KEY,
      last_seq INTEGER NOT NULL DEFAULT 0,
      synced_at INTEGER
    )
  ''';

  Future<void> _createSyncStateTable(Database db) => db.execute(_syncStateDdl);

  /// Rows this device still owes the server, as snapshots.
  ///
  /// Since v25 each entry is a snapshot at a revision: `payload` is the exact
  /// JSON row sent for `revision`, and the server's acknowledgement names that
  /// revision. An order voided while its sale was still in flight is a newer
  /// revision, so an "accepted" for the older one cannot remove it. `revision`
  /// and `payload` are NULL only on entries a v24 build queued, which stored an
  /// identity alone; the pusher snapshots those before their first send.
  ///
  /// The composite primary key keeps one pending snapshot per row: queueing the
  /// same row again replaces its snapshot rather than adding a second job.
  ///
  /// Device bookkeeping, like [_syncStateDdl]: never synced, never a merchant's
  /// data.
  static const _outboxDdl = '''
    CREATE TABLE IF NOT EXISTS _outbox (
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      queued_at INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      revision INTEGER,
      payload TEXT,
      PRIMARY KEY (entity, entity_id)
    )
  ''';

  Future<void> _createOutboxTable(Database db) => db.execute(_outboxDdl);

  /// The highest push revision ever issued per row (v25).
  ///
  /// Separate from `_outbox` because an acknowledged entry is deleted there,
  /// and the next edit of the same sale still needs a HIGHER revision than the
  /// one the server stored. Never pruned: one small row per sale.
  static const _pushRevisionsDdl = '''
    CREATE TABLE IF NOT EXISTS _push_revisions (
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      PRIMARY KEY (entity, entity_id)
    )
  ''';

  /// Rows the server refused (v25), moved here instead of being deleted.
  ///
  /// The v1 client dropped a sale the server answered 422 for. Every row here
  /// is money a customer paid, kept with the exact payload that was refused and
  /// the server's reason, until someone sends it again.
  static const _deadLetterDdl = '''
    CREATE TABLE IF NOT EXISTS _dead_letter (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      revision INTEGER NOT NULL,
      payload TEXT NOT NULL,
      code TEXT NOT NULL,
      message TEXT,
      details TEXT,
      recovery_id TEXT,
      rejected_at INTEGER NOT NULL
    )
  ''';

  /// Small sync values kept between runs (v25), such as the server clock
  /// offset stamped on every sale.
  static const _syncMetaDdl = '''
    CREATE TABLE IF NOT EXISTS _sync_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''';

  static const _brandsDdl = '''
    CREATE TABLE IF NOT EXISTS brands (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      sort_order INTEGER NOT NULL DEFAULT 0
    )
  ''';

  static const _f3MasterDdl = <String>[
    '''CREATE TABLE IF NOT EXISTS roles (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, system_key TEXT,
      permissions TEXT NOT NULL DEFAULT '', pos_access INTEGER NOT NULL DEFAULT 0,
      backoffice_access INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0
    )''',
    '''CREATE TABLE IF NOT EXISTS business_settings (
      id TEXT PRIMARY KEY, tax_rate_bp INTEGER NOT NULL, tax_mode TEXT NOT NULL,
      service_enabled INTEGER NOT NULL, service_rate_bp INTEGER NOT NULL,
      service_taxable INTEGER NOT NULL, rounding_unit INTEGER NOT NULL,
      rounding_mode TEXT NOT NULL, receipt_logo_url TEXT, receipt_footer TEXT
    )''',
    '''CREATE TABLE IF NOT EXISTS sales_types (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, system_key TEXT,
      uses_table INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1,
      sort_order INTEGER NOT NULL DEFAULT 0
    )''',
    '''CREATE TABLE IF NOT EXISTS payment_methods (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
      system_key TEXT, requires_reference INTEGER NOT NULL DEFAULT 0,
      active INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0
    )''',
    '''CREATE TABLE IF NOT EXISTS payment_groups (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, method_ids TEXT NOT NULL DEFAULT '',
      active INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0
    )''',
    '''CREATE TABLE IF NOT EXISTS discounts (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL, kind TEXT NOT NULL,
      value INTEGER, requires_authorization INTEGER NOT NULL DEFAULT 0,
      active INTEGER NOT NULL DEFAULT 1, sort_order INTEGER NOT NULL DEFAULT 0
    )''',
    '''CREATE TABLE IF NOT EXISTS outlet_settings (
      outlet_id TEXT PRIMARY KEY, tax_rate_bp INTEGER, tax_mode TEXT,
      service_enabled INTEGER, service_rate_bp INTEGER, service_taxable INTEGER,
      rounding_unit INTEGER, rounding_mode TEXT, receipt_header TEXT,
      receipt_footer TEXT, show_address INTEGER NOT NULL DEFAULT 1,
      show_phone INTEGER NOT NULL DEFAULT 1, track_server INTEGER NOT NULL DEFAULT 0,
      default_sales_type_id TEXT, sales_type_ids TEXT, payment_group_id TEXT,
      pricing_model TEXT NOT NULL DEFAULT 'legacy'
    )''',
    '''CREATE TABLE IF NOT EXISTS product_sales_type_prices (
      product_id TEXT NOT NULL, sales_type_id TEXT NOT NULL, price INTEGER NOT NULL,
      PRIMARY KEY (product_id, sales_type_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS outlet_product_sales_type_prices (
      outlet_id TEXT NOT NULL, product_id TEXT NOT NULL, sales_type_id TEXT NOT NULL,
      price INTEGER NOT NULL, PRIMARY KEY (outlet_id, product_id, sales_type_id)
    )''',
  ];

  static const _f3OrderColumns = <String, String>{
    'pricing_version': 'INTEGER',
    'pricing': 'TEXT',
    'tax_included': 'INTEGER NOT NULL DEFAULT 0',
    'rounding_amount': 'INTEGER NOT NULL DEFAULT 0',
    'tz_offset_minutes': 'INTEGER',
    'sales_type_id': 'TEXT',
    'sales_type_name': 'TEXT',
    'payment_method_id': 'TEXT',
    'payment_method_name': 'TEXT',
    'payment_reference': 'TEXT',
    'served_by_id': 'TEXT',
    'served_by_name': 'TEXT',
    'discount_id': 'TEXT',
    'discount_name': 'TEXT',
    'discount_authorized_by_id': 'TEXT',
    'discount_authorized_by_name': 'TEXT',
    'receipt_snapshot': 'TEXT',
  };

  static const _f3OrderItemColumns = <String, String>{
    'custom': 'INTEGER NOT NULL DEFAULT 0',
    'base_price': 'INTEGER',
    'price_source': 'TEXT',
    'tax_rate_bp': 'INTEGER',
    'discount_spec': 'TEXT',
    'line_discount_id': 'TEXT',
    'line_discount_name': 'TEXT',
    'line_discount_authorized_by_id': 'TEXT',
    'line_discount_authorized_by_name': 'TEXT',
    'line_discount': 'INTEGER NOT NULL DEFAULT 0',
    'bill_discount_share': 'INTEGER NOT NULL DEFAULT 0',
    'service_share': 'INTEGER NOT NULL DEFAULT 0',
    'tax_amount': 'INTEGER NOT NULL DEFAULT 0',
    'tax_included': 'INTEGER NOT NULL DEFAULT 0',
    'net_amount': 'INTEGER',
  };

  static const _customersDdl = '''
    CREATE TABLE IF NOT EXISTS customers (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      phone TEXT,
      email TEXT,
      address TEXT,
      note TEXT,
      active INTEGER NOT NULL DEFAULT 1
    )
  ''';

  /// Tables a connected store may hold, children before parents.
  ///
  /// Ordered so a delete never trips a foreign key, rather than relying on
  /// cascades to reach everything.
  static const _connectedStoreTables = <String>[
    'order_item_modifiers',
    'order_items',
    'orders',
    'outlet_product_sales_type_prices',
    'product_sales_type_prices',
    'outlet_settings',
    'payment_groups',
    'payment_methods',
    'discounts',
    'sales_types',
    'shifts',
    'stock_movements',
    'outlet_stock',
    'tables',
    'promos',
    'product_modifier_options',
    'product_modifier_groups',
    'modifier_options',
    'modifier_groups',
    'product_variants',
    'products',
    'brands',
    'categories',
    'customers',
    'employees',
    'business_settings',
    'roles',
    '_sync_state',
  ];

  /// One-time cleanup of a connected store that was populated by adoption.
  ///
  /// Until v24 the app copied the demo store into a connected one on
  /// activation. That produced two rows for every person and every dish,
  /// because the copies kept hand-written ids (`emp_owner`, `p_nasi_goreng`)
  /// while the server sends UUIDs — two id spaces that can never be reconciled,
  /// so the sync's "update by id, else insert" always inserted.
  ///
  /// Emptying is the right repair rather than deleting only the copies:
  /// the adopted rows include a fabricated month of orders, and once Phase 6
  /// starts pushing sales upward those fake orders would land in the merchant's
  /// real books. Cheaper to drop them here than to clean them out of a central
  /// database later.
  ///
  /// Nothing is lost that has anywhere else to be — the server owns the
  /// catalogue and staff, and `_sync_state` is cleared so the next pull fetches
  /// them again in full.
  ///
  /// **The demo store must never reach this.** The caller guards on
  /// `_connectedScope != null`, which is null for `nti_pos.db` and null in
  /// every migration test.
  Future<void> _purgeAdoptedConnectedStore(Database db) async {
    for (final table in _connectedStoreTables) {
      if (await _tableExists(db, table)) {
        await db.delete(table);
      }
    }
  }

  void _createSchemaV2(Batch batch) {
    batch.execute(_promoOutletsDdl);
    batch.execute(_tableStatusEventsDdl);
    batch.execute(_tableStatusSequenceIndex);
    batch.execute(_syncStateDdl);
    batch.execute(_outboxDdl);
    batch.execute(_pushRevisionsDdl);
    batch.execute(_deadLetterDdl);
    batch.execute(_syncMetaDdl);
    batch.execute(_brandsDdl);
    batch.execute(_customersDdl);
    for (final ddl in _f3MasterDdl) {
      batch.execute(ddl);
    }

    batch.execute('''
      CREATE TABLE categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        emoji TEXT NOT NULL DEFAULT '🍽️',
        icon_key TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_popular INTEGER NOT NULL DEFAULT 0
      )
    ''');

    batch.execute('''
      CREATE TABLE products (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        category_id TEXT NOT NULL,
		brand_id TEXT,
        price INTEGER NOT NULL,
        cost INTEGER,
        sku TEXT,
        -- NULL means "not stock-tracked", which is different from 0 ("tracked,
        -- none left"). Kitchen items cooked to order stay NULL.
        stock INTEGER,
        -- NULL means "use the store-wide rate". A literal 0 means this item is
        -- genuinely zero-rated and must ignore the store rate.
        tax_rate REAL,
        description TEXT,
        emoji TEXT NOT NULL DEFAULT '🍽️',
        image_url TEXT,
        icon_key TEXT NOT NULL DEFAULT 'restaurant',
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
      -- Which branch's floor this is. Nullable only for rows written before
      -- outlets existed; the board filters on it.
      outlet_id TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1,
        server_status TEXT,
        server_seq INTEGER,
        contested INTEGER NOT NULL DEFAULT 0,
        pos_x INTEGER,
        pos_y INTEGER
      )
    ''');

    batch.execute('''
      CREATE TABLE orders (
        id TEXT PRIMARY KEY,
        number TEXT NOT NULL,
        -- The integer behind `number`, counted per register (v24). Kept as its
        -- own column so the next number is a MAX() over this till rather than a
        -- COUNT() over the whole device — see OrderRepository._nextNumber.
        -- NULL on rows written before v24; those keep their ORD-xxxx string.
        number_seq INTEGER,
        created_at INTEGER NOT NULL,
        type TEXT NOT NULL,
        table_id TEXT,
        table_name TEXT,
        customer_name TEXT,
		customer_id TEXT,
        note TEXT,
        subtotal INTEGER NOT NULL,
        discount INTEGER NOT NULL DEFAULT 0,
        tax INTEGER NOT NULL DEFAULT 0,
        total INTEGER NOT NULL,
        amount_paid INTEGER NOT NULL DEFAULT 0,
        payment_method TEXT NOT NULL,
        status TEXT NOT NULL,
        cashier_id TEXT NOT NULL,
        cashier_name TEXT NOT NULL,
        promo_name TEXT,
        -- Who approved a void or refund, and why. Written in the same update
        -- that changes the status, so an unexplained void cannot exist.
        authorized_by TEXT,
        void_reason TEXT,
        refunded_amount INTEGER,
        -- Which branch took the money. Snapshot name alongside the id, like
        -- the cashier: renaming or closing a branch must not rewrite what a
        -- reprinted receipt says about where the sale happened.
        outlet_id TEXT,
        outlet_name TEXT,
        -- Which till rang it up, and during which session. The session id is
        -- what lets a drawer be reconciled against exactly the sales that went
        -- into it, including any rung up by a second cashier after a handover.
        -- Nullable: sales that predate tills carry none, and inventing one
        -- would be a name on history nobody can check.
        pos_id TEXT,
        pos_name TEXT,
        pos_session_id TEXT,
        -- PB1 and Service Charge rate/amount, snapshotted at sale time so a
        -- later change to Settings never rewrites a past receipt. Rates are
        -- nullable (unknown for a pre-v19 row); the service charge amount is
        -- NOT NULL — for a row written before the feature existed, "no
        -- service charge was applied" is a fact, not a guess.
        pb1_rate REAL,
        service_charge_rate REAL,
        service_charge_amount INTEGER NOT NULL DEFAULT 0,
        -- The business day the sale belongs to, YYYY-MM-DD in the device's
        -- local time, chosen once at checkout (v25): a push that arrives the
        -- next morning still lands in yesterday's report. NULL only on a sale
        -- written before v25; its first push freezes one from created_at.
        business_date TEXT,
        -- How far the server clock was ahead of this device when the sale was
        -- made, as last measured by a sync (v25). NULL before any sync.
        server_time_delta_ms INTEGER
        ,pricing_version INTEGER
        ,pricing TEXT
        ,tax_included INTEGER NOT NULL DEFAULT 0
        ,rounding_amount INTEGER NOT NULL DEFAULT 0
        ,tz_offset_minutes INTEGER
        ,sales_type_id TEXT
        ,sales_type_name TEXT
        ,payment_method_id TEXT
        ,payment_method_name TEXT
        ,payment_reference TEXT
        ,served_by_id TEXT
        ,served_by_name TEXT
        ,discount_id TEXT
        ,discount_name TEXT
        ,discount_authorized_by_id TEXT
        ,discount_authorized_by_name TEXT
        ,receipt_snapshot TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE order_items (
        id TEXT PRIMARY KEY,
        order_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_name TEXT NOT NULL,
        variant_name TEXT,
        unit_price INTEGER NOT NULL,
        -- Cost frozen at sale time so a later price edit cannot rewrite a
        -- profit figure that has already been reported.
        unit_cost INTEGER,
        quantity INTEGER NOT NULL,
        note TEXT,
        -- The product's category at sale time, snapshot like product_name —
        -- a category rename or a product moved elsewhere later must not
        -- rewrite a sales-by-category report that already ran.
        category_id TEXT,
        category_name TEXT,
		brand_id TEXT,
        custom INTEGER NOT NULL DEFAULT 0,
        base_price INTEGER,
        price_source TEXT,
        tax_rate_bp INTEGER,
        discount_spec TEXT,
        line_discount_id TEXT,
        line_discount_name TEXT,
        line_discount_authorized_by_id TEXT,
        line_discount_authorized_by_name TEXT,
        line_discount INTEGER NOT NULL DEFAULT 0,
        bill_discount_share INTEGER NOT NULL DEFAULT 0,
        service_share INTEGER NOT NULL DEFAULT 0,
        tax_amount INTEGER NOT NULL DEFAULT 0,
        tax_included INTEGER NOT NULL DEFAULT 0,
        net_amount INTEGER,
        FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE
      )
    ''');

    batch.execute(_createOutletsSql);
    batch.execute(_createOutletStockSql);
    batch.execute(_createPosRegistersSql);

    batch.execute('''
      CREATE TABLE employees (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        -- Exactly one of these two carries the credential.
        --
        -- `pin` is the demo/legacy plain text: a documented shortcut for a
        -- local till with no accounts and no network, where hashing would
        -- protect nothing because anyone who can read this file can read the
        -- app's code too. Empty for a synced account — a value no real PIN can
        -- take, since PINs are 4-6 digits.
        --
        -- `pin_hash` (v23) is a bcrypt hash pushed down from the server. It is
        -- what a connected till verifies against, offline, with no round trip.
        -- When set it wins outright: the plain-text column is never a second
        -- way past a server-owned credential.
        pin TEXT NOT NULL DEFAULT '',
        pin_hash TEXT,
        role TEXT NOT NULL,
        role_id TEXT,
        active INTEGER NOT NULL DEFAULT 1,
        sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // A shift IS the POS session: which till, which branch, who opened it,
    // what was in the drawer at both ends. Modelled as one row rather than a
    // session table alongside a shift table, because two rows describing one
    // drawer is one row too many to keep in step.
    batch.execute('''
      CREATE TABLE shifts (
        id TEXT PRIMARY KEY,
        employee_id TEXT NOT NULL,
        employee_name TEXT NOT NULL,
        -- Which till this session holds, and the branch it stands in. Snapshot
        -- names alongside the ids, like the cashier's. Nullable only for
        -- sessions opened before v16.
        pos_id TEXT,
        pos_name TEXT,
        outlet_id TEXT,
        outlet_name TEXT,
        opened_at INTEGER NOT NULL,
        opening_cash INTEGER NOT NULL,
        closed_at INTEGER,
        counted_cash INTEGER,
        -- Frozen at close, not recomputed on read: a later edit must not
        -- rewrite a variance someone already signed off.
        expected_cash INTEGER,
        -- Who counted the drawer, which is not always who opened it: a
        -- handover mid-session keeps the same session and the same cash box.
        closed_by_id TEXT,
        closed_by_name TEXT,
        note TEXT
      )
    ''');

    batch.execute(_createProductVariantsSql);
    batch.execute(_createStockMovementsSql);
    batch.execute(_createPromosSql);
    batch.execute(_createModifierGroupsSql);
    batch.execute(_createModifierOptionsSql);
    batch.execute(_createProductModifierGroupsSql);
    batch.execute(_createProductModifierOptionsSql);
    batch.execute(_createOrderItemModifiersSql);

    batch.execute(
      'CREATE INDEX idx_products_category ON products(category_id)',
    );
    batch.execute('CREATE INDEX idx_orders_created ON orders(created_at DESC)');
    batch.execute(
      'CREATE INDEX idx_order_items_order ON order_items(order_id)',
    );
    batch.execute(_indexVariantsProductSql);
    batch.execute(_indexStockMovementsProductSql);
    batch.execute(_indexOpenSessionPerRegisterSql);
    batch.execute(_indexOrderItemModifiersItemSql);
    batch.execute(_indexProductModifierOptionsProductSql);
    batch.execute(_tillStateDdl);
    batch.execute(_tillOpenDdl);
    batch.execute(_remoteOrdersDdl);
    batch.execute(_remoteOrdersIndexDdl);
    batch.execute(_remoteHistoryMetaDdl);
    batch.execute(_remoteReportsDdl);
    batch.execute('ALTER TABLE stock_movements ADD COLUMN order_id TEXT');
    for (final ddl in _f4Ddl) {
      batch.execute(ddl);
    }
    for (final table in _f4Columns.entries) {
      for (final column in table.value.entries) {
        batch.execute(
          'ALTER TABLE ${table.key} ADD COLUMN ${column.key} ${column.value}',
        );
      }
    }
  }

  /// Saved bills (v33, paritas F4).
  ///
  /// A bill is NOT an order. `orders` stays the final receipt — what a
  /// customer paid — and everything that reads money reads it; a bill is the
  /// mutable thing a table runs up before that, owned by exactly one till.
  /// Saving one moves no money and no stock; `kitchen_dispatches` is what
  /// consumes stock, once per batch sent to the kitchen; the receipt that
  /// settles a bill consumes nothing again.
  ///
  /// No foreign key from these to products, customers, staff or any master:
  /// a line is a snapshot, and a tombstone must never cascade into a bill a
  /// guest was already quoted. `bill_lines` and `kitchen_dispatches` hang off
  /// `bills` only, which is never deleted outside a demo reset.
  static const _f4Ddl = <String>[
    '''CREATE TABLE IF NOT EXISTS bills (
      id TEXT PRIMARY KEY,
      number TEXT NOT NULL,
      -- open | closed (settled by a receipt) | cancelled
      status TEXT NOT NULL,
      -- owned: this till may edit it. parked: released to the server for
      -- another till (or this one) to claim; read-only here.
      ownership TEXT NOT NULL DEFAULT 'owned',
      owner_generation INTEGER NOT NULL DEFAULT 1,
      -- The last revision saved here, which is also the push revision: every
      -- save is exactly one enqueue.
      revision INTEGER NOT NULL DEFAULT 0,
      outlet_id TEXT,
      pos_id TEXT,
      pos_session_id TEXT,
      type TEXT NOT NULL,
      sales_type_id TEXT,
      sales_type_name TEXT,
      table_id TEXT,
      table_name TEXT,
      table_session_id TEXT,
      customer_id TEXT,
      customer_name TEXT,
      served_by_id TEXT,
      served_by_name TEXT,
      note TEXT,
      created_by_id TEXT,
      created_by_name TEXT NOT NULL,
      -- The pricing configuration frozen at the first save (JSON), so a sync
      -- that changes a rate never re-prices a bill a guest was quoted.
      pricing TEXT NOT NULL,
      opened_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      closed_order_id TEXT,
      closed_at INTEGER,
      -- Why and by whom a cancelled bill was cancelled (JSON).
      cancel TEXT
    )''',
    'CREATE INDEX IF NOT EXISTS idx_bills_open ON bills(status, outlet_id)',
    '''CREATE TABLE IF NOT EXISTS bill_lines (
      id TEXT PRIMARY KEY,
      bill_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      product_id TEXT,
      product_name TEXT NOT NULL,
      variant_id TEXT,
      variant_name TEXT,
      -- The chosen modifiers as a JSON list: group/option ids and names and
      -- the delta, frozen with the line.
      modifiers TEXT NOT NULL DEFAULT '[]',
      unit_price INTEGER NOT NULL,
      base_price INTEGER,
      price_source TEXT,
      tax_rate_bp INTEGER,
      unit_cost INTEGER,
      quantity INTEGER NOT NULL,
      note TEXT,
      custom INTEGER NOT NULL DEFAULT 0,
      category_id TEXT,
      category_name TEXT,
      brand_id TEXT,
      discount TEXT,
      line_discount_id TEXT,
      line_discount_name TEXT,
      line_discount_authorized_by_id TEXT,
      line_discount_authorized_by_name TEXT,
      -- Set once, by the dispatch that sent it to the kitchen. A dispatched
      -- line is never edited or removed again.
      dispatch_id TEXT,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (bill_id) REFERENCES bills(id) ON DELETE CASCADE
    )''',
    'CREATE INDEX IF NOT EXISTS idx_bill_lines_bill ON bill_lines(bill_id, seq)',
    '''CREATE TABLE IF NOT EXISTS kitchen_dispatches (
      id TEXT PRIMARY KEY,
      bill_id TEXT NOT NULL,
      -- queued -> preparing -> ready -> served; cancelled with its bill.
      status TEXT NOT NULL,
      occurred_at INTEGER NOT NULL,
      status_changed_at INTEGER NOT NULL,
      employee_id TEXT,
      employee_name TEXT NOT NULL,
      pos_session_id TEXT,
      outlet_id TEXT,
      -- device: this till sent it and owes its stock effects. server: it came
      -- with a claimed bill; its stock is already on the server's ledger.
      origin TEXT NOT NULL DEFAULT 'device',
      -- For a server dispatch, the batch exactly as the server accepted it:
      -- reporting its kitchen progress repeats it unchanged (JSON).
      payload TEXT,
      FOREIGN KEY (bill_id) REFERENCES bills(id) ON DELETE CASCADE
    )''',
    'CREATE INDEX IF NOT EXISTS idx_kitchen_dispatches_bill ON kitchen_dispatches(bill_id)',
    // One seating at one table. On an activated till it is opened and closed
    // online; the demo keeps it locally.
    '''CREATE TABLE IF NOT EXISTS table_sessions (
      id TEXT PRIMARY KEY,
      table_id TEXT NOT NULL,
      table_name TEXT NOT NULL,
      outlet_id TEXT,
      guest_count INTEGER,
      opened_at INTEGER NOT NULL,
      opened_by_name TEXT,
      closed_at INTEGER
    )''',
    // The outlet's last fetched board of open bills and seatings (GET
    // /till/bills), replaced whole on every fetch. A read cache only: it
    // never makes a bill editable here.
    '''CREATE TABLE IF NOT EXISTS _bill_board (
      outlet_id TEXT PRIMARY KEY,
      payload TEXT NOT NULL,
      fetched_at INTEGER NOT NULL
    )''',
  ];

  /// Columns v33 adds to tables that already exist.
  static const _f4Columns = <String, Map<String, String>>{
    // When the entry was last re-queued. The stock-count barrier orders by it:
    // a bill cancelled after a count must reach the server after the count.
    '_outbox': {'last_queued_at': 'INTEGER'},
    // Which dispatch or cancellation a movement belongs to. Such a movement
    // travels inside that row's push, never on its own.
    'stock_movements': {'source_kind': 'TEXT', 'source_id': 'TEXT'},
    'orders': {'bill_id': 'TEXT'},
    'order_items': {'bill_line_id': 'TEXT'},
    // Whether the branch runs saved bills, pulled with the rest of the
    // outlet's settings. Legacy until the owner switches it on.
    'outlet_settings': {'bill_model': "TEXT NOT NULL DEFAULT 'legacy'"},
  };

  static const _tillStateDdl = '''
    CREATE TABLE IF NOT EXISTS _till_sessions (
      id TEXT PRIMARY KEY, state TEXT NOT NULL, employee_id TEXT NOT NULL,
      receipt_next INTEGER NOT NULL, receipt_end INTEGER NOT NULL,
      recovery_id TEXT, recovery_detected_at INTEGER)
  ''';
  static const _tillOpenDdl = '''
    CREATE TABLE IF NOT EXISTS _till_open_requests (
      register_id TEXT PRIMARY KEY, payload TEXT NOT NULL)
  ''';

  /// Server receipts this device has read, keyed by (receipt, VIEWER).
  ///
  /// The viewer is part of the key because the scope of what may be read is a
  /// property of the person, not of the receipt: with `id` alone as the key, a
  /// manager's wider fetch overwrote the cashier's row with a different
  /// `employee_id`, and the cashier's own history then came back empty after a
  /// handover. Two rows for one receipt is the honest cost of that.
  ///
  /// `register_id`, `cashier_id`, `status` and `placed_at_ms` are lifted out of
  /// the payload so a scoped or filtered read is a WHERE rather than decoding
  /// every cached row in Dart. The payload itself stays authoritative.
  static const _remoteOrdersDdl = '''
    CREATE TABLE IF NOT EXISTS _remote_orders (
      id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      business_date TEXT NOT NULL,
      scope TEXT NOT NULL DEFAULT 'register',
      register_id TEXT,
      cashier_id TEXT,
      status TEXT,
      placed_at_ms INTEGER NOT NULL DEFAULT 0,
      payload TEXT NOT NULL,
      fetched_at INTEGER NOT NULL,
      PRIMARY KEY (id, employee_id))
  ''';
  static const _remoteOrdersIndexDdl = '''
    CREATE INDEX IF NOT EXISTS _remote_orders_read
      ON _remote_orders (employee_id, business_date DESC, placed_at_ms DESC)
  ''';

  /// What was fetched, for whom, and whether the fetch finished.
  ///
  /// Without it the app cannot tell "this period had no sales" from "this
  /// period was never downloaded", and those are opposite answers: the first
  /// is a fact worth showing, the second is a reason to say the list is
  /// incomplete offline rather than to draw an empty day.
  /// Rebuilds `_remote_orders` onto its v30 key, carrying every cached row
  /// across.
  ///
  /// SQLite cannot add a column to a primary key in place, so the table is
  /// recreated beside the old one and the rows are copied. The copy keeps the
  /// payload verbatim and re-derives the new columns from it — the payload is
  /// what the server sent, so nothing here is invented.
  ///
  /// `INSERT OR IGNORE` because the OLD key allowed one row per receipt across
  /// every viewer: nothing can duplicate under the wider key, but an install
  /// that somehow holds a collision keeps its first row rather than failing
  /// the whole upgrade.
  Future<void> _rebuildRemoteOrders(Database db) async {
    if (!await _tableExists(db, '_remote_orders')) {
      await db.execute(_remoteOrdersDdl);
      await db.execute(_remoteOrdersIndexDdl);
      return;
    }
    await db.execute('ALTER TABLE _remote_orders RENAME TO _remote_orders_v29');
    await db.execute(_remoteOrdersDdl);
    await db.execute(_remoteOrdersIndexDdl);
    await db.execute('''
      INSERT OR IGNORE INTO _remote_orders
        (id, employee_id, business_date, scope, register_id, cashier_id, status, placed_at_ms, payload, fetched_at)
      SELECT id, employee_id, business_date, 'register',
             json_extract(payload, '\$.pos_id'),
             json_extract(payload, '\$.cashier_id'),
             json_extract(payload, '\$.status'),
             COALESCE(json_extract(payload, '\$.placed_at_ms'), 0),
             payload, fetched_at
      FROM _remote_orders_v29
    ''');
    await db.execute('DROP TABLE _remote_orders_v29');
  }

  static const _remoteHistoryMetaDdl = '''
    CREATE TABLE IF NOT EXISTS _remote_history_meta (
      employee_id TEXT NOT NULL,
      scope TEXT NOT NULL,
      filter_key TEXT NOT NULL,
      fetched_at INTEGER NOT NULL,
      complete INTEGER NOT NULL DEFAULT 0,
      row_count INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (employee_id, scope, filter_key))
  ''';

  /// Server report bodies, cached per viewer and per filter so an offline till
  /// shows the LAST SERVER ANSWER with its timestamp — never a local total
  /// quietly standing in for an outlet one.
  static const _remoteReportsDdl = '''
    CREATE TABLE IF NOT EXISTS _remote_reports (
      employee_id TEXT NOT NULL,
      endpoint TEXT NOT NULL,
      filter_key TEXT NOT NULL,
      payload TEXT NOT NULL,
      fetched_at INTEGER NOT NULL,
      PRIMARY KEY (employee_id, endpoint, filter_key))
  ''';

  /// Held as constants because both `_createSchemaV2` (fresh install) and the
  /// v10 upgrade have to create these, and two copies of a CREATE TABLE is how
  /// a migrated install ends up one column short of a fresh one.
  static const _createProductVariantsSql = '''
    CREATE TABLE IF NOT EXISTS product_variants (
      id TEXT PRIMARY KEY,
      product_id TEXT NOT NULL,
      name TEXT NOT NULL,
      -- Signed delta from the product's base price, not an absolute price:
      -- a base price change must not silently invalidate every variant.
      price_delta INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0,
      FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
    )
  ''';

  static const _createStockMovementsSql = '''
    CREATE TABLE IF NOT EXISTS stock_movements (
      id TEXT PRIMARY KEY,
      -- Which branch's shelf moved. Nullable only because rows written before
      -- outlets existed cannot be invented; every new row carries one.
      outlet_id TEXT,
      product_id TEXT NOT NULL,
      -- Copied, not joined: deleting a product must not blank its history.
      product_name TEXT NOT NULL,
      delta INTEGER NOT NULL,
      balance_after INTEGER NOT NULL,
      reason TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      employee_id TEXT NOT NULL DEFAULT '',
      employee_name TEXT NOT NULL DEFAULT '',
      note TEXT,
      -- v26, the server ledger. counted_qty/basis_seq describe a stock opname.
      -- server_seq is the projection sequence the server applied this movement
      -- at: NULL while it is still owed. origin says who wrote it — 'device'
      -- (this till) or 'server' (pulled history, never pushed back).
      counted_qty INTEGER,
      basis_seq INTEGER,
      server_seq INTEGER,
      origin TEXT NOT NULL DEFAULT 'device'
    )
  ''';

  static const _createPromosSql = '''
    CREATE TABLE IF NOT EXISTS promos (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      value INTEGER NOT NULL,
      min_spend INTEGER NOT NULL DEFAULT 0,
      all_outlets INTEGER NOT NULL DEFAULT 1,
      active INTEGER NOT NULL DEFAULT 1,
      sort_order INTEGER NOT NULL DEFAULT 0
    )
  ''';

  static const _promoOutletsDdl = '''
    CREATE TABLE IF NOT EXISTS promo_outlets (
      promo_id TEXT NOT NULL REFERENCES promos(id) ON DELETE CASCADE,
      outlet_id TEXT NOT NULL,
      PRIMARY KEY (promo_id, outlet_id)
    )
  ''';

  // No FK to the definition: an offline event must survive a tombstone so
  // the server can reject it and the original payload remains recoverable.
  static const _tableStatusEventsDdl = '''
    CREATE TABLE IF NOT EXISTS table_status_events (
      id TEXT PRIMARY KEY,
      table_id TEXT NOT NULL,
      outlet_id TEXT NOT NULL,
      status TEXT NOT NULL,
      client_seq INTEGER NOT NULL,
      basis_seq INTEGER NOT NULL,
      employee_name TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL,
      server_seq INTEGER,
      outcome TEXT
    )
  ''';

  static const _tableStatusSequenceIndex =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_table_status_client_seq '
      'ON table_status_events(table_id, client_seq)';

  static const _indexVariantsProductSql =
      'CREATE INDEX IF NOT EXISTS idx_variants_product '
      'ON product_variants(product_id)';

  static const _indexStockMovementsProductSql =
      'CREATE INDEX IF NOT EXISTS idx_stock_movements_product '
      'ON stock_movements(product_id, created_at DESC)';

  /// Gives a handful of products a size choice.
  ///
  /// Only drinks: a size picker on nasi goreng would be noise, and the point
  /// of seeding any is that the variant flow is visible on the sell screen
  /// without anyone first having to build a product to demonstrate it.
  ///
  /// No-ops when variants already exist, so it is safe from both `_onCreate`
  /// and the v10 upgrade.
  @visibleForTesting
  Future<void> seedVariants(Database db) async {
    final existing = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM product_variants'),
    );
    if ((existing ?? 0) > 0) return;

    // Only for products that are actually present. `product_variants` has an
    // enforced FK, and a catalogue where someone deleted a seeded coffee — or
    // a partially-migrated schema in a test — would otherwise abort the whole
    // migration with SQLite error 787.
    final knownProducts = {
      for (final r in await db.query('products', columns: ['id']))
        r['id'] as String,
    };

    final batch = db.batch();
    for (final entry in _seedVariants.entries) {
      if (!knownProducts.contains(entry.key)) continue;
      var i = 0;
      for (final v in entry.value) {
        batch.insert('product_variants', {
          'id': '${entry.key}_v${i + 1}',
          'product_id': entry.key,
          'name': v.$1,
          'price_delta': v.$2,
          'sort_order': i,
        });
        i++;
      }
    }
    await batch.commit(noResult: true);
  }

  /// Product id → list of (variant name, price delta).
  ///
  /// Regular is offered explicitly at +0 rather than being implied by "no
  /// variant chosen": a picker where one option is unnamed makes the cashier
  /// wonder whether they missed a step.
  static const _seedVariants = <String, List<(String, int)>>{
    'p_kopi_susu': [('Regular', 0), ('Large', 5000)],
    'p_cappuccino': [('Regular', 0), ('Large', 6000)],
    'p_latte': [('Regular', 0), ('Large', 6000)],
    'p_es_teh': [('Regular', 0), ('Jumbo', 3000)],
    'p_lemon_tea': [('Hot', 0), ('Iced', 2000)],
    'p_kopi_hitam': [('Hot', 0), ('Iced', 2000)],
  };

  /// Gives a handful of products a modifier group — the same "visible without
  /// building one" reasoning as [seedVariants]: spice level on food that
  /// plausibly has one, sugar/ice level on cold drinks that are not already
  /// covered by a Hot/Iced variant, toppings on coffee.
  ///
  /// No-ops when groups already exist, so it is safe from both `_onCreate`
  /// and the v17 upgrade. `product_modifier_groups.product_id` has an
  /// enforced FK, so — exactly like [seedVariants] — this only attaches a
  /// group to a product that is actually present, or a partially-migrated
  /// schema would abort the whole migration with SQLite error 787.
  @visibleForTesting
  Future<void> seedModifiers(Database db) async {
    final existing = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM modifier_groups'),
    );
    if ((existing ?? 0) > 0) return;

    final knownProducts = {
      for (final r in await db.query('products', columns: ['id']))
        r['id'] as String,
    };

    final batch = db.batch();
    for (final group in _seedModifierGroups) {
      batch.insert('modifier_groups', {
        'id': group.id,
        'name': group.name,
        'selection_type': group.selectionType,
        'required': group.required ? 1 : 0,
        'max_select': group.maxSelect,
        'sort_order': 0,
        'active': 1,
      });
      var i = 0;
      for (final option in group.options) {
        batch.insert('modifier_options', {
          'id': '${group.id}_o${i + 1}',
          'group_id': group.id,
          'name': option.$1,
          'price_delta': option.$2,
          'sort_order': i,
          'active': 1,
        });
        i++;
      }
      for (final productId in group.productIds) {
        if (!knownProducts.contains(productId)) continue;
        batch.insert('product_modifier_groups', {
          'product_id': productId,
          'group_id': group.id,
        });
      }
    }
    await batch.commit(noResult: true);
  }

  /// Backfills `product_modifier_options` from whatever `product_modifier_groups`
  /// already exists, so an attachment made before v18 keeps behaving exactly
  /// as it did — every currently-active option in the group — until an admin
  /// opens the product and narrows it down. `INSERT OR IGNORE` against the
  /// `(product_id, option_id)` primary key makes this safe to call more than
  /// once, so no separate "already ran" guard is needed the way [seedModifiers]
  /// needs one for its own inserts.
  @visibleForTesting
  Future<void> backfillProductModifierOptionScope(Database db) async {
    await db.rawInsert('''
      INSERT OR IGNORE INTO product_modifier_options (product_id, option_id)
      SELECT pmg.product_id, mo.id
      FROM product_modifier_groups pmg
      JOIN modifier_options mo ON mo.group_id = pmg.group_id
      WHERE mo.active = 1
    ''');
  }

  static const _seedModifierGroups = <_SeedModifierGroup>[
    (
      id: 'mg_spice',
      name: 'Level Pedas',
      selectionType: 'single',
      required: true,
      maxSelect: null,
      options: [
        ('No Spice', 0),
        ('Medium', 0),
        ('Spicy', 0),
        ('Extra Spicy', 0),
      ],
      productIds: ['p_ayam_geprek', 'p_mie_goreng', 'p_nasi_goreng'],
    ),
    (
      id: 'mg_sugar',
      name: 'Level Gula',
      selectionType: 'single',
      required: true,
      maxSelect: null,
      options: [('Normal', 0), ('Less Sugar', 0), ('No Sugar', 0)],
      productIds: [
        'p_kopi_susu',
        'p_es_teh',
        'p_lemon_tea',
        'p_kopi_hitam',
        'p_es_jeruk',
      ],
    ),
    (
      id: 'mg_ice',
      name: 'Level Es',
      selectionType: 'single',
      required: true,
      maxSelect: null,
      // Only drinks with no Hot/Iced variant already covering this — see
      // `_seedVariants` above for `p_lemon_tea`/`p_kopi_hitam`, which stay out
      // of this group so the two axes never overlap on the same product.
      options: [
        ('No Ice', 0),
        ('Less Ice', 0),
        ('Normal', 0),
        ('Extra Ice', 0),
      ],
      productIds: ['p_es_teh', 'p_es_jeruk', 'p_jus_alpukat'],
    ),
    (
      id: 'mg_topping',
      name: 'Topping',
      selectionType: 'multiple',
      required: false,
      maxSelect: 3,
      options: [
        ('Boba', 3000),
        ('Cheese Foam', 5000),
        ('Extra Shot', 5000),
        ('Whipped Cream', 3000),
      ],
      productIds: ['p_kopi_susu', 'p_cappuccino', 'p_latte'],
    ),
  ];

  /// Seeds two promotions so the discount picker is not an empty list.
  ///
  /// One percentage and one flat amount with a minimum spend, because those
  /// are the two shapes the model supports and a demo that only shows one of
  /// them leaves the other looking unimplemented.
  @visibleForTesting
  Future<void> seedPromos(Database db) async {
    final existing = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM promos'),
    );
    if ((existing ?? 0) > 0) return;

    final batch = db.batch();
    for (final p in const [
      Promo(
        id: 'promo_happy_hour',
        name: 'Happy Hour 15%',
        kind: PromoKind.percent,
        value: 15,
      ),
      Promo(
        id: 'promo_hemat_10k',
        name: 'Hemat Rp 10.000',
        kind: PromoKind.amount,
        value: 10000,
        minSpend: 75000,
        sortOrder: 1,
      ),
      Promo(
        id: 'promo_karyawan',
        name: 'Diskon Karyawan 20%',
        kind: PromoKind.percent,
        value: 20,
        active: false,
        sortOrder: 2,
      ),
    ]) {
      batch.insert('promos', p.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<void> _seed(Database db) async {
    final batch = db.batch();

    // Categories
    final categories = _seedCategories();
    for (final c in categories) {
      batch.insert('categories', c.toMap());
    }

    // Products
    for (final p in _seedProducts()) {
      batch.insert('products', p.toMap());
    }

    // Tables
    for (final t in _seedTables()) {
      batch.insert('tables', t.toMap());
    }

    await batch.commit(noResult: true);
    await applySeedStock(db);
    await applySeedCost(db);
    await seedEmployees(db);
    await seedOutlets(db);
    await seedPosRegisters(db);
    await seedOutletStock(db);
    await seedVariants(db);
    await seedModifiers(db);
    await backfillProductModifierOptionScope(db);
    await seedPromos(db);
    await seedOpeningStockMovements(db);
    // Orders are seeded last, then reattributed: `seedOrders` writes the
    // historical placeholder cashier, and `attributeSeedOrdersToStaff` is the
    // single place that maps it onto real staff — for fresh installs and
    // upgrades alike, so both end up with identical data.
    await seedOrders(db);
    await attributeSeedOrdersToStaff(db);
    await applyOutletScoping(db);
    await backfillOrderItemCost(db);
    await backfillOrderItemCategory(db);
  }

  /// Seeds a month of demo sales.
  ///
  /// Without this the app opens on an empty Dashboard (Rp 0, "No sales
  /// recorded yet"), an empty Orders tab and idle tables — which reads as a
  /// product that does not work rather than one that has no data yet.
  ///
  /// Deterministic apart from the anchor: the generator is fixed-seeded and
  /// timestamps are derived from "today" at seed time, so the current day
  /// always has sales and `topProducts` (7-day window) always has a ranking.
  /// Orders are numbered oldest-first, so `_nextNumber` (which counts rows)
  /// continues the sequence cleanly.
  ///
  /// Exposed for the v6 migration, which backfills installs created before
  /// orders were seeded, and for v12, which replaces the small original set.
  @visibleForTesting
  Future<void> seedOrders(Database db) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final specs = _generateSeedOrders();
    final batch = db.batch();

    var seq = 0;
    for (final spec in specs) {
      seq++;
      final id = 'seed_ord_${seq.toString().padLeft(5, '0')}';
      final createdAt = today
          .subtract(Duration(days: spec.daysAgo))
          .add(Duration(hours: spec.hour, minutes: spec.minute));

      // Resolve the lines first: the parent `orders` row has to be inserted
      // before its `order_items` (both FKs are enforced — `_onConfigure` turns
      // `PRAGMA foreign_keys` ON), and the order's subtotal is only known once
      // the lines are priced.
      final lines = [
        for (final item in spec.items)
          (product: _seedProductById(item.productId), qty: item.qty),
      ];
      final subtotal = lines.fold<int>(
        0,
        (sum, l) => sum + l.product.price * l.qty,
      );

      // Seeded orders carry no tax: the default store tax rate is 0%, and a
      // seeded tax would contradict the totals a user recomputes in Settings.
      final total = subtotal - spec.discount;
      batch.insert('orders', {
        'id': id,
        'number': 'ORD-${seq.toString().padLeft(4, '0')}',
        'created_at': createdAt.millisecondsSinceEpoch,
        'type': spec.type.wire,
        'table_id': spec.tableId,
        'table_name': spec.tableId == null
            ? null
            : _seedTableName(spec.tableId!),
        'customer_name': spec.customerName,
        'note': null,
        'subtotal': subtotal,
        'discount': spec.discount,
        'tax': 0,
        'total': total,
        // Cash is tendered in round notes; the electronic methods pay exact.
        'amount_paid': spec.payment == PaymentMethod.cash
            ? _roundUpToNote(total)
            : total,
        'payment_method': spec.payment.wire,
        'status': spec.status.wire,
        'cashier_id': 'cashier',
        'cashier_name': 'Kasir Demo',
        // A void or refund the app produced would always carry these; a
        // seeded one without them would be a state no code path can reach.
        'authorized_by': spec.authorizedBy,
        'void_reason': spec.voidReason,
        'refunded_amount': spec.status == OrderStatus.refunded ? total : null,
      });

      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        batch.insert('order_items', {
          'id': '${id}_i${i + 1}',
          'order_id': id,
          'product_id': l.product.id,
          'product_name': l.product.name,
          'unit_price': l.product.price,
          'quantity': l.qty,
          'note': null,
        });
      }
    }

    // Tables holding an unfinished dine-in order must not read as free.
    for (final spec in specs) {
      if (spec.tableId == null || spec.status.isTerminal) continue;
      batch.update(
        'tables',
        {'status': TableStatus.occupied.wire},
        where: 'id = ?',
        whereArgs: [spec.tableId],
      );
    }
    // Bookings nobody has walked into yet — the third status on the board,
    // which would otherwise never appear.
    //
    // Only where the table is still free. Without the guard this ran after
    // the occupancy pass and silently overwrote it, so a table with an order
    // in the kitchen showed as reserved and the board lost a cover.
    batch.update(
      'tables',
      {'status': TableStatus.reserved.wire},
      where:
          'id IN (${_seedReservedTables.map((_) => '?').join(', ')}) '
          'AND status = ?',
      whereArgs: [..._seedReservedTables, TableStatus.available.wire],
    );

    await batch.commit(noResult: true);
  }

  Product _seedProductById(String id) =>
      _seedProducts().firstWhere((p) => p.id == id);

  String _seedTableName(String id) =>
      _seedTables().firstWhere((t) => t.id == id).name;

  /// Cash is handed over in whole notes, so the receipt shows real change.
  static int _roundUpToNote(int total) {
    const notes = [5000, 10000, 20000, 50000, 100000, 150000, 200000];
    for (final n in notes) {
      if (n >= total) return n;
    }
    return ((total + 49999) ~/ 50000) * 50000;
  }

  /// Days of trading history the demo carries, today included.
  ///
  /// Matches the report's longest preset (Last 30) so that range is never
  /// half-empty, and gives "This month" a full set of days to draw.
  static const _seedHistoryDays = 30;

  /// Builds the demo's trading history.
  ///
  /// Hand-writing a busy restaurant's month is not an option — it is well over
  /// a thousand orders — so the *shape* is described here and the rows are
  /// generated from it. The generator takes a fixed seed: "Reset demo data"
  /// has to produce the same restaurant every time, or two screenshots of the
  /// same install disagree with each other.
  ///
  /// What the shape encodes, and why:
  /// - **Friday to Sunday are busier than midweek**, so the report's chart has
  ///   a rhythm rather than a flat line that looks generated.
  /// - **Parties skew large.** This is what puts the average check in the
  ///   hundreds of thousands: the menu tops out at Rp 35.000, so a big number
  ///   has to come from a table of eight rather than from an invented price.
  /// - **Nasi Goreng and Es Teh are weighted twice** in their pools, so Top
  ///   Products has a stable winner instead of a twenty-way tie that
  ///   reshuffles on every reset.
  /// - **A few orders are voided or refunded**, with an approver and a reason,
  ///   so the status filters and `kRevenueStatusSql` are exercised by real
  ///   rows and the report's revenue genuinely excludes them.
  /// - **Today ends with several still in the kitchen**, which is also what
  ///   puts tables into `occupied` and gives the board something to show.
  ///
  /// **Today is seeded as a full trading day rather than truncated at the
  /// clock.** A demo opened at 09:00 would otherwise land on an almost empty
  /// Dashboard — the exact failure this seed exists to prevent. The price is
  /// that a morning demo shows a few timestamps later than the wall clock.
  List<_SeedOrderSpec> _generateSeedOrders() {
    final rnd = Random(20260730);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tables = _seedTables();
    final prices = {for (final p in _seedProducts()) p.id: p.price};

    final specs = <_SeedOrderSpec>[];
    for (var daysAgo = _seedHistoryDays - 1; daysAgo >= 0; daysAgo--) {
      final date = today.subtract(Duration(days: daysAgo));
      final busy = date.weekday >= DateTime.friday;
      final covers = (busy ? 54 : 40) + rnd.nextInt(busy ? 15 : 13);

      final day = <_SeedOrderSpec>[
        for (var i = 0; i < covers; i++)
          _generateOrder(rnd, daysAgo, tables, prices),
      ];
      // Chronological within the day so order numbers, which are assigned in
      // list order, run forwards like a real receipt roll.
      day.sort(
        (a, b) => (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute),
      );
      specs.addAll(day);
    }

    _markSettledOrders(rnd, specs);
    _markKitchenOrders(specs, tables);
    return specs;
  }

  /// One order: when, who for, what they ate, how they paid.
  _SeedOrderSpec _generateOrder(
    Random rnd,
    int daysAgo,
    List<RestaurantTable> tables,
    Map<String, int> prices,
  ) {
    final (hour, minute) = _serviceTime(rnd);
    final party = _seedPartySizes[rnd.nextInt(_seedPartySizes.length)];
    final items = _composeOrder(rnd, party);

    final typeRoll = rnd.nextInt(100);
    final type = typeRoll < 68
        ? OrderType.dineIn
        : typeRoll < 86
        ? OrderType.takeaway
        : OrderType.delivery;

    final payRoll = rnd.nextInt(100);
    final payment = payRoll < 42
        ? PaymentMethod.qris
        : payRoll < 76
        ? PaymentMethod.cash
        : PaymentMethod.card;

    // A discount on roughly one order in eight, sized like the seeded promos
    // and rounded to a note — so the column is exercised by figures a cashier
    // could actually have keyed in.
    var discount = 0;
    if (rnd.nextInt(100) < 12) {
      final subtotal = items.fold<int>(
        0,
        (sum, i) => sum + (prices[i.productId] ?? 0) * i.qty,
      );
      discount = ((subtotal * (5 + rnd.nextInt(6)) / 100) / 500).round() * 500;
    }

    return _SeedOrderSpec(
      daysAgo: daysAgo,
      hour: hour,
      minute: minute,
      type: type,
      tableId: type == OrderType.dineIn ? _tableFor(rnd, party, tables) : null,
      customerName: type == OrderType.dineIn
          ? null
          : _seedCustomerNames[rnd.nextInt(_seedCustomerNames.length)],
      payment: payment,
      status: OrderStatus.paid,
      discount: discount,
      items: items,
    );
  }

  /// Service windows. Lunch is the heaviest, mid-afternoon the thinnest, and
  /// dinner runs longest — the shape of a restaurant's day rather than orders
  /// sprinkled evenly from open to close.
  static (int, int) _serviceTime(Random rnd) {
    final roll = rnd.nextInt(100);
    if (roll < 44) return (11 + rnd.nextInt(3), rnd.nextInt(60));
    if (roll < 60) return (14 + rnd.nextInt(3), rnd.nextInt(60));
    return (17 + rnd.nextInt(5), rnd.nextInt(60));
  }

  /// A main and a drink per head, plus snacks and dessert often enough to be
  /// believable without every table ordering the whole menu.
  List<_SeedOrderItem> _composeOrder(Random rnd, int party) {
    final items = <_SeedOrderItem>[];
    _spread(rnd, _seedMainPool, party, items);
    _spread(rnd, _seedDrinkPool, party, items);
    if (rnd.nextInt(100) < 55) {
      _spread(rnd, _seedSnackPool, 1 + rnd.nextInt(party <= 4 ? 2 : 3), items);
    }
    if (rnd.nextInt(100) < 35) {
      _spread(
        rnd,
        _seedDessertPool,
        1 + rnd.nextInt(party <= 4 ? 2 : 3),
        items,
      );
    }
    return items;
  }

  /// Splits [qty] across one to three distinct products from [pool].
  ///
  /// A table of eight ordering eight of the same dish is not what happens, and
  /// eight separate lines of one is not either — two or three dishes with
  /// quantities is. Repeat draws are dropped rather than retried forever: the
  /// pools weight their favourites by repetition, so a collision just means
  /// one fewer line, never a lost quantity.
  static void _spread(
    Random rnd,
    List<String> pool,
    int qty,
    List<_SeedOrderItem> out,
  ) {
    if (qty <= 0) return;
    final wanted = qty <= 2 ? 1 : (qty <= 5 ? 2 : 3);
    final kinds = <String>[];
    for (var i = 0; i < wanted * 3 && kinds.length < wanted; i++) {
      final id = pool[rnd.nextInt(pool.length)];
      if (!kinds.contains(id)) kinds.add(id);
    }

    var left = qty;
    for (var i = 0; i < kinds.length; i++) {
      final isLast = i == kinds.length - 1;
      // Every remaining kind still needs at least one, hence the reservation.
      final take = isLast
          ? left
          : 1 + rnd.nextInt(left - (kinds.length - i - 1));
      out.add(_SeedOrderItem(kinds[i], take));
      left -= take;
    }
  }

  /// Seats a party at a table that can actually hold it.
  static String _tableFor(Random rnd, int party, List<RestaurantTable> tables) {
    final fits = tables.where((t) => t.capacity >= party).toList();
    final pool = fits.isEmpty ? tables : fits;
    return pool[rnd.nextInt(pool.length)].id;
  }

  /// Voids a handful of historical orders and refunds a handful more.
  ///
  /// Both carry the approving manager's name and a reason, because
  /// `voidOrder` / `refundOrder` write those in the same UPDATE as the status —
  /// a seeded row without them would be a state the app itself cannot produce.
  /// Kept off today so the current day's takings stay clean and the Dashboard
  /// figure matches what a cashier would count.
  static void _markSettledOrders(Random rnd, List<_SeedOrderSpec> specs) {
    final history = [
      for (var i = 0; i < specs.length; i++)
        if (specs[i].daysAgo > 0) i,
    ];
    if (history.length < 20) return;

    final picked = <int>{};
    while (picked.length < 12) {
      picked.add(history[rnd.nextInt(history.length)]);
    }
    var n = 0;
    for (final i in picked) {
      final void_ = n++ % 2 == 0;
      specs[i] = specs[i].settled(
        status: void_ ? OrderStatus.cancelled : OrderStatus.refunded,
        authorizedBy: 'Siwi Wiyono Raharjo',
        voidReason: void_
            ? _seedVoidReasons[rnd.nextInt(_seedVoidReasons.length)]
            : null,
      );
    }
  }

  /// Leaves the tail of today mid-service.
  ///
  /// Without this the kitchen board is empty, every table reads free, and the
  /// Orders tab's status filters all return nothing — three screens that look
  /// broken rather than idle.
  ///
  /// Each one is forced to **dine-in on a table of its own**. Left to the
  /// ordinary distribution most of the tail came out takeaway or delivery, and
  /// two of the ten that did not landed on the same table — so a thirty-one
  /// table board showed two occupied and read as a restaurant nobody visits.
  static void _markKitchenOrders(
    List<_SeedOrderSpec> specs,
    List<RestaurantTable> tables,
  ) {
    final today = [
      for (var i = 0; i < specs.length; i++)
        if (specs[i].daysAgo == 0) i,
    ];
    // The most recent ten: five still cooking, three plated, one served but
    // not yet settled, one just sent to the kitchen.
    const statuses = [
      OrderStatus.pending,
      OrderStatus.preparing,
      OrderStatus.preparing,
      OrderStatus.preparing,
      OrderStatus.preparing,
      OrderStatus.preparing,
      OrderStatus.ready,
      OrderStatus.ready,
      OrderStatus.ready,
      OrderStatus.served,
    ];
    final tail = today.length < statuses.length
        ? today
        : today.sublist(today.length - statuses.length);

    // Spread across the floors rather than taken in id order, so the board
    // does not fill up from one corner.
    final seats = [
      for (var i = 0; i < tail.length; i++)
        tables[(i * 7 + 2) % tables.length].id,
    ];
    for (var i = 0; i < tail.length; i++) {
      specs[tail[i]] = specs[tail[i]].withStatus(
        statuses[i],
        type: OrderType.dineIn,
        tableId: seats[i],
      );
    }
  }

  /// Nasi Goreng appears twice so Top Products has a stable winner.
  static const _seedMainPool = [
    'p_nasi_goreng',
    'p_nasi_goreng',
    'p_mie_goreng',
    'p_ayam_geprek',
    'p_nasi_padang',
    'p_sate_ayam',
    'p_ayam_goreng',
    'p_mie_ayam',
    'p_gado_gado',
  ];

  /// Es Teh likewise — it is what most of the room drinks.
  static const _seedDrinkPool = [
    'p_es_teh',
    'p_es_teh',
    'p_es_jeruk',
    'p_lemon_tea',
    'p_soft_drink',
    'p_jus_alpukat',
    'p_air_mineral',
    'p_kopi_susu',
    'p_kopi_hitam',
    'p_cappuccino',
    'p_latte',
  ];

  static const _seedSnackPool = [
    'p_kentang',
    'p_dimsum',
    'p_pisang_goreng',
    'p_risol',
    'p_roti_bakar',
  ];

  static const _seedDessertPool = ['p_es_krim', 'p_pudding', 'p_brownies'];

  /// Weighted towards tables rather than couples — this is the number that
  /// decides the average check. The menu tops out at Rp 35.000, so the only
  /// honest route to a restaurant-sized ticket is a restaurant-sized party.
  static const _seedPartySizes = [2, 3, 4, 4, 4, 5, 6, 6, 8, 8, 10, 12];

  static const _seedCustomerNames = [
    'Bu Sinta',
    'Pak Hendra',
    'Mas Yoga',
    'Mbak Rina',
    'Pak Anton',
    'Bu Ratna',
    'Kak Vina',
    'Pak Joko',
    'Bu Maya',
    'Mas Reza',
  ];

  /// Tables held by a booking. Four candidates for three bookings: the
  /// kitchen tail seats itself first and may take one of these, and the
  /// reserved pass only claims what is still free.
  static const _seedReservedTables = ['t_8', 't_25', 't_29', 't_31'];

  static const _seedVoidReasons = [
    'Pesanan salah input',
    'Tamu membatalkan',
    'Meja pindah, order dibuat ulang',
    'Stok habis',
  ];

  /// Drop & recreate everything (used by Settings -> Reset demo data).
  Future<void> reset() async {
    if (_connectedScope != null) {
      throw StateError(
        'Demo reset is unavailable for connected device storage.',
      );
    }
    final db = await this.db;
    final batch = db.batch();
    // Children before parents: PRAGMA foreign_keys is on.
    batch.delete('bill_lines');
    batch.delete('kitchen_dispatches');
    batch.delete('bills');
    batch.delete('table_sessions');
    batch.delete('order_items');
    batch.delete('orders');
    batch.delete('stock_movements');
    batch.delete('product_variants');
    batch.delete('products');
    batch.delete('brands');
    batch.delete('categories');
    batch.delete('customers');
    batch.delete('tables');
    batch.delete('employees');
    batch.delete('shifts');
    batch.delete('promos');
    await batch.commit(noResult: true);
    await _seed(db);
  }

  List<Category> _seedCategories() {
    return [
      Category(
        id: 'cat_food',
        name: 'Food',
        emoji: '🍱',
        iconKey: _seedCategoryIconKeys['cat_food'],
        sortOrder: 0,
      ),
      Category(
        id: 'cat_drinks',
        name: 'Drinks',
        emoji: '🥤',
        iconKey: _seedCategoryIconKeys['cat_drinks'],
        sortOrder: 1,
      ),
      Category(
        id: 'cat_snacks',
        name: 'Snacks',
        emoji: '🍟',
        iconKey: _seedCategoryIconKeys['cat_snacks'],
        sortOrder: 2,
      ),
      Category(
        id: 'cat_dessert',
        name: 'Dessert',
        emoji: '🍰',
        iconKey: _seedCategoryIconKeys['cat_dessert'],
        sortOrder: 3,
      ),
      Category(
        id: 'cat_coffee',
        name: 'Coffee',
        emoji: '☕',
        iconKey: _seedCategoryIconKeys['cat_coffee'],
        sortOrder: 4,
      ),
    ];
  }

  List<Product> _seedProducts() {
    // Image URLs: stable Unsplash photos, auto-formatted via ?w=400&q=80.
    // These gracefully degrade to icon+gradient on offline / load failure.
    const img = 'https://images.unsplash.com/photo-';
    return [
      // Food
      Product(
        id: 'p_nasi_goreng',
        name: 'Nasi Goreng Spesial',
        categoryId: 'cat_food',
        price: 25000,
        emoji: '🍳',
        iconKey: 'rice_bowl',
        imageUrl:
            '${img}1680674774705-90b4904b3a7f?auto=format&fit=crop&w=400&q=80',
        isPopular: true,
        sortOrder: 0,
        description: 'Nasi goreng dengan telur, ayam, dan kerupuk.',
      ),
      Product(
        id: 'p_mie_goreng',
        name: 'Mie Goreng',
        categoryId: 'cat_food',
        price: 22000,
        emoji: '🍜',
        iconKey: 'ramen_dining',
        imageUrl:
            '${img}1680675494363-75bbf9838a09?auto=format&fit=crop&w=400&q=80',
        isPopular: true,
        sortOrder: 1,
      ),
      Product(
        id: 'p_ayam_geprek',
        name: 'Ayam Geprek Sambal Matah',
        categoryId: 'cat_food',
        price: 28000,
        emoji: '🍗',
        iconKey: 'lunch_dining',
        imageUrl:
            '${img}1696340034876-6245523babfa?auto=format&fit=crop&w=400&q=80',
        isPopular: true,
        sortOrder: 2,
      ),
      Product(
        id: 'p_ayam_goreng',
        name: 'Ayam Goreng + Nasi',
        categoryId: 'cat_food',
        price: 23000,
        emoji: '🍗',
        iconKey: 'dinner_dining',
        imageUrl:
            '${img}1569058242253-92a9c755a0ec?auto=format&fit=crop&w=400&q=80',
        sortOrder: 3,
      ),
      Product(
        id: 'p_mie_ayam',
        name: 'Mie Ayam Bakso',
        categoryId: 'cat_food',
        price: 20000,
        emoji: '🍲',
        iconKey: 'soup_kitchen',
        imageUrl:
            '${img}1470324161839-ce2bb6fa6bc3?auto=format&fit=crop&w=400&q=80',
        sortOrder: 4,
      ),
      Product(
        id: 'p_nasi_padang',
        name: 'Nasi Padang Komplit',
        categoryId: 'cat_food',
        price: 35000,
        emoji: '🍛',
        iconKey: 'rice_bowl',
        imageUrl:
            '${img}1685186114062-68d0cb6b9e86?auto=format&fit=crop&w=400&q=80',
        sortOrder: 5,
      ),
      Product(
        id: 'p_sate_ayam',
        name: 'Sate Ayam (10 tusuk)',
        categoryId: 'cat_food',
        price: 30000,
        emoji: '🍢',
        iconKey: 'kebab_dining',
        imageUrl:
            '${img}1751212352288-d5811798804c?auto=format&fit=crop&w=400&q=80',
        sortOrder: 6,
      ),
      Product(
        id: 'p_gado_gado',
        name: 'Gado-gado',
        categoryId: 'cat_food',
        price: 18000,
        emoji: '🥗',
        iconKey: 'restaurant',
        imageUrl:
            '${img}1512621776951-a57141f2eefd?auto=format&fit=crop&w=400&q=80',
        sortOrder: 7,
      ),

      // Drinks
      Product(
        id: 'p_es_teh',
        name: 'Es Teh Manis',
        categoryId: 'cat_drinks',
        price: 5000,
        emoji: '🧊',
        iconKey: 'local_drink',
        imageUrl:
            '${img}1556679343-c7306c1976bc?auto=format&fit=crop&w=400&q=80',
        isPopular: true,
        sortOrder: 0,
      ),
      Product(
        id: 'p_es_jeruk',
        name: 'Es Jeruk',
        categoryId: 'cat_drinks',
        price: 8000,
        emoji: '🍊',
        iconKey: 'local_drink',
        imageUrl:
            '${img}1547514701-42782101795e?auto=format&fit=crop&w=400&q=80',
        sortOrder: 1,
      ),
      Product(
        id: 'p_air_mineral',
        name: 'Air Mineral',
        categoryId: 'cat_drinks',
        price: 4000,
        emoji: '💧',
        iconKey: 'water_drop',
        imageUrl:
            '${img}1548839140-29a749e1cf4d?auto=format&fit=crop&w=400&q=80',
        sortOrder: 2,
      ),
      Product(
        id: 'p_lemon_tea',
        name: 'Lemon Tea',
        categoryId: 'cat_drinks',
        price: 12000,
        emoji: '🍋',
        iconKey: 'local_cafe',
        imageUrl:
            '${img}1656936637945-571e3f0893f9?auto=format&fit=crop&w=400&q=80',
        isPopular: true,
        sortOrder: 3,
      ),
      Product(
        id: 'p_soft_drink',
        name: 'Soft Drink',
        categoryId: 'cat_drinks',
        price: 10000,
        emoji: '🥤',
        iconKey: 'local_bar',
        imageUrl:
            '${img}1624552184280-9e9631bbeee9?auto=format&fit=crop&w=400&q=80',
        sortOrder: 4,
      ),
      Product(
        id: 'p_jus_alpukat',
        name: 'Jus Alpukat',
        categoryId: 'cat_drinks',
        price: 15000,
        emoji: '🥑',
        iconKey: 'local_drink',
        imageUrl:
            '${img}1546173159-315724a31696?auto=format&fit=crop&w=400&q=80',
        sortOrder: 5,
      ),

      // Snacks
      Product(
        id: 'p_kentang',
        name: 'Kentang Goreng',
        categoryId: 'cat_snacks',
        price: 18000,
        emoji: '🍟',
        iconKey: 'lunch_dining',
        imageUrl:
            '${img}1573080496219-bb080dd4f877?auto=format&fit=crop&w=400&q=80',
        isPopular: true,
        sortOrder: 0,
      ),
      Product(
        id: 'p_pisang_goreng',
        name: 'Pisang Goreng Keju',
        categoryId: 'cat_snacks',
        price: 15000,
        emoji: '🍌',
        iconKey: 'bakery_dining',
        imageUrl:
            '${img}1563336522-c3bd728d3b45?auto=format&fit=crop&w=400&q=80',
        sortOrder: 1,
      ),
      Product(
        id: 'p_roti_bakar',
        name: 'Roti Bakar Coklat',
        categoryId: 'cat_snacks',
        price: 14000,
        emoji: '🍞',
        iconKey: 'bakery_dining',
        imageUrl:
            '${img}1631294012419-2d5ee9da5f5c?auto=format&fit=crop&w=400&q=80',
        sortOrder: 2,
      ),
      Product(
        id: 'p_dimsum',
        name: 'Dimsum Ayam (5 pcs)',
        categoryId: 'cat_snacks',
        price: 20000,
        emoji: '🥟',
        iconKey: 'dinner_dining',
        imageUrl:
            '${img}1604632910793-c0601f361b34?auto=format&fit=crop&w=400&q=80',
        isPopular: true,
        sortOrder: 3,
      ),
      Product(
        id: 'p_risol',
        name: 'Risol Mayo (3 pcs)',
        categoryId: 'cat_snacks',
        price: 12000,
        emoji: '🥧',
        iconKey: 'bakery_dining',
        imageUrl:
            '${img}1769254870299-338bfd99aabd?auto=format&fit=crop&w=400&q=80',
        sortOrder: 4,
      ),

      // Dessert
      Product(
        id: 'p_es_krim',
        name: 'Es Krim Vanilla',
        categoryId: 'cat_dessert',
        price: 12000,
        emoji: '🍦',
        iconKey: 'icecream',
        imageUrl:
            '${img}1497034825429-c343d7c6a68f?auto=format&fit=crop&w=400&q=80',
        sortOrder: 0,
      ),
      Product(
        id: 'p_pudding',
        name: 'Pudding Coklat',
        categoryId: 'cat_dessert',
        price: 13000,
        emoji: '🍮',
        iconKey: 'cake',
        imageUrl:
            '${img}1488477181946-6428a0291777?auto=format&fit=crop&w=400&q=80',
        sortOrder: 1,
      ),
      Product(
        id: 'p_brownies',
        name: 'Brownies Coklat',
        categoryId: 'cat_dessert',
        price: 18000,
        emoji: '🍫',
        iconKey: 'cake',
        imageUrl:
            '${img}1606312619070-d48b4c652a52?auto=format&fit=crop&w=400&q=80',
        isPopular: true,
        sortOrder: 2,
      ),

      // Coffee
      Product(
        id: 'p_kopi_hitam',
        name: 'Kopi Hitam',
        categoryId: 'cat_coffee',
        price: 10000,
        emoji: '☕',
        iconKey: 'coffee',
        imageUrl:
            '${img}1514432324607-a09d9b4aefdd?auto=format&fit=crop&w=400&q=80',
        sortOrder: 0,
      ),
      Product(
        id: 'p_kopi_susu',
        name: 'Es Kopi Susu',
        categoryId: 'cat_coffee',
        price: 18000,
        emoji: '🧋',
        iconKey: 'local_cafe',
        imageUrl:
            '${img}1461023058943-07fcbe16d735?auto=format&fit=crop&w=400&q=80',
        isPopular: true,
        sortOrder: 1,
      ),
      Product(
        id: 'p_cappuccino',
        name: 'Cappuccino',
        categoryId: 'cat_coffee',
        price: 22000,
        emoji: '☕',
        iconKey: 'coffee',
        imageUrl:
            '${img}1572442388796-11668a67e53d?auto=format&fit=crop&w=400&q=80',
        sortOrder: 2,
      ),
      Product(
        id: 'p_latte',
        name: 'Caffe Latte',
        categoryId: 'cat_coffee',
        price: 24000,
        emoji: '☕',
        iconKey: 'coffee',
        imageUrl:
            '${img}1509042239860-f550ce710b93?auto=format&fit=crop&w=400&q=80',
        sortOrder: 3,
      ),
    ];
  }

  List<RestaurantTable> _seedTables() {
    return [
      RestaurantTable(
        id: 't_1',
        name: 'Meja 1',
        capacity: 2,
        floor: 'floor_1',
        sortOrder: 0,
      ),
      RestaurantTable(
        id: 't_2',
        name: 'Meja 2',
        capacity: 2,
        floor: 'floor_1',
        sortOrder: 1,
      ),
      RestaurantTable(
        id: 't_3',
        name: 'Meja 3',
        capacity: 4,
        floor: 'floor_1',
        sortOrder: 2,
      ),
      RestaurantTable(
        id: 't_4',
        name: 'Meja 4',
        capacity: 4,
        floor: 'floor_1',
        sortOrder: 3,
      ),
      RestaurantTable(
        id: 't_5',
        name: 'Meja 5',
        capacity: 6,
        floor: 'floor_1',
        sortOrder: 4,
      ),
      RestaurantTable(
        id: 't_6',
        name: 'Meja 6',
        capacity: 8,
        floor: 'floor_2',
        sortOrder: 5,
      ),
      RestaurantTable(
        id: 't_7',
        name: 'Meja 7',
        capacity: 4,
        floor: 'floor_2',
        sortOrder: 6,
      ),
      RestaurantTable(
        id: 't_8',
        name: 'VIP Room',
        capacity: 10,
        floor: 'floor_3',
        sortOrder: 7,
      ),
      // ── Added in v12, when the demo grew from a warung's eight tables to a
      // full restaurant's floor plan. The original eight keep their ids,
      // names and floors untouched: `orders.table_name` is a snapshot, so
      // renaming one would leave the history pointing at a table that never
      // existed under that name.
      //
      // Numbering runs per section rather than per floor, which is why
      // Lantai 1 holds Meja 1–5 and 8–15 while 6–7 sit upstairs. That is how
      // a room actually gets numbered once it is extended.
      ..._moreTables(
        floor: 'floor_1',
        startId: 9,
        startSort: 8,
        names: [
          'Meja 8',
          'Meja 9',
          'Meja 10',
          'Meja 11',
          'Meja 12',
          'Meja 13',
          'Meja 14',
          'Meja 15',
        ],
        capacities: [2, 4, 4, 4, 6, 6, 8, 8],
      ),
      ..._moreTables(
        floor: 'floor_2',
        startId: 17,
        startSort: 16,
        names: [
          'Meja 16',
          'Meja 17',
          'Meja 18',
          'Meja 19',
          'Meja 20',
          'Meja 21',
        ],
        capacities: [4, 4, 6, 6, 8, 12],
      ),
      ..._moreTables(
        floor: 'floor_3',
        startId: 23,
        startSort: 22,
        names: ['VIP 2', 'VIP 3', 'VIP 4'],
        capacities: [10, 12, 20],
      ),
      ..._moreTables(
        floor: 'floor_4',
        startId: 26,
        startSort: 25,
        names: [
          'Teras 1',
          'Teras 2',
          'Teras 3',
          'Teras 4',
          'Teras 5',
          'Teras 6',
        ],
        capacities: [2, 2, 4, 4, 6, 6],
      ),
    ];
  }

  /// Builds a contiguous block of tables so the floor plan reads as data
  /// rather than as forty lines of near-identical constructor calls.
  static List<RestaurantTable> _moreTables({
    required String floor,
    required int startId,
    required int startSort,
    required List<String> names,
    required List<int> capacities,
  }) => [
    for (var i = 0; i < names.length; i++)
      RestaurantTable(
        id: 't_${startId + i}',
        name: names[i],
        capacity: capacities[i],
        floor: floor,
        sortOrder: startSort + i,
      ),
  ];
}

/// One seeded order. Private to the seeding path — once written, the app reads
/// these rows back through [OrderRepository] like any other order.
class _SeedOrderSpec {
  const _SeedOrderSpec({
    required this.daysAgo,
    required this.hour,
    required this.minute,
    required this.type,
    required this.payment,
    required this.status,
    required this.items,
    this.tableId,
    this.customerName,
    this.discount = 0,
    this.authorizedBy,
    this.voidReason,
  });

  final int daysAgo;
  final int hour;
  final int minute;
  final OrderType type;
  final PaymentMethod payment;
  final OrderStatus status;
  final List<_SeedOrderItem> items;
  final String? tableId;
  final String? customerName;
  final int discount;

  /// Who approved a void or refund. Null on an ordinary sale.
  final String? authorizedBy;

  /// Why it was voided. Null on a refund, which is explained by the amount.
  final String? voidReason;

  _SeedOrderSpec withStatus(
    OrderStatus status, {
    OrderType? type,
    String? tableId,
  }) => _SeedOrderSpec(
    daysAgo: daysAgo,
    hour: hour,
    minute: minute,
    type: type ?? this.type,
    payment: payment,
    status: status,
    items: items,
    tableId: tableId ?? this.tableId,
    // A dine-in order is identified by its table, not by a name taken at the
    // counter; leaving one behind would print both on the receipt.
    customerName: type == OrderType.dineIn ? null : customerName,
    discount: discount,
    authorizedBy: authorizedBy,
    voidReason: voidReason,
  );

  _SeedOrderSpec settled({
    required OrderStatus status,
    required String authorizedBy,
    String? voidReason,
  }) => _SeedOrderSpec(
    daysAgo: daysAgo,
    hour: hour,
    minute: minute,
    type: type,
    payment: payment,
    status: status,
    items: items,
    tableId: tableId,
    customerName: customerName,
    discount: discount,
    authorizedBy: authorizedBy,
    voidReason: voidReason,
  );
}

class _SeedOrderItem {
  const _SeedOrderItem(this.productId, this.qty);
  final String productId;
  final int qty;
}
