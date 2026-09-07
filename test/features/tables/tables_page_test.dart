import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/empty_state.dart';
import 'package:nti_pos/core/widgets/glass/glass_buttons.dart';
import 'package:nti_pos/core/widgets/glass/glass_card.dart';
import 'package:nti_pos/core/widgets/glass/glass_chip.dart';
import 'package:nti_pos/core/widgets/glass/glass_sheet.dart';
import 'package:nti_pos/core/widgets/glass/skeleton.dart';
import 'package:nti_pos/core/widgets/status_badge.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/table.dart';
import 'package:nti_pos/features/tables/tables_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/order_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Widget tests for [TablesPage].
///
/// Locale-agnostic by design:
/// - Table names (`T1`, `T2`, …) and capacity counts are DATA, not localized
///   strings — they are asserted verbatim.
/// - [StatusBadge] is matched by type and its `status` property, never by its
///   translated label.
/// - The `_SummaryRow` totals are matched by their numeric `Text` values
///   (`'4'`, `'2'`, `'1'`), which are independent of any .arb key.
/// - The status chips in the action sheet are matched by INDEX in a fixed
///   order [GlassFilterChip] list (available, occupied, reserved) rather than
///   by localized label — see `_TableTile._statusChip` call order.
/// - Loading / empty branches are matched by widget type ([Skeleton],
///   [EmptyState]) plus the [IconData] the empty state uses.
///
/// `tablesProvider` is an `AutoDisposeAsyncNotifierProvider` parameterized
/// over `TablesNotifier` and `List<RestaurantTable>`. Each test overrides it
/// with a fake whose `build` returns the seeded list, and whose `setStatus`
/// either captures the call (spy) or mutates the seed (so the badge update is
/// observable).
class _ResolvedSettingsNotifier extends SettingsNotifier {
  _ResolvedSettingsNotifier(this._initial);
  final SettingsState _initial;
  @override
  Future<SettingsState> build() async => _initial;
}

/// Fake [TablesNotifier] that returns a fixed list and records `setStatus`
/// calls without touching sqflite. Used by the status-chip spy test.
class _SpyTablesNotifier extends TablesNotifier {
  _SpyTablesNotifier(this._data);
  final List<RestaurantTable> _data;

  /// Calls captured by the last `setStatus` invocation. Public so the test can
  /// read it directly.
  final List<({String id, TableStatus status})> calls = [];

  @override
  Future<List<RestaurantTable>> build() async => _data;

  @override
  Future<void> setStatus(String id, TableStatus status) async {
    calls.add((id: id, status: status));
    // Mutate the seed so the badge update is observable too — the production
    // notifier refreshes from the DB, which we do not have under test.
    final i = _data.indexWhere((t) => t.id == id);
    if (i >= 0) {
      _data[i] = _data[i].copyWith(status: status);
    }
    state = AsyncData(_data);
  }
}

/// Fake whose `build` returns the literal list passed in. Used for the
/// read-only tests (counts, tiles, sheet-open) where we do not need a spy.
class _FakeTablesNotifier extends TablesNotifier {
  _FakeTablesNotifier(this._data);
  final List<RestaurantTable> _data;
  @override
  Future<List<RestaurantTable>> build() async => _data;
}

/// Fake whose `build` never completes so the provider stays in `AsyncLoading`.
class _HangingTablesNotifier extends TablesNotifier {
  _HangingTablesNotifier();
  @override
  Future<List<RestaurantTable>> build() =>
      Completer<List<RestaurantTable>>().future;
}

RestaurantTable _table({
  required String id,
  required String name,
  required TableStatus status,
  int capacity = 6,
  String floor = 'floor_1',
}) =>
    RestaurantTable(
      id: id,
      name: name,
      capacity: capacity,
      status: status,
      floor: floor,
      sortOrder: 0,
    );

final _t1 = _table(id: 't1', name: 'T1', status: TableStatus.available);
final _t2 = _table(id: 't2', name: 'T2', status: TableStatus.occupied);
final _t3 = _table(id: 't3', name: 'T3', status: TableStatus.reserved);
final _t4 = _table(id: 't4', name: 'T4', status: TableStatus.available);

/// Seed for the counts/tiles test: 4 tables → total=4, available=2,
/// occupied=1, reserved=1 (reserved has no summary stat). Capacities picked
/// outside {1,2,4} so capacity text ("6 seats") never collides with a summary
/// numeric value.
List<RestaurantTable> _seed() => [_t1, _t2, _t3, _t4];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpTables(
    WidgetTester tester, {
    List<Override> extraOverrides = const [],
    bool settle = true,
    Widget? home,
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

    // Surface sized so the sliver grid (maxCrossAxisExtent 170) lays the
    // four seed tables out in one row of four ~184px-wide tiles. Going wider
    // bumps the column count up and shrinks each tile, which makes the
    // StatusBadge overflow the icon Row (a real production layout quirk at
    // narrow tile widths — out of scope here). 800×1600 is the sweet spot:
    // enough cross-axis for 4 columns, enough height for summary + floor
    // label + grid + the action sheet.
    tester.view.physicalSize = const Size(800, 1600);
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
          home: home ?? const TablesPage(),
        ),
      ),
    );
    // The loading branch renders [Skeleton] bars whose `_Shimmer` ticker loops
    // forever — `pumpAndSettle` would time out. Callers exercising loading
    // pass `settle: false` and let the first frame land.
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  group('summary row', () {
    testWidgets(
        'total / available / occupied counts match the seeded list '
        '(4 total, 2 available, 1 occupied)', (tester) async {
      await pumpTables(
        tester,
        extraOverrides: [
          tablesProvider.overrideWith(() => _FakeTablesNotifier(_seed())),
        ],
      );

      // `_SummaryRow` renders the three counts as bare numeric `Text` widgets
      // via `_StatTile.value`. Capacities in the seed are all 6 → the only
      // '4', '2', '1' Text nodes in the tree are the summary values.
      expect(find.text('4'), findsOneWidget); // total
      expect(find.text('2'), findsOneWidget); // available
      expect(find.text('1'), findsOneWidget); // occupied
    });
  });

  group('tiles', () {
    testWidgets(
        'renders one _TableTile per table, each with its name + a StatusBadge '
        'carrying the right status', (tester) async {
      await pumpTables(
        tester,
        extraOverrides: [
          tablesProvider.overrideWith(() => _FakeTablesNotifier(_seed())),
        ],
      );

      // Names are data, not localized strings.
      expect(find.text('T1'), findsOneWidget);
      expect(find.text('T2'), findsOneWidget);
      expect(find.text('T3'), findsOneWidget);
      expect(find.text('T4'), findsOneWidget);

      // One StatusBadge per tile (the summary row uses _StatTile, not badges).
      expect(find.byType(StatusBadge), findsNWidgets(4));

      // Per-tile status correctness — match the badge widget whose `status`
      // field equals each expected enum value.
      expect(
        find.byWidgetPredicate(
          (w) => w is StatusBadge && w.status == TableStatus.available,
        ),
        findsNWidgets(2),
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is StatusBadge && w.status == TableStatus.occupied,
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is StatusBadge && w.status == TableStatus.reserved,
        ),
        findsOneWidget,
      );
    });
  });

  group('action sheet', () {
    testWidgets(
        'tapping a tile opens the glass sheet with the table name and three '
        'status chips', (tester) async {
      await pumpTables(
        tester,
        extraOverrides: [
          tablesProvider.overrideWith(() => _FakeTablesNotifier(_seed())),
        ],
      );

      // `_TableTile` builds its card via `GlassCard.solid(onTap: …)`; the
      // sliver grid paints 4 of them. Tap the first tile (T1 — available).
      // We target by the table's name Text and walk up to the tappable card.
      final t1Card = find.ancestor(
        of: find.text('T1'),
        matching: find.byType(GlassCard),
      );
      expect(t1Card, findsOneWidget);

      await tester.tap(t1Card);
      await tester.pumpAndSettle();

      // Sheet mounts a GlassSheet with the table name and the table's own
      // StatusBadge at the top, plus three status GlassFilterChips.
      expect(find.byType(GlassSheet), findsOneWidget);
      // T1's name should appear twice now (tile + sheet header), so scope the
      // sheet's copy to descendants of GlassSheet.
      expect(
        find.descendant(
          of: find.byType(GlassSheet),
          matching: find.text('T1'),
        ),
        findsOneWidget,
      );
      // Chips are built in fixed order: available, occupied, reserved.
      expect(find.byType(GlassFilterChip), findsNWidgets(3));
    });

    testWidgets(
        'tapping the "occupied" status chip calls setStatus(id, occupied) '
        'on the notifier', (tester) async {
      final fake = _SpyTablesNotifier(_seed());
      await pumpTables(
        tester,
        extraOverrides: [
          tablesProvider.overrideWith(() => fake),
        ],
      );

      // Open T1's action sheet.
      await tester.tap(
        find.ancestor(
          of: find.text('T1'),
          matching: find.byType(GlassCard),
        ),
      );
      await tester.pumpAndSettle();

      // Chips in fixed order: 0=available, 1=occupied, 2=reserved.
      final occupiedChip = find.byType(GlassFilterChip).at(1);
      expect(occupiedChip, findsOneWidget);

      await tester.tap(occupiedChip);
      await tester.pumpAndSettle();

      // Spy recorded the call against T1 with the occupied status.
      expect(fake.calls, [
        (id: 't1', status: TableStatus.occupied),
      ]);
    });
  });

  group('start order', () {
    testWidgets(
        'the available table\'s sheet shows a PrimaryButton "start order" and '
        'tapping it navigates to / via context.go', (tester) async {
      // The production `context.go('/')` needs a GoRouter on the ancestor —
      // without one the tap throws "no router". Mount TablesPage at `/tables`
      // inside a minimal router whose `/` route paints a sentinel Text, so we
      // can assert the navigation actually fired.
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
          tablesProvider.overrideWith(() => _FakeTablesNotifier(_seed())),
        ],
      );
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      const posMarkerKey = Key('pos-host-marker');
      final router = GoRouter(
        initialLocation: '/tables',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(
              body: Center(
                child: Text('POS_HOST', key: posMarkerKey),
              ),
            ),
          ),
          GoRoute(
            path: '/tables',
            builder: (_, _) => const TablesPage(),
          ),
        ],
      );

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

      // Open T1 (available) — only available tables render the start-order
      // PrimaryButton.
      await tester.tap(
        find.ancestor(
          of: find.text('T1'),
          matching: find.byType(GlassCard),
        ),
      );
      await tester.pumpAndSettle();

      // The PrimaryButton carries the `add_shopping_cart_rounded` icon —
      // match it by type so the assertion stays label-agnostic.
      final startOrder = find.byType(PrimaryButton);
      expect(startOrder, findsOneWidget);
      expect(
        find.descendant(
          of: startOrder,
          matching: find.byIcon(Icons.add_shopping_cart_rounded),
        ),
        findsOneWidget,
      );

      await tester.tap(startOrder);
      await tester.pumpAndSettle();

      // `context.go('/')` fired → the sentinel mounts and the sheet is gone.
      expect(find.byKey(posMarkerKey), findsOneWidget);
      expect(find.byType(GlassSheet), findsNothing);
    });
  });

  group('loading & empty', () {
    testWidgets(
        'AsyncLoading renders the skeleton bars and no tiles', (tester) async {
      await pumpTables(
        tester,
        settle: false,
        extraOverrides: [
          tablesProvider.overrideWith(() => _HangingTablesNotifier()),
        ],
      );

      // TablesPage's loading branch renders `LoadingIndicator.skeleton(lines:
      // 4)` — four Skeleton bars. (Do not pumpAndSettle: the shimmer ticker
      // loops forever.)
      expect(find.byType(Skeleton), findsNWidgets(4));
      expect(find.byType(StatusBadge), findsNothing);
      expect(find.byType(EmptyState), findsNothing);
    });

    testWidgets(
        'empty list renders the EmptyState with the table icon and zero tiles',
        (tester) async {
      await pumpTables(
        tester,
        extraOverrides: [
          tablesProvider.overrideWith(() => _FakeTablesNotifier(const [])),
        ],
      );

      expect(find.byType(EmptyState), findsOneWidget);
      expect(
        find.byIcon(Icons.table_restaurant_rounded),
        findsOneWidget,
      );
      expect(find.byType(StatusBadge), findsNothing);
    });
  });
}
