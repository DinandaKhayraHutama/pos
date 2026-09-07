import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/skeleton.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/features/dashboard/dashboard_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/order_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Widget tests for [DashboardPage].
///
/// Locale-agnostic by design:
/// - Formatted money (`Rp 250.000`, `Rp 50 rb`) and order numbers
///   (`#ORD-0001`) are DATA, not localized strings — they are produced by
///   [MoneyFormatter] / [Order.number] and asserted verbatim.
/// - Product names (`Nasi Goreng`, `Es Teh Manis`) are DATA.
/// - Loading / empty branches are matched by widget type ([Skeleton]) or
///   runtimeType predicate (`_EmptyInline`), never by translated label.
/// - The tablet two-column layout is detected structurally: a `Row` whose
///   direct children include exactly two `Expanded` (the stats Row always
///   matches; the layout Row matches only at ≥900dp).
///
/// The three dashboard providers are overridden with controlled `AsyncData`:
/// - [dashboardSummaryProvider] — `FutureProvider.autoDispose` for the
///   `(revenue, count, itemsSold)` record.
/// - [topProductsProvider] — `FutureProvider.autoDispose` for the ranked
///   product list.
/// - [ordersProvider] — `AsyncNotifierProvider.autoDispose.family` keyed by
///   `OrderStatus?`; the dashboard watches the `null` (all) member.
class _ResolvedSettingsNotifier extends SettingsNotifier {
  _ResolvedSettingsNotifier(this._initial);
  final SettingsState _initial;
  @override
  Future<SettingsState> build() async => _initial;
}

/// Fake [OrdersNotifier] returning a per-arg list, no sqflite.
class _FakeOrdersNotifier extends OrdersNotifier {
  _FakeOrdersNotifier(this._byArg);
  final Map<OrderStatus?, List<Order>> _byArg;
  @override
  Future<List<Order>> build(OrderStatus? arg) async => _byArg[arg] ?? const [];
}

/// Fake that increments [onBuild] every time `build` runs, so the refresh
/// test can assert the provider was invalidated → rebuilt.
class _CountingOrdersNotifier extends OrdersNotifier {
  _CountingOrdersNotifier(this._data, this.onBuild);
  final List<Order> _data;
  final VoidCallback onBuild;
  @override
  Future<List<Order>> build(OrderStatus? arg) async {
    onBuild();
    return _data;
  }
}

/// Fake whose `build` never completes so the provider stays in `AsyncLoading`.
class _HangingOrdersNotifier extends OrdersNotifier {
  _HangingOrdersNotifier();
  @override
  Future<List<Order>> build(OrderStatus? arg) =>
      Completer<List<Order>>().future;
}

Order _order({
  required String id,
  required String number,
  required int total,
}) {
  return Order(
    id: id,
    number: number,
    createdAt: DateTime(2025, 1, 15, 14, 30),
    type: OrderType.dineIn,
    subtotal: total,
    discount: 0,
    tax: 0,
    total: total,
    amountPaid: total,
    paymentMethod: PaymentMethod.cash,
    status: OrderStatus.paid,
    cashierId: 'cashier',
    cashierName: 'Cashier',
  );
}

const _seedSummary = (revenue: 250000, count: 5, itemsSold: 15);

final _seedTopProducts = <
  ({String name, String? iconKey, int qty, int revenue})
>[
  (name: 'Nasi Goreng', iconKey: 'restaurant', qty: 10, revenue: 150000),
  (name: 'Es Teh Manis', iconKey: 'local_cafe', qty: 5, revenue: 25000),
];

final _seedOrders = <Order>[
  _order(id: 'o1', number: '#ORD-0001', total: 75000),
  _order(id: 'o2', number: '#ORD-0002', total: 42000),
];

/// Standard data overrides for the "happy path" tests: all three providers
/// resolve to the seeded `AsyncData`.
List<Override> _dataOverrides({VoidCallback? onOrdersBuild}) => [
  dashboardSummaryProvider.overrideWith((ref) => _seedSummary),
  topProductsProvider.overrideWith((ref) => _seedTopProducts),
  ordersProvider.overrideWith(
    () =>
        _CountingOrdersNotifier(_seedOrders, onOrdersBuild ?? () {}),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpDashboard(
    WidgetTester tester, {
    List<Override> extraOverrides = const [],
    bool settle = true,
    bool tablet = false,
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

    // Phone: 800 logical width < AppDimensions.tabletWidth (900) → single
    // column. Tablet: 1200 logical width ≥ 900 → two-column split.
    tester.view.physicalSize =
        tablet ? const Size(1200, 1800) : const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Pre-resolve the three async providers before pumping so the widget's
    // first build sees AsyncData directly. FutureProvider always starts in
    // AsyncLoading for one microtask even when the override returns a
    // synchronous value; without pre-resolution the widget paints the
    // loading branch — whose SizedBox(height: 60) is 8px too short for 3
    // Skeleton bars (a pre-existing production layout bug) — and the
    // RenderFlex overflow fails the test. The manual listen keeps the
    // autoDispose providers alive while awaiting; after pumpWidget the
    // widget's own subscriptions hold them, so we close ours.
    final subs = <ProviderSubscription>[
      container.listen(dashboardSummaryProvider, (_, _) {}),
      container.listen(topProductsProvider, (_, _) {}),
      container.listen(ordersProvider(null), (_, _) {}),
    ];
    if (settle) {
      await Future.wait([
        container.read(dashboardSummaryProvider.future),
        container.read(topProductsProvider.future),
        container.read(ordersProvider(null).future),
      ]);
    }

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
          home: const DashboardPage(),
        ),
      ),
    );
    for (final s in subs) {
      s.close();
    }
    // Skeleton shimmer ticker loops forever — loading tests pass settle:false
    // and let the first frame land.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  group('stats row', () {
    testWidgets(
        'renders the seeded summary as formatted money + bare count '
        '(revenue Rp 250.000, orders 5, avg Rp 50 rb)', (tester) async {
      await pumpDashboard(
        tester,
        extraOverrides: _dataOverrides(),
      );

      // _BigStat value → MoneyFormatter.format(250000) = "Rp 250.000".
      expect(find.text('Rp 250.000'), findsOneWidget);
      // _SmallStat orders count → '${data.count}' = "5".
      expect(find.text('5'), findsOneWidget);
      // _SmallStat avg → MoneyFormatter.compact(250000 ~/ 5 = 50000) =
      // "Rp 50 rb".
      expect(find.text('Rp 50 rb'), findsOneWidget);
    });
  });

  group('top products', () {
    testWidgets(
        'renders one bar per seeded product with the product name (data) '
        'and a LinearProgressIndicator', (tester) async {
      await pumpDashboard(
        tester,
        extraOverrides: _dataOverrides(),
      );

      // Product names are data, not localized strings.
      expect(find.text('Nasi Goreng'), findsOneWidget);
      expect(find.text('Es Teh Manis'), findsOneWidget);

      // Each _TopProductBar paints a LinearProgressIndicator sized by its
      // ratio to the top seller. Two seeded products → two indicators.
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));

      // Compact revenue labels are deterministic data too:
      // compact(150000) = "Rp 150 rb", compact(25000) = "Rp 25 rb".
      expect(find.text('Rp 150 rb'), findsOneWidget);
      expect(find.text('Rp 25 rb'), findsOneWidget);
    });
  });

  group('recent orders', () {
    testWidgets(
        'renders one tile per seeded recent order with the order number '
        'and formatted total (data)', (tester) async {
      await pumpDashboard(
        tester,
        extraOverrides: _dataOverrides(),
      );

      // Order numbers are data.
      expect(find.text('#ORD-0001'), findsOneWidget);
      expect(find.text('#ORD-0002'), findsOneWidget);

      // MoneyFormatter.format(total): 75000 → "Rp 75.000", 42000 → "Rp 42.000".
      expect(find.text('Rp 75.000'), findsOneWidget);
      expect(find.text('Rp 42.000'), findsOneWidget);
    });
  });

  group('loading', () {
    testWidgets(
        'AsyncLoading on all three providers paints the Skeleton bars '
        'and no data widgets', (tester) async {
      // Overflow errors are captured rather than allowed to fail the test on
      // their own, so the assertion below can name the count. It used to be
      // 2: the loading branch packed 3 Skeleton bars (68px) into a
      // SizedBox(height: 60) in each of the two lower sections. That is fixed,
      // and the expectation now pins ZERO — asserting a known overflow is
      // asserting a bug is still present, which is the opposite of a guard.
      // Non-overflow errors are re-thrown so real regressions still surface.
      final overflowErrors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception.toString().contains('overflowed')) {
          overflowErrors.add(details);
        } else {
          previousOnError?.call(details);
        }
      };

      await pumpDashboard(
        tester,
        settle: false,
        extraOverrides: [
          dashboardSummaryProvider.overrideWith(
            (ref) => Completer<
                ({int revenue, int count, int itemsSold})
            >().future,
          ),
          topProductsProvider.overrideWith(
            (ref) =>
                Completer<
                  List<({String name, String? iconKey, int qty, int revenue})>
                >().future,
          ),
          ordersProvider.overrideWith(() => _HangingOrdersNotifier()),
        ],
      );

      // Three `.when(loading:)` branches each render
      // `LoadingIndicator.skeleton(lines: 3)` → 9 Skeleton bars total.
      expect(find.byType(Skeleton), findsNWidgets(9));
      // No data widgets should be mounted while loading.
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('#ORD-0001'), findsNothing);

      FlutterError.onError = previousOnError;
      expect(
        overflowErrors,
        isEmpty,
        reason: 'the loading state must not overflow: '
            '${overflowErrors.map((e) => e.exception).join('; ')}',
      );
    });
  });

  group('empty', () {
    testWidgets(
        'zero revenue / no products / no orders renders the inline empty '
        'state in both sections and no data widgets', (tester) async {
      await pumpDashboard(
        tester,
        extraOverrides: [
          dashboardSummaryProvider.overrideWith(
            (ref) => (revenue: 0, count: 0, itemsSold: 0),
          ),
          topProductsProvider.overrideWith((ref) => <_TopProductTuple>[]),
          ordersProvider.overrideWith(
            () => _FakeOrdersNotifier({null: const []}),
          ),
        ],
      );

      // Both _topProductsSection and _recentOrdersSection render an
      // _EmptyInline when their data list is empty. The private widget is
      // matched by runtimeType so the assertion stays label-agnostic.
      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_EmptyInline',
        ),
        findsNWidgets(2),
      );
      // No product bars or order tiles in the empty branch.
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('#ORD-0001'), findsNothing);
      // Not loading either.
      expect(find.byType(Skeleton), findsNothing);
    });
  });

  group('refresh action', () {
    testWidgets(
        'tapping the GlassAppBar refresh icon invalidates all three '
        'dashboard providers (summary, topProducts, orders) so they rebuild',
        (tester) async {
      // Counters incremented inside each override's build function. After
      // the initial pump each reads 1; after the refresh tap each reads 2.
      var summaryBuilds = 0;
      var topProductsBuilds = 0;
      var ordersBuilds = 0;

      await pumpDashboard(
        tester,
        extraOverrides: [
          dashboardSummaryProvider.overrideWith((ref) {
            summaryBuilds++;
            return _seedSummary;
          }),
          topProductsProvider.overrideWith((ref) {
            topProductsBuilds++;
            return _seedTopProducts;
          }),
          ordersProvider.overrideWith(
            () => _CountingOrdersNotifier(_seedOrders, () => ordersBuilds++),
          ),
        ],
      );

      // Initial build of each provider has fired.
      expect(summaryBuilds, 1);
      expect(topProductsBuilds, 1);
      expect(ordersBuilds, 1);

      // Tap the refresh IconButton in the GlassAppBar. Matched by icon, not
      // by localized tooltip / label.
      final refreshButton = find.byIcon(Icons.refresh_rounded);
      expect(refreshButton, findsOneWidget);
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      // invalidate() re-ran each provider's build → counters doubled.
      expect(summaryBuilds, 2);
      expect(topProductsBuilds, 2);
      expect(ordersBuilds, 2);
    });
  });

  group('tablet two-column layout', () {
    testWidgets(
        'at ≥900dp the top-products and recent-orders sections split into '
        'two side-by-side Expanded columns inside a Row', (tester) async {
      await pumpDashboard(
        tester,
        tablet: true,
        extraOverrides: _dataOverrides(),
      );

      // Detect the two-column layout structurally: a Row whose direct
      // children include exactly two Expanded widgets. Two such Rows exist
      // on tablet — the always-present _statsRow and the layout Row that
      // only mounts when isTablet. (Every other Row in the tree has 0 or 1
      // Expanded among its direct children.)
      expect(
        find.byWidgetPredicate((w) {
          if (w is! Row) return false;
          return w.children.whereType<Expanded>().length == 2;
        }),
        findsNWidgets(2),
      );
    });
  });
}

/// Local alias so the empty-state override can name the record type without
/// pulling in a private symbol from the production code.
typedef _TopProductTuple =
    ({String name, String? iconKey, int qty, int revenue});
