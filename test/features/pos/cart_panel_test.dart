import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/utils/formatters.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/features/pos/cart_panel.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/cart_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Widget tests for [CartPanel].
///
/// Locale-agnostic by design: line tiles, steppers, the clear button, the
/// order-type segment and the table field are all located by widget type /
/// `IconData` / `runtimeType`. The only string assertions are against
/// [MoneyFormatter.format] output, which is data (deterministic, locale-id_ID
/// number formatting) — never against translated labels.
///
/// `settingsProvider` is overridden with a synchronous fake so `taxRate` is
/// known (10.0). `cartProvider` stays real so add/decrement/remove mutations
/// are observable through `container.read(cartProvider)`.

class _ResolvedSettingsNotifier extends SettingsNotifier {
  _ResolvedSettingsNotifier(this._initial);
  final SettingsState _initial;
  @override
  Future<SettingsState> build() async => _initial;
}

const _pa = Product(
  id: 'pa',
  name: 'Nasi Goreng',
  categoryId: 'cat_food',
  price: 25000,
  iconKey: 'rice_bowl',
);
const _pc = Product(
  id: 'pc',
  name: 'Ayam Bakar',
  categoryId: 'cat_food',
  price: 30000,
  iconKey: 'dinner_dining',
);

// Tax rate fixed at 10% so the expected money strings are deterministic.
// With _pa and _pc at qty 1: subtotal = 55.000, tax = 5.500, total = 60.500.
const _pb1Rate = 10.0;
final _subtotalText = MoneyFormatter.format(_pa.price + _pc.price);
final _taxText =
    MoneyFormatter.format(((_pa.price + _pc.price) * _pb1Rate / 100).round());
final _totalText = MoneyFormatter.format(
  (_pa.price + _pc.price) +
      ((_pa.price + _pc.price) * _pb1Rate / 100).round(),
);

Finder _tableField() => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_TableField',
    );

Finder _emptyCart() => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_EmptyCart',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpCart(
    WidgetTester tester, {
    List<Product> seed = const [_pa, _pc],
    OrderType type = OrderType.dineIn,
  }) async {
    final brand = BrandPreset.presets.first;
    final settings = SettingsState(
      themeMode: ThemeMode.light,
      brand: brand,
      locale: const Locale('en'),
      pb1Rate: _pb1Rate,
      serviceChargeEnabled: false,
      serviceChargeRate: 0,
      currency: 'IDR',
      storeName: 'Test Store',
      storeAddress: '',
      cashierName: '',
      loggedIn: true,
    );
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _ResolvedSettingsNotifier(settings)),
      ],
    );
    addTearDown(container.dispose);

    // Seed the cart through the real notifier so ref.watch rebuilds the panel
    // on every mutation (same path the UI uses in production).
    final notifier = container.read(cartProvider.notifier);
    for (final p in seed) {
      notifier.add(p);
    }
    notifier.setType(type);

    // Phone-class surface. Tall enough for the header + segment + list +
    // summary footer to mount without clipping.
    tester.view.physicalSize = const Size(420, 1400);
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
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 380,
                child: CartPanel(onCheckout: () {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('empty cart', () {
    testWidgets('renders the empty state instead of the list', (tester) async {
      await pumpCart(tester, seed: const []);
      expect(container.read(cartProvider).isEmpty, isTrue);

      expect(_emptyCart(), findsOneWidget);
      expect(find.byIcon(Icons.shopping_cart_outlined), findsOneWidget);
      expect(find.byType(Dismissible), findsNothing);
    });

    testWidgets('does not render the clear-cart icon nor the order-type segment',
        (tester) async {
      await pumpCart(tester, seed: const []);
      expect(find.byIcon(Icons.delete_sweep_rounded), findsNothing);
      expect(find.byIcon(Icons.table_restaurant_rounded), findsNothing);
      expect(find.byIcon(Icons.shopping_bag_rounded), findsNothing);
      expect(find.byIcon(Icons.two_wheeler_rounded), findsNothing);
    });
  });

  group(
    'populated cart',
    () {

      testWidgets('two line tiles render when cart has two lines',
          (tester) async {
        await pumpCart(tester);
        expect(find.byType(Dismissible), findsNWidgets(2));
        // Each tile renders exactly one GlassStepper → two `+` icons.
        expect(find.byIcon(Icons.add_rounded), findsNWidgets(2));
      });

      testWidgets(
          'summary shows subtotal, tax and total as formatted money data',
          (tester) async {
        await pumpCart(tester);
        expect(find.text(_subtotalText), findsOneWidget);
        expect(find.text(_taxText), findsOneWidget);
        expect(find.text(_totalText), findsOneWidget);
      });

      testWidgets('tapping + on a line increments cart quantity',
          (tester) async {
        await pumpCart(tester);
        expect(container.read(cartProvider).itemCount, 2);

        await tester.tap(find.byIcon(Icons.add_rounded).first);
        await tester.pumpAndSettle();

        expect(container.read(cartProvider).itemCount, 3);
        final paLine = container.read(cartProvider).lines.firstWhere(
              (l) => l.product.id == 'pa',
            );
        expect(paLine.quantity, 2);
      });

      testWidgets('tapping - on a line at qty > 1 decrements',
          (tester) async {
        await pumpCart(tester, seed: [_pa, _pa]);
        expect(container.read(cartProvider).lines.length, 1);
        expect(container.read(cartProvider).lines.first.quantity, 2);

        await tester.tap(find.byIcon(Icons.remove_rounded).first);
        await tester.pumpAndSettle();

        expect(container.read(cartProvider).lines.first.quantity, 1);
      });

      testWidgets('tapping - on a line at qty 1 removes the line',
          (tester) async {
        await pumpCart(tester);
        expect(container.read(cartProvider).lines.length, 2);

        await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
        await tester.pumpAndSettle();

        expect(container.read(cartProvider).lines.length, 1);
      });

      testWidgets('dismissing a line end-to-start removes it',
          (tester) async {
        await pumpCart(tester);
        expect(find.byType(Dismissible), findsNWidgets(2));

        await tester.drag(
          find.byType(Dismissible).first,
          const Offset(-600, 0),
        );
        await tester.pumpAndSettle();

        expect(find.byType(Dismissible), findsOneWidget);
        expect(container.read(cartProvider).lines.length, 1);
      });

      testWidgets('tapping the clear-cart icon empties the cart',
          (tester) async {
        await pumpCart(tester);
        expect(container.read(cartProvider).isEmpty, isFalse);

        await tester.tap(find.byIcon(Icons.delete_sweep_rounded));
        await tester.pumpAndSettle();

        expect(container.read(cartProvider).isEmpty, isTrue);
        expect(_emptyCart(), findsOneWidget);
        expect(find.byType(Dismissible), findsNothing);
      });

      testWidgets(
          'switching to takeaway updates cart type and hides the table field',
          (tester) async {
        await pumpCart(tester);
        expect(container.read(cartProvider).type, OrderType.dineIn);
        expect(_tableField(), findsOneWidget);

        await tester.tap(find.byIcon(Icons.shopping_bag_rounded));
        await tester.pumpAndSettle();

        expect(container.read(cartProvider).type, OrderType.takeaway);
        expect(_tableField(), findsNothing);
      });

      testWidgets(
          'switching to delivery updates cart type and hides the table field',
          (tester) async {
        await pumpCart(tester);

        await tester.tap(find.byIcon(Icons.two_wheeler_rounded));
        await tester.pumpAndSettle();

        expect(container.read(cartProvider).type, OrderType.delivery);
        expect(_tableField(), findsNothing);
      });

      testWidgets('switching back to dine-in shows the table field again',
          (tester) async {
        await pumpCart(tester);

        await tester.tap(find.byIcon(Icons.shopping_bag_rounded));
        await tester.pumpAndSettle();
        expect(_tableField(), findsNothing);

        await tester.tap(find.byIcon(Icons.table_restaurant_rounded));
        await tester.pumpAndSettle();

        expect(container.read(cartProvider).type, OrderType.dineIn);
        expect(_tableField(), findsOneWidget);
      });
    },
  );
}
