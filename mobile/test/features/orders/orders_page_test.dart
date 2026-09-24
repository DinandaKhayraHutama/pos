import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/empty_state.dart';
import 'package:nti_pos/core/widgets/glass/glass_chip.dart';
import 'package:nti_pos/core/widgets/glass/skeleton.dart';
import 'package:nti_pos/core/widgets/status_badge.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/features/orders/orders_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/order_history_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Widget tests for [OrdersPage].
///
/// Locale-agnostic by design:
/// - Order numbers (`#ORD-00xx`) are DATA, not localized strings.
/// - [StatusBadge] is matched by type and its `status` property, never by its
///   translated label.
/// - The filter chips are matched by index in a fixed order rather than by
///   localized label text. Since paritas F1 the page builds three rows:
///   period (today, yesterday, 7 days, this month, custom), then status (All,
///   pending, preparing, ready, served, paid, cancelled, refunded), then —
///   for an account holding `viewAllOrders` — scope (this till, whole outlet).
///   [_paidChipIndex] names the one the filter test taps.
/// - The empty / loading branches are matched by widget type
///   ([EmptyState], [Skeleton]) and by the [IconData] the empty state uses.
///
/// The page reads [orderHistoryProvider], which pages the server and SQLite
/// together; the fake below stands in for both so these tests stay about the
/// widget. The filter itself lives in [orderHistoryFilterProvider], so tapping
/// a chip genuinely re-runs the notifier the way it does in the app.

/// The first chip of the status row, and the sixth within it.
const _periodChips = 5;
const _paidChipIndex = _periodChips + 5;

class _ResolvedSettingsNotifier extends SettingsNotifier {
  _ResolvedSettingsNotifier(this._initial);
  final SettingsState _initial;
  @override
  Future<SettingsState> build() async => _initial;
}

/// Fake history notifier that answers from a per-status map, re-reading the
/// filter so a chip tap changes the list exactly as it does in the app.
class _FakeHistoryNotifier extends OrderHistoryNotifier {
  _FakeHistoryNotifier(this._byStatus);
  final Map<OrderStatus?, List<Order>> _byStatus;

  @override
  Future<OrderHistoryState> build() async {
    final filter = ref.watch(orderHistoryFilterProvider);
    return OrderHistoryState(
      orders: _byStatus[filter.status] ?? const [],
      localOnly: true,
    );
  }
}

/// Fake whose `build` never completes so the provider stays in `AsyncLoading`.
class _HangingHistoryNotifier extends OrderHistoryNotifier {
  _HangingHistoryNotifier();
  @override
  Future<OrderHistoryState> build() => Completer<OrderHistoryState>().future;
}

Order _order({
  required String id,
  required String number,
  required OrderStatus status,
  OrderType type = OrderType.dineIn,
  int total = 50000,
}) {
  return Order(
    id: id,
    number: number,
    createdAt: DateTime(2025, 1, 15, 12, 30),
    type: type,
    subtotal: total,
    discount: 0,
    tax: 0,
    total: total,
    amountPaid: total,
    paymentMethod: PaymentMethod.cash,
    status: status,
    cashierId: 'cashier',
    cashierName: 'Cashier',
  );
}

final _o1 = _order(
  id: 'o1',
  number: '#ORD-0001',
  status: OrderStatus.pending,
);
final _o2 = _order(
  id: 'o2',
  number: '#ORD-0002',
  status: OrderStatus.preparing,
);
final _o3 = _order(
  id: 'o3',
  number: '#ORD-0003',
  status: OrderStatus.paid,
);
final _allOrders = [_o1, _o2, _o3];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpOrders(
    WidgetTester tester, {
    List<Override> extraOverrides = const [],
    bool settle = true,
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
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _ResolvedSettingsNotifier(settings)),
        ...extraOverrides,
      ],
    );
    addTearDown(container.dispose);

    // Surface wide enough that every filter chip mounts at once
    // (the bar is a horizontal ListView — at phone width the later chips
    // are off-screen and not built, so `find...at(5)` would throw). Tall
    // enough for the AppBar + filter row + orders ListView.
    tester.view.physicalSize = const Size(1200, 1200);
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
          home: const OrdersPage(),
        ),
      ),
    );
    // The loading branch renders [Skeleton]s, whose `_Shimmer` ticker loops
    // forever — `pumpAndSettle` would time out. Callers that exercise the
    // loading branch pass `settle: false` and let the first frame land.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  group('orders list', () {
    testWidgets(
        'renders one tile per order across mixed statuses '
        '(pending, preparing, paid)', (tester) async {
      await pumpOrders(
        tester,
        extraOverrides: [
          orderHistoryProvider.overrideWith(
            () => _FakeHistoryNotifier({null: _allOrders}),
          ),
        ],
      );

      // Order numbers are data, not localized strings.
      expect(find.text('#ORD-0001'), findsOneWidget);
      expect(find.text('#ORD-0002'), findsOneWidget);
      expect(find.text('#ORD-0003'), findsOneWidget);
      // One StatusBadge per tile.
      expect(find.byType(StatusBadge), findsNWidgets(3));
    });

    testWidgets(
        'tapping the paid filter chip narrows the list to paid orders only',
        (tester) async {
      await pumpOrders(
        tester,
        extraOverrides: [
          orderHistoryProvider.overrideWith(
            () => _FakeHistoryNotifier({
              null: _allOrders,
              OrderStatus.paid: [_o3],
            }),
          ),
        ],
      );

      // Five period chips come first, then the status row:
      //   0:All 1:pending 2:preparing 3:ready 4:served 5:paid 6:cancelled
      //   7:refunded
      // Tap by index so the test stays agnostic to the localized label.
      final paidChip = find.byType(GlassFilterChip).at(_paidChipIndex);
      expect(paidChip, findsOneWidget);

      await tester.tap(paidChip);
      await tester.pumpAndSettle();

      expect(find.text('#ORD-0001'), findsNothing);
      expect(find.text('#ORD-0002'), findsNothing);
      expect(find.text('#ORD-0003'), findsOneWidget);
      expect(find.byType(StatusBadge), findsOneWidget);
    });

    testWidgets(
        'empty list renders the EmptyState with the receipt icon, '
        'and zero tiles', (tester) async {
      await pumpOrders(
        tester,
        extraOverrides: [
          orderHistoryProvider.overrideWith(
            () => _FakeHistoryNotifier({null: const []}),
          ),
        ],
      );

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.byIcon(Icons.receipt_long_rounded), findsOneWidget);
      expect(find.byType(StatusBadge), findsNothing);
    });

    testWidgets(
        'loading state renders the skeleton bars and no tiles',
        (tester) async {
      await pumpOrders(
        tester,
        settle: false,
        extraOverrides: [
          orderHistoryProvider.overrideWith(() => _HangingHistoryNotifier()),
        ],
      );

      // OrdersPage's loading branch renders `LoadingIndicator.skeleton(lines:
      // 5)`. Each line is one Skeleton bar. (Don't pumpAndSettle here — the
      // shimmer ticker loops forever.)
      expect(find.byType(Skeleton), findsNWidgets(5));
      expect(find.byType(StatusBadge), findsNothing);
      expect(find.byType(EmptyState), findsNothing);
    });
  });
}
