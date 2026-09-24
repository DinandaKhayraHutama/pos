import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/models/table.dart';
import 'package:nti_pos/data/preferences/app_preferences.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/table_repository.dart';
import 'package:nti_pos/providers/bill_provider.dart';
import 'package:nti_pos/providers/cart_provider.dart';
import 'package:nti_pos/providers/order_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

import '../helpers/db_helper.dart';
import '../helpers/provider_helpers.dart';

/// These exercise one branch's board. Per-outlet separation has its own
/// coverage; threading a second outlet through every case here would only
/// obscure what is being asserted.
const _outlet = 'outlet-1';

const _product = Product(
  id: 'p_test',
  name: 'Nasi Test',
  categoryId: 'cat_food',
  price: 25000,
  iconKey: 'rice_bowl',
);

const _table = RestaurantTable(
        outletId: _outlet,
  id: 't_test',
  name: 'Meja Test',
  capacity: 4,
);

Future<void> _seed(Database db) async {
  await db.insert('categories', {
    'id': 'cat_food',
    'name': 'Food',
    'icon_key': 'set_meal',
    'sort_order': 0,
    'is_popular': 0,
  });
  await db.insert('products', _product.toMap());
  await db.insert('tables', _table.toMap());
}

/// Subscribes a listener that increments [counter] on any state transition
/// of [provider]. Used to detect whether `ref.invalidate(provider)` fired —
/// invalidation causes the autoDispose provider to rebuild, which emits at
/// least one new AsyncValue (loading → data).
ProviderSubscription<T> _countRebuilds<T>(
  ProviderContainer container,
  ProviderListenable<T> provider,
  Counter counter,
) {
  return container.listen<T>(provider, (_, _) => counter.value++);
}

class Counter {
  int value = 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Database? db;
  late ProviderContainer container;

  setUp(() async {
    db = await openInMemoryAppDb(seed: false);
    // Route the singleton-backed repos at the in-memory DB.
    await AppDatabase.instance.useTestDb(db!);
    await _seed(db!);

    // Settings provider needs prefs (cashier name, tax rate). Seed before
    // the singleton caches; resetForTest ensures the next instance() reads
    // the mocked store.
    AppPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({
      'logged_in': true,
      'cashier_name': 'Kasir Test',
      'tax_rate': 11.0,
      'store_name': 'Warung Test',
      'store_address': 'Jl. Test',
      'currency': 'Rp',
      'theme_mode': 'system',
      'brand_id': 'flame',
      'locale_code': 'en',
    });

    // The legacy checkout: a connected outlet that has not switched saved
    // bills on still sells this way. The bill checkout (the demo's default)
    // has its own cases in bill_checkout_test.dart.
    container = makeContainer(
      overrides: [billsEnabledProvider.overrideWith((ref) => false)],
    );
  });

  tearDown(() async {
    container.dispose();
    if (db != null && db!.isOpen) {
      await db!.close();
    }
    // Drop the singleton cache so the next test starts clean.
    AppPreferences.resetForTest();
  });

  group('placeOrderFromCart — dine-in', () {
    test('writes the order, marks table occupied, invalidates dependent '
        'providers', () async {
      // Settings must be loaded before placeOrderFromCart reads it.
      await container.read(settingsProvider.future);

      final orderCounter = Counter();
      final tableCounter = Counter();
      final dashboardCounter = Counter();
      final topProductsCounter = Counter();
      _countRebuilds<AsyncValue<List<Order>>>(
        container,
        ordersProvider(null),
        orderCounter,
      );
      _countRebuilds<AsyncValue<List<RestaurantTable>>>(
        container,
        tablesProvider,
        tableCounter,
      );
      _countRebuilds<AsyncValue<({int revenue, int count, int itemsSold})>>(
        container,
        dashboardSummaryProvider,
        dashboardCounter,
      );
      _countRebuilds<
        AsyncValue<
          List<({String name, String? iconKey, int qty, int revenue})>
        >
      >(
        container,
        topProductsProvider,
        topProductsCounter,
      );

      // Force initial builds to complete so the baseline is stable.
      await container.read(ordersProvider(null).future);
      await container.read(tablesProvider.future);
      await container.read(dashboardSummaryProvider.future);
      await container.read(topProductsProvider.future);
      final baselineOrders = orderCounter.value;
      final baselineTables = tableCounter.value;
      final baselineDashboard = dashboardCounter.value;
      final baselineTopProducts = topProductsCounter.value;

      // Build a dine-in cart with one line for the seeded product + table.
      final cart = container.read(cartProvider.notifier);
      cart.add(_product, qty: 2);
      cart.setType(OrderType.dineIn);
      cart.setTable(_table);

      // Sanity-check cart math before exercising the function under test.
      // subtotal 50000, tax 11% = 5500, total 55500.
      expect(container.read(cartProvider).subtotal, 50000);

      final order = await placeOrderFromCart(
        read: container.read,
        invalidate: container.invalidate,
      );

      // (a) Order persisted to the in-memory DB.
      final allOrders = await OrderRepository.instance.recent();
      expect(allOrders, hasLength(1));
      expect(allOrders.first.id, order.id);
      expect(allOrders.first.total, 55500);
      expect(allOrders.first.items, isEmpty); // recent() doesn't join items

      final byId = await OrderRepository.instance.byId(order.id);
      expect(byId, isNotNull);
      expect(byId!.items, hasLength(1));
      expect(byId.items.first.productId, _product.id);
      expect(byId.items.first.quantity, 2);

      // (b) Table flipped to occupied for the demo.
      final tables = await TableRepository.instance.byOutlet(_outlet);
      final t = tables.firstWhere((t) => t.id == _table.id);
      expect(t.status, TableStatus.occupied);

      // (c) ordersProvider was invalidated → listener fires again.
      expect(orderCounter.value, greaterThan(baselineOrders));

      // (d) tablesProvider was invalidated for dine-in → listener fires again.
      expect(tableCounter.value, greaterThan(baselineTables));

      // (e) Dashboard + top products invalidate on every placed order
      //     (revenue / count / avg + top product mix all changed).
      expect(dashboardCounter.value, greaterThan(baselineDashboard));
      expect(topProductsCounter.value, greaterThan(baselineTopProducts));

      // (f) Cart was cleared.
      expect(container.read(cartProvider).isEmpty, isTrue);
    });
  });

  group('placeOrderFromCart — takeaway', () {
    test('writes the order, does NOT touch tables, does NOT invalidate '
        'tablesProvider', () async {
      await container.read(settingsProvider.future);

      final orderCounter = Counter();
      final tableCounter = Counter();
      final dashboardCounter = Counter();
      final topProductsCounter = Counter();
      _countRebuilds<AsyncValue<List<Order>>>(
        container,
        ordersProvider(null),
        orderCounter,
      );
      _countRebuilds<AsyncValue<List<RestaurantTable>>>(
        container,
        tablesProvider,
        tableCounter,
      );
      _countRebuilds<AsyncValue<({int revenue, int count, int itemsSold})>>(
        container,
        dashboardSummaryProvider,
        dashboardCounter,
      );
      _countRebuilds<
        AsyncValue<
          List<({String name, String? iconKey, int qty, int revenue})>
        >
      >(
        container,
        topProductsProvider,
        topProductsCounter,
      );

      await container.read(ordersProvider(null).future);
      await container.read(tablesProvider.future);
      await container.read(dashboardSummaryProvider.future);
      await container.read(topProductsProvider.future);
      final baselineOrders = orderCounter.value;
      final baselineTables = tableCounter.value;
      final baselineDashboard = dashboardCounter.value;
      final baselineTopProducts = topProductsCounter.value;

      final cart = container.read(cartProvider.notifier);
      cart.add(_product, qty: 1);
      cart.setType(OrderType.takeaway);
      // No table assigned — setType(takeaway) clears any table anyway.

      final order = await placeOrderFromCart(
        read: container.read,
        invalidate: container.invalidate,
      );

      // Order persisted.
      final allOrders = await OrderRepository.instance.recent();
      expect(allOrders, hasLength(1));
      expect(allOrders.first.id, order.id);

      // Table remains available (no write, no invalidation).
      final tables = await TableRepository.instance.byOutlet(_outlet);
      expect(tables.firstWhere((t) => t.id == _table.id).status,
          TableStatus.available);

      // ordersProvider invalidated.
      expect(orderCounter.value, greaterThan(baselineOrders));

      // Dashboard + top products still invalidate on takeaway — revenue,
      // count, avg + top product mix all changed even without a table.
      expect(dashboardCounter.value, greaterThan(baselineDashboard));
      expect(topProductsCounter.value, greaterThan(baselineTopProducts));

      // tablesProvider NOT invalidated — no extra state transitions.
      expect(tableCounter.value, baselineTables);
    });
  });

  group('placeOrderFromCart — empty cart', () {
    test('throws StateError and writes no order', () async {
      await container.read(settingsProvider.future);

      expect(
        () => placeOrderFromCart(
          read: container.read,
          invalidate: container.invalidate,
        ),
        throwsA(isA<StateError>()),
      );

      final allOrders = await OrderRepository.instance.recent();
      expect(allOrders, isEmpty);
    });
  });
}
