import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/router/app_router.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/models/order_item.dart';
import 'package:nti_pos/features/orders/order_detail_page.dart';
import 'package:nti_pos/features/orders/orders_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/order_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Navigation contract for the Orders → OrderDetail drill-in.
///
/// Opening an order must PUSH the detail onto the stack (not replace it), so
/// the detail page shows a back affordance and popping returns to the list.
/// The bug this guards: `orders_page` used `context.go('/orders/:id')`, which
/// replaces the whole stack — the detail then had nothing to pop back to and
/// [GlassAppBar]'s implied leading never rendered a [BackButton].
///
/// Runs against the REAL [routerProvider] (a shell + pushed `/orders/:id`)
/// through `MaterialApp.router`, so the assertion covers the actual go_router
/// wiring, not a hand-rolled navigator. Locale-agnostic: the order number is
/// data, and the back affordance is matched by [BackButton] type.
class _ResolvedSettingsNotifier extends SettingsNotifier {
  _ResolvedSettingsNotifier(this._initial);
  final SettingsState _initial;
  @override
  Future<SettingsState> build() async => _initial;
}

class _FakeOrdersNotifier extends OrdersNotifier {
  _FakeOrdersNotifier(this._data);
  final List<Order> _data;
  @override
  Future<List<Order>> build(OrderStatus? arg) async => _data;
}

Order _order() => Order(
      id: 'o1',
      number: '#ORD-0042',
      createdAt: DateTime(2025, 1, 15, 12, 30),
      type: OrderType.dineIn,
      table: const TableAssignment(tableId: 't1', tableName: 'Table 5'),
      customerName: 'Alice',
      subtotal: 25000,
      discount: 0,
      tax: 2500,
      total: 27500,
      amountPaid: 27500,
      paymentMethod: PaymentMethod.cash,
      status: OrderStatus.preparing,
      cashierId: 'cashier',
      cashierName: 'Cashier',
      items: const [
        OrderItem(
          id: 'i1',
          orderId: 'o1',
          productId: 'pa',
          productName: 'Nasi Goreng',
          unitPrice: 25000,
          quantity: 1,
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpApp(WidgetTester tester) async {
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
    );
    final order = _order();

    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _ResolvedSettingsNotifier(settings)),
        ordersProvider.overrideWith(() => _FakeOrdersNotifier([order])),
        orderDetailProvider.overrideWith((ref, _) async => order),
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final router = container.read(routerProvider);
    // Drive the real router straight to the Orders tab so the drill-in below
    // exercises the production `/orders` → `/orders/:id` route wiring.
    router.go('/orders');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(brand),
          locale: const Locale('en'),
          supportedLocales: kSupportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
      'tapping an order pushes the detail with a back button, and back returns '
      'to the list', (tester) async {
    await pumpApp(tester);

    // On the Orders list.
    expect(find.byType(OrdersPage), findsOneWidget);
    expect(find.text('#ORD-0042'), findsOneWidget);
    expect(find.byType(BackButton), findsNothing,
        reason: 'A tab root has nothing to pop back to');

    // Drill into the order.
    await tester.tap(find.text('#ORD-0042'));
    await tester.pumpAndSettle();

    // On the detail, WITH a back button (the route was pushed, not replaced).
    expect(find.byType(OrderDetailPage), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget,
        reason:
            'Opening an order must push the detail so a back affordance shows');

    // Back returns to the list.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(OrdersPage), findsOneWidget,
        reason: 'Popping the detail must land back on the Orders list');
  });
}
