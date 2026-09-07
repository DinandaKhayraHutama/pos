import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/empty_state.dart';
import 'package:nti_pos/core/widgets/glass/glass_card.dart';
import 'package:nti_pos/core/widgets/glass/glass_sheet.dart';
import 'package:nti_pos/core/widgets/glass/skeleton.dart';
import 'package:nti_pos/data/models/category.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/features/products/product_form_sheet.dart';
import 'package:nti_pos/features/products/product_management_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/catalog_provider.dart';

/// Widget tests for [ProductManagementPage].
///
/// Locale-agnostic by design:
/// - Product names ('Nasi Goreng', 'Es Teh') and category names ('Makanan',
///   'Minuman') are DATA — caller-invented strings, not localized labels. They
///   are asserted verbatim.
/// - Formatted prices ('Rp 45.000') are deterministic output of
///   [MoneyFormatter.format] — DATA.
/// - Tabs are matched by index in the TabBar (products=0, categories=1),
///   never by their localized text.
/// - The confirm dialog is matched by widget type ([AlertDialog],
///   [FilledButton], [TextButton]) — its title / button labels are localized.
/// - The form sheets are matched by type ([ProductFormSheet],
///   [GlassSheet]) — never by their localized titles.
/// - Empty / loading branches are matched by widget type ([EmptyState],
///   [Skeleton]) plus the [IconData] the empty state paints.
///
/// The catalog providers ([productsProvider], [categoriesProvider]) are
/// `AsyncNotifierProvider.autoDispose`. Each test overrides them with a fake
/// whose `build` returns the seeded list, and the spy variants record
/// `upsert` / `delete` calls without touching sqflite.
class _FakeProductsNotifier extends ProductsNotifier {
  _FakeProductsNotifier(this._data);
  final List<Product> _data;
  @override
  Future<List<Product>> build() async => _data;
}

class _FakeCategoriesNotifier extends CategoriesNotifier {
  _FakeCategoriesNotifier(this._data);
  final List<Category> _data;
  @override
  Future<List<Category>> build() async => _data;
}

/// Spy that records `upsert` / `delete` calls without touching sqflite.
/// Used by the toggle / delete tests to verify the notifier receives the
/// right payload.
class _SpyProductsNotifier extends ProductsNotifier {
  _SpyProductsNotifier(this._data);
  final List<Product> _data;
  final List<Product> upsertCalls = [];
  final List<String> deleteCalls = [];

  @override
  Future<List<Product>> build() async => _data;

  @override
  Future<void> upsert(Product p) async => upsertCalls.add(p);

  @override
  Future<void> delete(String id) async => deleteCalls.add(id);
}

class _SpyCategoriesNotifier extends CategoriesNotifier {
  _SpyCategoriesNotifier(this._data);
  final List<Category> _data;
  final List<String> deleteCalls = [];

  @override
  Future<List<Category>> build() async => _data;

  @override
  Future<void> delete(String id) async => deleteCalls.add(id);
}

/// Fake whose `build` never completes so the provider stays in AsyncLoading.
class _HangingProductsNotifier extends ProductsNotifier {
  _HangingProductsNotifier();
  @override
  Future<List<Product>> build() => Completer<List<Product>>().future;
}

Category _cat({required String id, required String name}) =>
    Category(id: id, name: name, emoji: '🍽️', iconKey: 'restaurant');

Product _product({
  required String id,
  required String name,
  required String categoryId,
  int price = 45000,
  bool available = true,
}) =>
    Product(
      id: id,
      name: name,
      categoryId: categoryId,
      price: price,
      iconKey: 'restaurant',
      available: available,
    );

final _cat1 = _cat(id: 'c1', name: 'Makanan');
final _cat2 = _cat(id: 'c2', name: 'Minuman');

List<Product> _seedProducts() => [
      _product(
        id: 'p1',
        name: 'Nasi Goreng',
        categoryId: 'c1',
        price: 45000,
        available: true,
      ),
      _product(
        id: 'p2',
        name: 'Es Teh',
        categoryId: 'c2',
        price: 10000,
        available: false,
      ),
    ];

List<Category> _seedCategories() => [_cat1, _cat2];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpManagement(
    WidgetTester tester, {
    List<Override> extraOverrides = const [],
    bool settle = true,
  }) async {
    final brand = BrandPreset.presets.first;
    container = ProviderContainer(overrides: extraOverrides);
    addTearDown(container.dispose);

    // Phone-class surface. The page is a TabBarView; no tablet split.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(brand),
          locale: const Locale('en'),
          supportedLocales: kSupportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const ProductManagementPage(),
        ),
      ),
    );
    // Skeleton shimmer ticker loops forever — loading tests pass settle:false
    // and let the first frame land. Once AsyncData resolves, no Skeleton is
    // mounted and pumpAndSettle returns normally.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  /// Standard data overrides: both catalog providers resolve to the seeded
  /// `AsyncData`.
  List<Override> dataOverrides({
    List<Product>? products,
    List<Category>? categories,
  }) =>
      [
        productsProvider.overrideWith(
          () => _FakeProductsNotifier(products ?? _seedProducts()),
        ),
        categoriesProvider.overrideWith(
          () => _FakeCategoriesNotifier(categories ?? _seedCategories()),
        ),
      ];

  group('products tab', () {
    testWidgets(
        'renders one tile per seeded product with its name, formatted price '
        'and category name (all data); plus an add FAB', (tester) async {
      await pumpManagement(tester, extraOverrides: dataOverrides());

      // Names are caller-invented data.
      expect(find.text('Nasi Goreng'), findsOneWidget);
      expect(find.text('Es Teh'), findsOneWidget);

      // Formatted prices are deterministic data: format(45000) = 'Rp 45.000'.
      expect(find.text('Rp 45.000'), findsOneWidget);
      expect(find.text('Rp 10.000'), findsOneWidget);

      // Category name on each tile is also data.
      expect(find.text('Makanan'), findsOneWidget);
      expect(find.text('Minuman'), findsOneWidget);

      // The product icon resolves from iconKey='restaurant' → leading icon.
      // Two leading icons in the tiles + the FAB's add icon (no other
      // restaurant_rounded icons paint on the page).
      expect(find.byIcon(Icons.restaurant_rounded), findsNWidgets(2));

      // FAB is matched by type — its label is localized.
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets(
        'tapping the availability switch calls upsert with available:false '
        'on the first product', (tester) async {
      final spy = _SpyProductsNotifier(_seedProducts());
      await pumpManagement(
        tester,
        extraOverrides: [
          productsProvider.overrideWith(() => spy),
          categoriesProvider.overrideWith(
            () => _FakeCategoriesNotifier(_seedCategories()),
          ),
        ],
      );

      // Locate the first product's tile by its name, then the Switch within.
      final card = find.ancestor(
        of: find.text('Nasi Goreng'),
        matching: find.byType(GlassCard),
      );
      expect(card, findsOneWidget);
      final toggle = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      expect(toggle, findsOneWidget);

      await tester.tap(toggle);
      await tester.pumpAndSettle();

      // Spy captured one upsert call with the same id and flipped availability.
      expect(spy.upsertCalls, hasLength(1));
      expect(spy.upsertCalls.single.id, 'p1');
      expect(spy.upsertCalls.single.available, false);
      // Other fields preserved by copyWith.
      expect(spy.upsertCalls.single.name, 'Nasi Goreng');
      expect(spy.upsertCalls.single.price, 45000);
    });

    testWidgets(
        'tapping delete opens a confirm dialog; confirming calls delete(p1) '
        'on the notifier', (tester) async {
      final spy = _SpyProductsNotifier(_seedProducts());
      await pumpManagement(
        tester,
        extraOverrides: [
          productsProvider.overrideWith(() => spy),
          categoriesProvider.overrideWith(
            () => _FakeCategoriesNotifier(_seedCategories()),
          ),
        ],
      );

      // The delete IconButton sits inside the same tile as the product name.
      final card = find.ancestor(
        of: find.text('Nasi Goreng'),
        matching: find.byType(GlassCard),
      );
      final deleteBtn = find.descendant(
        of: card,
        matching: find.byIcon(Icons.delete_outline_rounded),
      );
      expect(deleteBtn, findsOneWidget);

      await tester.tap(deleteBtn);
      await tester.pumpAndSettle();

      // Confirm dialog mounts with TextButton (cancel) + FilledButton (delete),
      // matched by type — never by their localized labels.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);

      expect(spy.deleteCalls, isEmpty);

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      // Dialog dismissed and the spy recorded delete('p1').
      expect(find.byType(AlertDialog), findsNothing);
      expect(spy.deleteCalls, ['p1']);
    });

    testWidgets(
        'cancelling the delete dialog dismisses without calling delete',
        (tester) async {
      final spy = _SpyProductsNotifier(_seedProducts());
      await pumpManagement(
        tester,
        extraOverrides: [
          productsProvider.overrideWith(() => spy),
          categoriesProvider.overrideWith(
            () => _FakeCategoriesNotifier(_seedCategories()),
          ),
        ],
      );

      final card = find.ancestor(
        of: find.text('Nasi Goreng'),
        matching: find.byType(GlassCard),
      );
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byIcon(Icons.delete_outline_rounded),
        ),
      );
      await tester.pumpAndSettle();

      // Cancel = TextButton (first action in the dialog).
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(spy.deleteCalls, isEmpty);
    });

    testWidgets(
        'tapping the FAB opens the ProductFormSheet in a GlassSheet',
        (tester) async {
      await pumpManagement(tester, extraOverrides: dataOverrides());

      expect(find.byType(ProductFormSheet), findsNothing);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Form sheet is mounted. Matched by type — never by localized title.
      expect(find.byType(ProductFormSheet), findsOneWidget);
    });
  });

  group('categories tab', () {
    // Switching to the categories tab: the TabBar paints two Tab widgets in
    // declaration order (products=0, categories=1). Drive the switch by
    // tapping the second Tab, identified by index — the tab labels are
    // localized and never asserted.
    Future<void> goToCategories(WidgetTester tester) async {
      await tester.tap(find.byType(Tab).at(1));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'renders one tile per seeded category with its name (data); plus an '
        'add FAB', (tester) async {
      await pumpManagement(tester, extraOverrides: dataOverrides());

      await goToCategories(tester);

      // Category names are data.
      expect(find.text('Makanan'), findsOneWidget);
      expect(find.text('Minuman'), findsOneWidget);

      // Each tile paints a delete IconButton.
      expect(
        find.byIcon(Icons.delete_outline_rounded),
        findsNWidgets(2),
      );

      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets(
        'tapping delete on a category opens a confirm dialog; confirming '
        'calls delete(c1) on the notifier', (tester) async {
      final spy = _SpyCategoriesNotifier(_seedCategories());
      await pumpManagement(
        tester,
        extraOverrides: [
          productsProvider.overrideWith(
            () => _FakeProductsNotifier(_seedProducts()),
          ),
          categoriesProvider.overrideWith(() => spy),
        ],
      );

      await goToCategories(tester);

      // First category's delete button — scoped to its tile.
      final card = find.ancestor(
        of: find.text('Makanan'),
        matching: find.byType(GlassCard),
      );
      expect(card, findsOneWidget);
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byIcon(Icons.delete_outline_rounded),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);

      expect(spy.deleteCalls, isEmpty);

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(spy.deleteCalls, ['c1']);
    });

    testWidgets(
        'tapping the categories FAB opens a GlassSheet (category form)',
        (tester) async {
      await pumpManagement(tester, extraOverrides: dataOverrides());

      await goToCategories(tester);

      // Before tapping, no GlassSheet is mounted (the page itself uses
      // GlassCards but no GlassSheet wrapper).
      expect(find.byType(GlassSheet), findsNothing);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // _CategoryFormSheet is private — assert via GlassSheet presence.
      expect(find.byType(GlassSheet), findsOneWidget);
    });
  });

  group('empty & loading', () {
    testWidgets(
        'empty product list renders the EmptyState with the restaurant icon',
        (tester) async {
      await pumpManagement(
        tester,
        extraOverrides: dataOverrides(
          products: const [],
          categories: _seedCategories(),
        ),
      );

      // Default tab is products — its empty branch paints EmptyState with
      // Icons.restaurant_rounded.
      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.byIcon(Icons.restaurant_rounded), findsOneWidget);
      // No product tiles.
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    });

    testWidgets(
        'AsyncLoading paints the Skeleton bars and no tiles',
        (tester) async {
      await pumpManagement(
        tester,
        settle: false,
        extraOverrides: [
          productsProvider.overrideWith(() => _HangingProductsNotifier()),
          categoriesProvider.overrideWith(
            () => _FakeCategoriesNotifier(_seedCategories()),
          ),
        ],
      );

      // _ProductsTab loading branch paints LoadingIndicator.skeleton(lines: 6).
      // (Do not pumpAndSettle: the _Shimmer ticker loops forever.)
      expect(find.byType(Skeleton), findsNWidgets(6));
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
    });
  });
}
