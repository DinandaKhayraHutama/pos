import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nti_pos/core/auth/permissions.dart';
import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/router/app_router.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/data/models/category.dart';
import 'package:nti_pos/data/models/employee.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/preferences/app_preferences.dart';
import 'package:nti_pos/features/auth/login_page.dart';
import 'package:nti_pos/features/pos/pos_page.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/features/splash/splash_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/catalog_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Widget tests for the `/splash` redirect.
///
/// `routerProvider`'s `redirect` resolves `/splash` → `/login` when
/// `settings.loggedIn` is false, and `/splash` → `/` (POS) when it is true.
/// The assertions stay locale-agnostic: they check which page widget mounts
/// (`LoginPage`, `PosPage`) rather than any translated label, and never match
/// on `SplashPage` — a still-mounted splash would mean the redirect stalled.
///
/// `PosPage` watches [productsProvider] / [categoriesProvider], whose `build`
/// calls into `AppDatabase` via the repositories. Under `flutter test` that
/// hits `sqflite_common_ffi` timers that outlive the test frame, so the
/// catalog providers are overridden with empty fakes — the redirect logic
/// itself reads only `settingsProvider`, so this swap does not weaken what the
/// test is asserting.
class _EmptyProductsNotifier extends ProductsNotifier {
  @override
  Future<List<Product>> build() async => const [];
}

class _EmptyCategoriesNotifier extends CategoriesNotifier {
  @override
  Future<List<Category>> build() async => const [];
}

/// Settings that resolve immediately at a chosen role, with no database.
class _RoleSettingsNotifier extends SettingsNotifier {
  _RoleSettingsNotifier({
    required this.loggedIn,
    required this.role,
    this.posSessionId = '',
  });
  final bool loggedIn;
  final EmployeeRole role;

  /// Whether this device is signed on to a till.
  ///
  /// `PosPage` renders `_SessionGate` instead of the catalogue while this is
  /// empty, so a test that wants `find.byType(ProductCard)` to find anything
  /// has to say it has a session.
  final String posSessionId;

  @override
  Future<SettingsState> build() async => SettingsState(
    themeMode: ThemeMode.light,
    brand: BrandPreset.presets.first,
    locale: const Locale('en'),
    pb1Rate: 0,
    serviceChargeEnabled: false,
    serviceChargeRate: 0,
    currency: 'Rp',
    storeName: 'Test',
    storeAddress: '',
    cashierName: 'Tester',
    loggedIn: loggedIn,
    employeeRole: role,
    posSessionId: posSessionId,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Reset the cached prefs singleton BEFORE seeding mock values so the
    // next `AppPreferences.instance()` re-reads from the mocked store.
    AppPreferences.resetForTest();
  });

  ProviderContainer makeContainer({
    required bool loggedIn,
    EmployeeRole role = EmployeeRole.cashier,
    String posSessionId = '',
  }) {
    SharedPreferences.setMockInitialValues({'logged_in': loggedIn});
    return ProviderContainer(
      overrides: [
        productsProvider.overrideWith(_EmptyProductsNotifier.new),
        categoriesProvider.overrideWith(_EmptyCategoriesNotifier.new),
        // The role decides the landing route, so the redirect test has to be
        // able to name it. Overridden rather than seeded through the employees
        // table: this test has no database.
        settingsProvider.overrideWith(
          () => _RoleSettingsNotifier(
            loggedIn: loggedIn,
            role: role,
            posSessionId: posSessionId,
          ),
        ),
      ],
    );
  }

  Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
    final brand = BrandPreset.presets.first;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: container.read(routerProvider),
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
    // Drive frames manually instead of `pumpAndSettle`: the redirect chain
    // (settingsProvider resolve → refreshListenable → redirect → mount) plays
    // out over a few microtask boundaries, and once PosPage mounts its
    // skeleton loaders animate forever, which would hang `pumpAndSettle`.
    // 500ms of frames is plenty for the redirect without waiting on the
    // skeleton shimmer.
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
  }

  testWidgets('/splash redirects to /login when logged out', (tester) async {
    final container = makeContainer(loggedIn: false);
    addTearDown(container.dispose);
    await pumpApp(tester, container);

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(SplashPage), findsNothing);
  });

  testWidgets('/splash redirects to the role home when logged in', (
    tester,
  ) async {
    // A cashier who is already signed on to a till. Without a session,
    // `PosPage` shows `_SessionGate` instead of the catalogue — see the
    // regression test below — which is correct, and not what this test is
    // about.
    final container = makeContainer(
      loggedIn: true,
      role: EmployeeRole.cashier,
      posSessionId: 'session_1',
    );
    addTearDown(container.dispose);
    await pumpApp(tester, container);

    expect(find.byType(PosPage), findsOneWidget);
    expect(find.byType(SplashPage), findsNothing);
  });

  testWidgets(
    'a cashier with no POS session keeps the bottom nav, on `/` and after '
    'switching tabs and back',
    (tester) async {
      // Regression guard: selling needs an open session, and that used to be
      // enforced with a `redirect` from `/` to the pushed `/shift` route.
      // `/shift` sits OUTSIDE `MainShell`'s `ShellRoute`, so the redirect took
      // the bottom nav (and the whole shell) down with it — a cashier who had
      // just closed their drawer landed on a screen with no way to switch
      // tabs at all. The fix moved the gate INSIDE `PosPage`, which renders
      // `_SessionGate` in place of the catalogue but stays mounted as the
      // Shell's `/` child, so `MainShell` keeps painting the nav around it
      // exactly as it does for every other tab.
      final container = makeContainer(
        loggedIn: true,
        role: EmployeeRole.cashier,
        posSessionId: '',
      );
      addTearDown(container.dispose);
      await pumpApp(tester, container);

      // Still `/` — `PosPage` itself mounted, only its INTERNAL content
      // changed — and the catalogue must not render before a session exists.
      expect(find.byType(PosPage), findsOneWidget);
      expect(find.byType(ProductCard), findsNothing);
      // The nav survived. Whichever chrome this width picks (bottom bar on a
      // phone, side rail on a tablet), one of the two must be mounted.
      expect(
        find.byType(GlassNav).evaluate().isNotEmpty ||
            find.byType(GlassNavRail).evaluate().isNotEmpty,
        isTrue,
        reason: 'MainShell must stay mounted around the session gate',
      );

      // The exact scenario described in the bug report: leave the tab and
      // come back.
      final router = container.read(routerProvider);
      router.go('/orders');
      await tester.pump(const Duration(milliseconds: 200));
      router.go('/');
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(ProductCard), findsNothing);
      expect(
        find.byType(GlassNav).evaluate().isNotEmpty ||
            find.byType(GlassNavRail).evaluate().isNotEmpty,
        isTrue,
        reason: 'nav must still be there and switchable after the round trip',
      );
    },
  );

  testWidgets('only a cashier lands on the till', (tester) async {
    // The role decides where sign-in ends up: a cashier opens on the till,
    // everyone else on the numbers — a manager included, since neither they
    // nor an owner can open the sell screen any more. Asserted through the
    // router rather than by mounting DashboardPage, which would drag the whole
    // reporting stack (and its database calls) into a routing test.
    final container = makeContainer(loggedIn: true, role: EmployeeRole.owner);
    addTearDown(container.dispose);

    expect(homeRouteFor(EmployeeRole.owner), '/dashboard');
    expect(homeRouteFor(EmployeeRole.manager), '/dashboard');
    expect(homeRouteFor(EmployeeRole.cashier), '/');
  });
}
