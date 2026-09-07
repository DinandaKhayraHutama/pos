import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/utils/formatters.dart';
import 'package:nti_pos/core/widgets/glass/glass_buttons.dart';
import 'package:nti_pos/core/widgets/glass/glass_chip.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/preferences/app_preferences.dart';
import 'package:nti_pos/features/pos/checkout_sheet.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/cart_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

import '../../helpers/db_helper.dart';

/// Widget tests for [CheckoutSheet].
///
/// Locale-agnostic by design: the total, change, and quick-cash chip values
/// are located by [MoneyFormatter.format] output (data — deterministic
/// id_ID number formatting), and the payment-method segments / cash field /
/// exact-cash button / place-order button are located by widget type or
/// [IconData]. No translated label is ever matched.
///
/// `settingsProvider` is overridden with a synchronous fake so `taxRate` is
/// known (0% → subtotal == total == 55.000). `placeOrderFromCart` runs
/// against the in-memory SQLite DB via the Task 1 helper, so the success
/// receipt mounts with a real [Order]; the cart type is takeaway so the
/// function skips the [TableRepository] step.

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

// Tax rate fixed at 0% so totals are obvious. Subtotal = total = 55.000.
const _pb1Rate = 0.0;
final int _total = _pa.price + _pc.price; // 55000
final String _totalText = MoneyFormatter.format(_total); // "Rp 55.000"
// Quick-cash chips for total 55.000: denominations >= 55.000 = {100.000},
// plus round-up-to-5k = 55.000. Sorted: [55.000, 100.000].
final String _changeFor100k = MoneyFormatter.format(100000 - _total); // "Rp 45.000"

Finder _cashField() => find.byType(TextField);
Finder _exactCashButton() => find.byIcon(Icons.check_circle_rounded);
Finder _qrisSegment() => find.byIcon(Icons.qr_code_rounded);
Finder _cardSegment() => find.byIcon(Icons.credit_card_rounded);
// When the cash field is hidden, `Icons.payments_rounded` lives only on the
// cash segment — unambiguous. When the field is visible the field prefix
// also renders it, so callers that need the segment use it only after the
// field has been hidden.
Finder _cashSegment() => find.byIcon(Icons.payments_rounded);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Database? db;
  late ProviderContainer container;

  setUp(() async {
    db = await openInMemoryAppDb(seed: false);
    await AppDatabase.instance.useTestDb(db!);

    AppPreferences.resetForTest();

    final brand = BrandPreset.presets.first;
    final settings = SettingsState(
      themeMode: ThemeMode.light,
      brand: brand,
      locale: const Locale('en'),
      pb1Rate: _pb1Rate,
      serviceChargeEnabled: false,
      serviceChargeRate: 0,
      currency: 'Rp',
      storeName: 'Test Store',
      storeAddress: '',
      cashierName: 'Cash',
      loggedIn: true,
    );
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _ResolvedSettingsNotifier(settings)),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    if (db != null && db!.isOpen) {
      await db!.close();
    }
    AppPreferences.resetForTest();
  });

  Future<void> pumpCheckout(WidgetTester tester) async {
    // Seed the cart with two known products via the real notifier so the
    // sheet's ref.watch(cartProvider) rebuilds on every mutation.
    final notifier = container.read(cartProvider.notifier);
    notifier.add(_pa);
    notifier.add(_pc);
    // Takeaway with no table → placeOrderFromCart skips the TableRepository
    // step, so the test exercises only the order insert path.
    notifier.setType(OrderType.takeaway);

    // Phone-class surface, tall enough for header + total card + segment +
    // cash field + chips + change row + place-order button.
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final brand = BrandPreset.presets.first;
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
          // Three stacked routes ('/' → '/cart' → '/cart/checkout') so the
          // CheckoutSheet's double-pop in `_placeOrder` (close checkout, close
          // cart sheet) pops back to '/' rather than popping the harness root.
          // The subsequent `showGlassSheet` then mounts the receipt cleanly.
          initialRoute: '/cart/checkout',
          routes: {
            '/': (_) => const Scaffold(body: SizedBox.shrink()),
            '/cart': (_) => const Scaffold(body: SizedBox.shrink()),
            '/cart/checkout': (_) => Scaffold(
                  body: SingleChildScrollView(
                    child: CheckoutSheet(),
                  ),
                ),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('total card shows the formatted cart total', (tester) async {
    await pumpCheckout(tester);
    expect(find.text(_totalText), findsOneWidget);
  });

  testWidgets(
    'payment method: cash default; switching to qris/card hides the cash '
    'field, exact-cash button and quick-cash chips; switching back to cash '
    're-shows them',
    (tester) async {
      await pumpCheckout(tester);

      // Default: cash selected → cash field, exact-cash button, chips visible.
      expect(_cashField(), findsOneWidget);
      expect(_exactCashButton(), findsOneWidget);
      expect(find.byType(GlassFilterChip), findsWidgets);

      // Switch to QRIS → cash UI hidden.
      await tester.tap(_qrisSegment());
      await tester.pumpAndSettle();
      expect(_cashField(), findsNothing);
      expect(_exactCashButton(), findsNothing);
      expect(find.byType(GlassFilterChip), findsNothing);

      // Switch to card → cash UI still hidden.
      await tester.tap(_cardSegment());
      await tester.pumpAndSettle();
      expect(_cashField(), findsNothing);
      expect(find.byType(GlassFilterChip), findsNothing);

      // Switch back to cash. While the field is hidden only the cash segment
      // carries Icons.payments_rounded, so the finder is unambiguous.
      await tester.tap(_cashSegment());
      await tester.pumpAndSettle();
      expect(_cashField(), findsOneWidget);
      expect(_exactCashButton(), findsOneWidget);
      expect(find.byType(GlassFilterChip), findsWidgets);
    },
  );

  testWidgets(
    'cash: when the cash field holds an amount above the total, the change '
    'row renders live with the formatted change value (no external rebuild '
    'required)',
    (tester) async {
      await pumpCheckout(tester);

      // Type 100000 into the cash field. The sheet attaches a listener to
      // `_amountCtrl` in initState, so typing alone rebuilds the sheet and
      // the change row appears without any external nudge.
      await tester.enterText(_cashField(), '100000');
      await tester.pumpAndSettle();

      // Change row visible with formatted change = 100000 - 55000 = 45000.
      expect(find.text(_changeFor100k), findsOneWidget);
    },
  );

  testWidgets(
    'cash: exact-cash button sets the field to the total and suppresses the '
    'change row',
    (tester) async {
      await pumpCheckout(tester);

      await tester.tap(_exactCashButton());
      await tester.pumpAndSettle();

      // Field holds the raw total.
      final field = tester.widget<TextField>(_cashField());
      expect(field.controller!.text, _total.toString());

      // No change row (paid == total → change 0 → row not built).
      expect(find.text(_changeFor100k), findsNothing);
    },
  );

  testWidgets(
    'cash: tapping a quick-cash chip sets the cash field to the chip value',
    (tester) async {
      await pumpCheckout(tester);

      // The 100.000 chip label renders without the currency symbol.
      final chip100k = find.text(MoneyFormatter.format(100000, symbol: ''));
      expect(chip100k, findsOneWidget);
      await tester.tap(chip100k);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(_cashField());
      expect(field.controller!.text, '100000');
    },
  );

  testWidgets(
    'place-order: PrimaryButton shows the busy spinner while the order is '
    'placed, then placeOrderFromCart clears the cart and the success '
    'receipt mounts without crashing',
    (tester) async {
      await pumpCheckout(tester);

      // Only one PrimaryButton (the place-order) before placement.
      expect(find.byType(PrimaryButton), findsOneWidget);

      await tester.tap(find.byType(PrimaryButton));
      // Run the frame where setState(_busy = true) rebuilds the button with
      // its loading swap — the 18px CircularProgressIndicator.
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // `placeOrderFromCart` runs against the real in-memory DB via
      // sqflite_common_ffi, whose async chain doesn't progress under the
      // binding's FakeAsync (the CircularProgressIndicator would schedule
      // frames forever). Step out to a real async zone and wait for the
      // side effect — an empty cart.
      //
      // The wait alternates real time with a pump. Real time alone is not
      // enough: `create` runs a transaction whose continuations are scheduled
      // on the test's fake-async zone, and that queue only drains on a pump.
      // Staying inside one long `runAsync` therefore let the DB work finish
      // while the Dart side never resumed — the cart stayed full until
      // teardown disposed the container.
      for (var i = 0; i < 200; i++) {
        if (container.read(cartProvider).isEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(container.read(cartProvider).isEmpty, isTrue);

      // After placeOrderFromCart returns, _placeOrder pops twice and mounts
      // _SuccessReceipt via showGlassSheet. Pump the continuation frames —
      // the receipt's `order.items.first.productName` previously threw
      // `Bad state: No element` (Bug 2: OrderRepository.create returned an
      // Order with `items: const []`). The fix populates `items` on the
      // returned Order, so the success icon and an order line both mount.
      await tester.pumpAndSettle();

      // Success header icon.
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      // The receipt renders `order.items.first.productName` as a bold header
      // line AND walks `order.items` for the per-line rows below — so the
      // first cart item appears twice and the second once. Finding either
      // proves the items survived the placeOrderFromCart → repository →
      // receipt round-trip (Bug 2).
      expect(find.text(_pa.name), findsNWidgets(2));
      expect(find.text(_pc.name), findsOneWidget);
    },
  );
}
