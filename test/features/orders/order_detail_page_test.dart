import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/utils/formatters.dart';
import 'package:nti_pos/core/widgets/status_badge.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/models/order_item.dart';
import 'package:nti_pos/features/orders/order_detail_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/order_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Widget tests for [OrderDetailPage].
///
/// Locale-agnostic by design:
/// - The order number (`#ORD-0042`), product names (`Nasi Goreng`, `Es Teh`),
///   `Nx` quantity prefixes, and [MoneyFormatter.format] totals are DATA —
///   deterministic and not localized labels.
/// - [StatusBadge] is matched by type and its `status` property, never by its
///   translated label.
/// - The status-advance button is matched by its [FilledButton] type and the
///   leading [Icons.arrow_forward_rounded] icon, not by its label text.
///
/// `orderDetailProvider` (a `FutureProvider.family<Order?, String>`) is
/// overridden at the family level with a closure that reads a mutable
/// `current` [Order]. When `_statusActions` calls
/// `ref.invalidate(orderDetailProvider(order.id))` after `setStatus`, the
/// provider re-runs and returns the updated order — exercising the real
/// read→invalidate→rebuild path the production UI uses.
///
/// `Order` has no `copyWith`; the test rebuilds the order through `_makeOrder`
/// to keep all non-status fields identical across the pending → preparing
/// transition.
class _ResolvedSettingsNotifier extends SettingsNotifier {
  _ResolvedSettingsNotifier(this._initial);
  final SettingsState _initial;
  @override
  Future<SettingsState> build() async => _initial;
}

/// Fake [OrdersNotifier] whose `setStatus` delegates to a caller-supplied
/// callback (typically mutating a closure-captured [Order]) instead of hitting
/// sqflite.
class _FakeOrdersNotifier extends OrdersNotifier {
  _FakeOrdersNotifier(this._data, this._onSetStatus);
  final List<Order> _data;
  final Future<void> Function(String id, OrderStatus status) _onSetStatus;

  @override
  Future<List<Order>> build(OrderStatus? arg) async => _data;

  @override
  Future<void> setStatus(String id, OrderStatus status) =>
      _onSetStatus(id, status);
}

Order _makeOrder(OrderStatus status) {
  return Order(
    id: 'o1',
    number: '#ORD-0042',
    createdAt: DateTime(2025, 1, 15, 12, 30),
    type: OrderType.dineIn,
    table: const TableAssignment(tableId: 't1', tableName: 'Table 5'),
    customerName: 'Alice',
    subtotal: 55000,
    discount: 0,
    tax: 5500,
    total: 60500,
    amountPaid: 60500,
    paymentMethod: PaymentMethod.cash,
    status: status,
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
      OrderItem(
        id: 'i2',
        orderId: 'o1',
        productId: 'pb',
        productName: 'Es Teh',
        unitPrice: 5000,
        quantity: 6,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpDetail(
    WidgetTester tester, {
    required Order Function() currentOrder,
    Future<void> Function(String id, OrderStatus status)? onSetStatus,
  }) async {
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

    // Default no-op so callers that don't care about advancing still work.
    final setStatus = onSetStatus ?? ((_, _) async {});

    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _ResolvedSettingsNotifier(settings)),
        // The override closure re-reads `currentOrder()` on every invalidate,
        // so a status mutation in `onSetStatus` is visible on the next rebuild
        // without re-pumping the widget tree.
        orderDetailProvider.overrideWith((ref, _) async => currentOrder()),
        // `_statusActions` reads `ordersProvider(null).notifier`; supply the
        // fake at the family level (riverpod 2.6 only supports family-level
        // overrides) so the status-advance path doesn't touch sqflite.
        ordersProvider.overrideWith(
          () => _FakeOrdersNotifier([currentOrder()], setStatus),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Phone-class surface, tall enough for the header + items + summary + the
    // status-action buttons to mount without clipping.
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
          home: const OrderDetailPage(orderId: 'o1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('order detail', () {
    testWidgets(
        'renders the order number, line items (name + qty prefix) and the '
        'totals block', (tester) async {
      await pumpDetail(
        tester,
        currentOrder: () => _makeOrder(OrderStatus.pending),
      );

      // Header: order number is data; StatusBadge is matched by type.
      expect(find.text('#ORD-0042'), findsOneWidget);
      expect(find.byType(StatusBadge), findsOneWidget);

      // Line items: product names (data) + `Nx` quantity prefix (data).
      expect(find.text('Nasi Goreng'), findsOneWidget);
      expect(find.text('Es Teh'), findsOneWidget);
      expect(find.text('1x'), findsOneWidget);
      expect(find.text('6x'), findsOneWidget);

      // Totals block: MoneyFormatter.format output is deterministic id_ID
      // number formatting (data). Subtotal=55.000, Tax=5.500, Total=60.500;
      // line totals 1*25000=25.000 and 6*5000=30.000 are also present.
      expect(find.text(MoneyFormatter.format(55000)), findsOneWidget);
      expect(find.text(MoneyFormatter.format(5500)), findsOneWidget);
      expect(find.text(MoneyFormatter.format(60500)), findsOneWidget);
    });

    testWidgets(
        'tapping the status-advance button moves pending → preparing',
        (tester) async {
      Order current = _makeOrder(OrderStatus.pending);

      await pumpDetail(
        tester,
        currentOrder: () => current,
        onSetStatus: (id, status) async {
          expect(id, 'o1');
          // Order has no copyWith; rebuild via _makeOrder so all non-status
          // fields stay identical across the pending → preparing transition.
          current = _makeOrder(status);
        },
      );

      // Pre-tap: badge reflects the seeded status.
      var badge = tester.widget<StatusBadge>(find.byType(StatusBadge));
      expect(badge.status, OrderStatus.pending);

      // The advance action is a `FilledButton.icon` whose runtime type is
      // `_FilledButtonWithIcon` (so `find.byType(FilledButton)` misses it).
      // Locate it by its leading `Icons.arrow_forward_rounded` icon, which is
      // unique on this page, then tap to drive pending → preparing.
      expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
      await tester.pumpAndSettle();

      // Post-tap: setStatus ran (mutating `current`), orderDetailProvider was
      // invalidated by the page, and the badge now reflects `preparing`.
      badge = tester.widget<StatusBadge>(find.byType(StatusBadge));
      expect(badge.status, OrderStatus.preparing);
    });
  });
}
