import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_chip.dart';
import 'package:nti_pos/data/models/category.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/features/pos/pos_page.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/cart_provider.dart';
import 'package:nti_pos/providers/catalog_provider.dart';
import 'package:nti_pos/providers/modifier_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Widget tests for [PosPage] interactions.
///
/// Locale-agnostic by design: products and categories are located by widget
/// type / icon / id, never by translated labels. The "All" / "Popular" chips
/// are matched by their leading [IconData] (`Icons.restaurant_menu_rounded`
/// and `Icons.local_fire_department_rounded`) and category chips by their
/// [Category.iconKey]-derived icon, which is data — not a localized string.
///
/// `productsProvider`, `categoriesProvider`, and `settingsProvider` are
/// overridden with synchronous fakes so the catalog renders deterministically
/// without touching `sqflite`. `cartProvider` stays real so add/decrement
/// mutations are observable through `container.read(cartProvider)`.
class _FakeProductsNotifier extends ProductsNotifier {
  _FakeProductsNotifier(this._initial);
  final List<Product> _initial;
  @override
  Future<List<Product>> build() async => _initial;
}

class _FakeCategoriesNotifier extends CategoriesNotifier {
  _FakeCategoriesNotifier(this._initial);
  final List<Category> _initial;
  @override
  Future<List<Category>> build() async => _initial;
}

class _ResolvedSettingsNotifier extends SettingsNotifier {
  _ResolvedSettingsNotifier(this._initial);
  final SettingsState _initial;
  @override
  Future<SettingsState> build() async => _initial;
}

const _catFood = Category(
  id: 'cat_food',
  name: 'Food',
  emoji: '🍱',
  iconKey: 'set_meal',
);

final List<Product> _products = [
  const Product(
    id: 'pa',
    name: 'Nasi Goreng',
    categoryId: 'cat_food',
    price: 25000,
    iconKey: 'rice_bowl',
    isPopular: true,
  ),
  const Product(
    id: 'pb',
    name: 'Es Teh',
    categoryId: 'cat_drinks',
    price: 5000,
    iconKey: 'local_drink',
  ),
  const Product(
    id: 'pc',
    name: 'Ayam Bakar',
    categoryId: 'cat_food',
    price: 30000,
    iconKey: 'dinner_dining',
  ),
  // Available=false: PosPage filters these out of the grid before any other
  // filter runs, so this card must never mount.
  const Product(
    id: 'pd',
    name: 'Sate',
    categoryId: 'cat_food',
    price: 20000,
    iconKey: 'fastfood',
    available: false,
  ),
];

Finder _cardById(String id) =>
    find.byWidgetPredicate((w) => w is ProductCard && w.product.id == id);

Finder _cartBar() =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_OpenCartBar');

Finder _chipByIcon(IconData icon) =>
    find.byWidgetPredicate((w) => w is GlassFilterChip && w.icon == icon);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpPos(WidgetTester tester) async {
    final brand = BrandPreset.presets.first;
    final settings = SettingsState(
      themeMode: ThemeMode.light,
      brand: brand,
      locale: const Locale('en'),
      pb1Rate: 10.0,
      serviceChargeEnabled: false,
      serviceChargeRate: 0,
      currency: 'IDR',
      storeName: 'Test Store',
      storeAddress: '',
      cashierName: '',
      loggedIn: true,
      // A held POS session, or `PosPage` shows `_SessionGate` instead of the
      // catalogue this whole file is testing — `posSessionId` defaults to
      // empty, which now means "no session" and would swap every one of
      // these cases onto a completely different widget tree.
      posSessionId: 'test_session',
    );
    container = ProviderContainer(
      overrides: [
        // The catalogue waits for option configuration before enabling Add.
        // These plain-product fixtures intentionally contain no choices.
        productVariantsProvider.overrideWith((ref) async => {}),
        productModifierGroupsProvider.overrideWith((ref) async => {}),
        modifierOptionsByGroupProvider.overrideWith((ref) async => {}),
        productModifierOptionScopeProvider.overrideWith((ref) async => {}),
        productModifierDefaultsProvider.overrideWith((ref) async => {}),
        productsProvider.overrideWith(() => _FakeProductsNotifier(_products)),
        categoriesProvider.overrideWith(
          () => _FakeCategoriesNotifier(const [_catFood]),
        ),
        settingsProvider.overrideWith(
          () => _ResolvedSettingsNotifier(settings),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Phone-class surface so PosPage picks the bottom-sheet-cart layout
    // (< AppDimensions.tabletWidth). Tall enough for the catalog grid +
    // the cart bar that slides in once an item is added.
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

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
          home: const PosPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('initial catalog shows available products, hides unavailable, '
      'and has no cart bar when empty', (tester) async {
    await pumpPos(tester);

    expect(find.byType(ProductCard), findsNWidgets(3));
    expect(_cardById('pd'), findsNothing);
    expect(_cartBar(), findsNothing);
    expect(container.read(cartProvider).isEmpty, isTrue);
  });

  testWidgets('tapping an available product card adds it to the cart and '
      'reveals the cart bar', (tester) async {
    await pumpPos(tester);

    await tester.tap(_cardById('pa'));
    await tester.pumpAndSettle();

    expect(container.read(cartProvider).itemCount, 1);
    expect(_cartBar(), findsOneWidget);
  });

  testWidgets('typing in the search field filters the grid and shows an '
      'empty state when nothing matches', (tester) async {
    await pumpPos(tester);

    await tester.enterText(find.byType(TextField), 'nasi goreng');
    await tester.pumpAndSettle();
    expect(find.byType(ProductCard), findsOneWidget);
    expect(_cardById('pa'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'zzzzzz');
    await tester.pumpAndSettle();
    expect(find.byType(ProductCard), findsNothing);
    expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);
  });

  testWidgets('tapping a category chip filters products by category', (
    tester,
  ) async {
    await pumpPos(tester);

    await tester.tap(_chipByIcon(Icons.set_meal_rounded));
    await tester.pumpAndSettle();

    // pa and pc are cat_food; pb is cat_drinks. pd is unavailable and
    // filtered out before the category filter runs.
    expect(find.byType(ProductCard), findsNWidgets(2));
    expect(_cardById('pa'), findsOneWidget);
    expect(_cardById('pc'), findsOneWidget);
  });

  testWidgets('tapping the Popular chip shows only popular products', (
    tester,
  ) async {
    await pumpPos(tester);

    await tester.tap(_chipByIcon(Icons.local_fire_department_rounded));
    await tester.pumpAndSettle();

    // Only pa has isPopular = true.
    expect(find.byType(ProductCard), findsOneWidget);
    expect(_cardById('pa'), findsOneWidget);
  });
}
