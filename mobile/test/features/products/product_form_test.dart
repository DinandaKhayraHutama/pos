import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_sheet.dart';
import 'package:nti_pos/data/models/category.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/features/products/product_form_sheet.dart';
import 'package:nti_pos/features/products/product_management_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/catalog_provider.dart';

/// Widget tests for the product & category form sheets.
///
/// The forms are reached from [ProductManagementPage]'s per-tab FAB:
/// - Products tab → [ProductFormSheet] (public)
/// - Categories tab → `_CategoryFormSheet` (private, lives inside
///   `product_management_page.dart`)
///
/// Locale-agnostic by design:
/// - Form text fields are matched by TYPE ([TextField]) and INDEX in the
///   declaration order of [ProductFormSheet] (0=name, 1=price, 2=description).
///   The category form has exactly one [TextField] (name).
/// - The category picker chips in the product form are matched by their
///   data Text (the category's own name) scoped to the [GlassSheet], so the
///   assertion never collides with the same name painted by the product tile
///   underneath the modal.
/// - The save button is matched by type ([FilledButton]); its label is
///   localized.
/// - The "empty name" no-op path is verified by the spy notifier recording
///   zero `upsert` calls AND (product form only) a [SnackBar] mounting — the
///   category form's `_save` returns silently with no snack.
///
/// Both catalog providers are overridden with fakes / spies that never touch
/// sqflite. The spy's `build` returns the seeded list so the management page
/// underneath the modal keeps rendering data while the form is open.
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

/// Spy that records `upsert` calls without touching sqflite, so the form's
/// save path is verifiable end-to-end.
class _SpyProductsNotifier extends ProductsNotifier {
  _SpyProductsNotifier(this._data);
  final List<Product> _data;
  final List<Product> upsertCalls = [];

  @override
  Future<List<Product>> build() async => _data;

  @override
  Future<void> upsert(Product p) async => upsertCalls.add(p);
}

class _SpyCategoriesNotifier extends CategoriesNotifier {
  _SpyCategoriesNotifier(this._data);
  final List<Category> _data;
  final List<Category> upsertCalls = [];

  @override
  Future<List<Category>> build() async => _data;

  @override
  Future<void> upsert(Category c) async => upsertCalls.add(c);
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
      _product(id: 'p1', name: 'Nasi Goreng', categoryId: 'c1', price: 45000),
      _product(id: 'p2', name: 'Es Teh', categoryId: 'c2', price: 10000),
    ];

List<Category> _seedCategories() => [_cat1, _cat2];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpManagement(
    WidgetTester tester, {
    required List<Override> overrides,
  }) async {
    final brand = BrandPreset.presets.first;
    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);

    // Phone-class surface. The form sits in a modal bottom sheet — needs
    // enough vertical room for the icon picker grid + fields + save button.
    tester.view.physicalSize = const Size(800, 1800);
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
    await tester.pumpAndSettle();
  }

  /// Opens the product form via the products-tab FAB. Caller pumps the
  /// management page first with the spy overrides.
  Future<void> openProductForm(WidgetTester tester) async {
    expect(find.byType(ProductFormSheet), findsNothing);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(ProductFormSheet), findsOneWidget);
  }

  /// Switches to the categories tab (index 1 in the TabBar) and taps its FAB
  /// to mount `_CategoryFormSheet`. The category form is private, so we
  /// assert the modal via [GlassSheet].
  Future<void> openCategoryForm(WidgetTester tester) async {
    // Categories tab is the second Tab in declaration order.
    await tester.tap(find.byType(Tab).at(1));
    await tester.pumpAndSettle();

    expect(find.byType(GlassSheet), findsNothing);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSheet), findsOneWidget);
  }

  group('product form — save path', () {
    testWidgets(
        'filling name + price + picking a category chip and tapping save '
        'calls upsert with the entered fields', (tester) async {
      final spy = _SpyProductsNotifier(_seedProducts());
      await pumpManagement(
        tester,
        overrides: [
          productsProvider.overrideWith(() => spy),
          categoriesProvider.overrideWith(
            () => _FakeCategoriesNotifier(_seedCategories()),
          ),
        ],
      );

      await openProductForm(tester);

      // Fields are matched by their label rather than by index. The form grew
      // cost / SKU / stock alongside name, price and description, and an
      // index-based lookup silently starts typing into the wrong box the next
      // time a field is inserted above another.
      Finder fieldLabelled(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(TextField),
      );

      await tester.enterText(fieldLabelled('Product name'), 'Mie Goreng');
      await tester.pumpAndSettle();

      await tester.enterText(fieldLabelled('Price'), '37500');
      await tester.pumpAndSettle();

      // Category picker chips live inside the GlassSheet. Each chip carries
      // the category's data name. Scope to the sheet so the assertion does
      // not collide with the same name painted by the product tile beneath
      // the modal.
      final chip = find.descendant(
        of: find.byType(GlassSheet),
        matching: find.text('Makanan'),
      );
      expect(chip, findsOneWidget);
      await tester.tap(chip);
      await tester.pumpAndSettle();

      expect(spy.upsertCalls, isEmpty);

      // Save = the only FilledButton on the sheet.
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      // Form sheet dismissed.
      expect(find.byType(ProductFormSheet), findsNothing);

      // Spy captured the new product with the entered fields. The id is
      // generated (`p_<ms>`); we only assert on user-controlled fields.
      expect(spy.upsertCalls, hasLength(1));
      final captured = spy.upsertCalls.single;
      expect(captured.name, 'Mie Goreng');
      expect(captured.price, 37500);
      expect(captured.categoryId, 'c1');
      // Default icon key (no icon was tapped).
      expect(captured.iconKey, 'restaurant');
      // Default availability / popularity flags for a new product.
      expect(captured.available, true);
      expect(captured.isPopular, false);
      // Empty description → null.
      expect(captured.description, isNull);
    });
  });

  group('product form — validation', () {
    testWidgets(
        'tapping save with empty name shows a SnackBar and does NOT call '
        'upsert', (tester) async {
      final spy = _SpyProductsNotifier(_seedProducts());
      await pumpManagement(
        tester,
        overrides: [
          productsProvider.overrideWith(() => spy),
          categoriesProvider.overrideWith(
            () => _FakeCategoriesNotifier(_seedCategories()),
          ),
        ],
      );

      await openProductForm(tester);

      expect(spy.upsertCalls, isEmpty);
      expect(find.byType(SnackBar), findsNothing);

      // Save with all fields empty — name.isEmpty triggers the validation
      // branch which shows a SnackBar and returns before upsert fires.
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(spy.upsertCalls, isEmpty);

      // Form sheet is still mounted (no pop on the validation branch).
      expect(find.byType(ProductFormSheet), findsOneWidget);
    });
  });

  group('category form — save path', () {
    testWidgets(
        'filling name and tapping save calls upsert with the entered name',
        (tester) async {
      final spy = _SpyCategoriesNotifier(_seedCategories());
      await pumpManagement(
        tester,
        overrides: [
          productsProvider.overrideWith(
            () => _FakeProductsNotifier(_seedProducts()),
          ),
          categoriesProvider.overrideWith(() => spy),
        ],
      );

      await openCategoryForm(tester);

      // _CategoryFormSheet has exactly one TextField (name). The products tab
      // underneath the modal has no TextFields, but switching tabs replaced
      // the page body with the categories tab which also has no TextFields,
      // so the only TextField is the form's name field.
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Cemilan');
      await tester.pumpAndSettle();

      expect(spy.upsertCalls, isEmpty);

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      // Sheet dismissed.
      expect(find.byType(GlassSheet), findsNothing);

      // Spy captured the new category. Id is generated; assert the
      // user-controlled fields + the default iconKey.
      expect(spy.upsertCalls, hasLength(1));
      final captured = spy.upsertCalls.single;
      expect(captured.name, 'Cemilan');
      expect(captured.iconKey, 'restaurant');
    });
  });

  group('category form — validation', () {
    testWidgets(
        'tapping save with empty name is a silent no-op (no SnackBar, no '
        'upsert)', (tester) async {
      final spy = _SpyCategoriesNotifier(_seedCategories());
      await pumpManagement(
        tester,
        overrides: [
          productsProvider.overrideWith(
            () => _FakeProductsNotifier(_seedProducts()),
          ),
          categoriesProvider.overrideWith(() => spy),
        ],
      );

      await openCategoryForm(tester);

      expect(spy.upsertCalls, isEmpty);
      expect(find.byType(SnackBar), findsNothing);

      // Save with empty name — _CategoryFormSheet._save returns before
      // calling upsert. No SnackBar is shown (unlike the product form).
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(spy.upsertCalls, isEmpty);

      // Sheet still mounted.
      expect(find.byType(GlassSheet), findsOneWidget);
    });
  });
}
