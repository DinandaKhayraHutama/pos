import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/login_page.dart';
import '../../features/dashboard/dashboard_page.dart';
import '../../features/inventory/inventory_page.dart';
import '../../features/promos/promo_management_page.dart';
import '../../features/orders/order_detail_page.dart';
import '../../features/orders/orders_page.dart';
import '../../features/pos/pos_page.dart';
import '../../features/reports/report_page.dart';
import '../../features/recovery/recovery_center_page.dart';
import '../../features/shift/shift_page.dart';
import '../../features/employees/employee_management_page.dart';
import '../../features/outlets/outlet_management_page.dart';
import '../../features/products/product_management_page.dart';
import '../../features/registers/register_management_page.dart';
import '../../features/settings/settings_page.dart';
import '../../features/shared/main_shell.dart';
import '../../features/splash/splash_page.dart';
import '../../features/tables/table_management_page.dart';
import '../../features/tables/tables_page.dart';
import '../../providers/settings_provider.dart';
import '../../data/device/till_binding.dart';
import '../auth/permissions.dart';

/// iOS-style right-to-left slide for PUSHED routes only (never tab switches).
///
/// The ShellRoute tab routes (`/`, `/orders`, `/tables`, `/dashboard`,
/// `/settings`) use [NoTransitionPage] for an explicit instant swap — a slide
/// on tab change clashes with the bottom-nav mental model, and leaving them
/// on the default MaterialPage means the platform pageTransitionsTheme
/// (zoom/fade on Android) animates them anyway. Pushed routes (`/orders/:id`, `/products`)
/// feel like drilling into a stack, so they get the familiar horizontal slide.
///
/// Implemented inline (not via `CupertinoPageTransitionsBuilder`) so it works
/// identically on iOS, Android, and macOS without per-platform branching, and
/// so it does NOT touch `routerProvider`'s stability — `pageBuilder` is a
/// static closure that doesn't `ref.watch` anything; `router_stability_test`
/// stays green.
Page<T> _iosSlidePage<T>({required LocalKey key, required Widget child}) {
  return CustomTransitionPage<T>(
    key: key,
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // Driven off the primary route transition curve so the push and the
      // pop (reverse) feel native-iOS: fast ease-out going forward, gentle
      // ease-in coming back.
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      );
    },
  );
}

/// The permission each guarded route needs.
///
/// Paths absent from this map are open to any signed-in user: `/orders` and
/// `/settings` are reachable by every role, and gating them would only mean a
/// role with nowhere to land.
///
/// Anything listed here must keep [homeRouteFor] reachable for every role, or
/// the redirect bounces a user between two closed doors forever. Note `/orders/:id` is not listed — the
/// list it opens from is already scoped per role, so a cashier can only ever
/// arrive at an order that is theirs.
const routePermissions = <String, AppPermission>{
  // The sell screen is a guarded route, not merely a hidden tab. An owner or
  // manager typing `/` would otherwise land on a till they are not supposed to
  // run — and on the web that is one keystroke away.
  '/': AppPermission.sell,
  '/tables': AppPermission.manageTables,
  '/dashboard': AppPermission.viewDailySummary,
  '/report': AppPermission.viewFinancialReports,
  '/products': AppPermission.manageCatalogue,
  '/inventory': AppPermission.adjustStock,
  '/promos': AppPermission.managePromos,
  '/employees': AppPermission.manageEmployees,
  '/outlets': AppPermission.manageOutlets,
  '/registers': AppPermission.manageOutlets,
  // Table CONFIGURATION (add/edit/deactivate), not the cashier's floor board
  // — that is `/tables`, gated by `manageTables`, which a cashier also
  // holds. This is Manager/Owner setup, so it takes the same permission
  // `/registers` uses rather than a new one.
  '/floorplan': AppPermission.manageOutlets,
  '/shift': AppPermission.openCloseShift,
};

/// Routes that only exist where guests are seated at tables.
///
/// A second gate alongside [routePermissions], because the two answer
/// different questions: that map asks whether this PERSON may open the screen,
/// this set asks whether the thing the screen is about EXISTS here. A takeaway
/// till fails the second even for an owner, who passes every permission there
/// is.
///
/// Since table service became a per-register setting the answer depends on
/// which till the device is signed on to — `SettingsState.tableServiceEnabled`
/// resolves that, so this gate did not have to change.
const tableServiceRoutes = <String>{'/tables'};

/// The POS session requirement is enforced INSIDE `PosPage`, not here.
///
/// A cashier picks a POS and opens a session before any money moves, so every
/// order can name the drawer it went into — but `/` is a `ShellRoute` tab, and
/// a `redirect` that sent an unsessioned cashier to the pushed `/shift` route
/// took `MainShell` (and its bottom nav / rail) down with it: the cashier
/// landed on a screen with no way to switch tabs, closing the very trap the
/// tab bar exists to prevent.
///
/// `PosPage` reads `SettingsState.hasPosSession` itself and renders
/// `PosSessionOpenCard` in place of the catalogue when it is false — same
/// URL, same shell, nav bar intact. See `PosSessionOpenCard`'s doc comment.
final routerProvider = Provider<GoRouter>((ref) {
  // Deliberately does NOT watch settingsProvider. Watching would rebuild this
  // provider on every settings change, handing MaterialApp.router a brand new
  // GoRouter, which remounts at [initialLocation] and throws the user back to
  // the POS page while they are changing a theme, brand colour or language.
  // The router instance stays stable for the whole session; [refreshListenable]
  // re-runs [redirect] instead, and [redirect] reads the settings itself.
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: _SettingsListenable(ref),
    redirect: (context, state) {
      final settings = ref.read(settingsProvider);
      final ready = settings.hasValue && !settings.isLoading;
      final loggedIn = settings.valueOrNull?.loggedIn ?? false;
      final path = state.uri.path;

      if (!ready) return '/splash';

      final home = settings.valueOrNull?.homeRoute ?? '/';
      if (path == '/splash') {
        return loggedIn ? home : '/login';
      }
      if (!loggedIn && path != '/login') return '/login';
      if (loggedIn && path == '/login') return home;

      // Connected master data has one writer: Backoffice. Keep demo editors,
      // but a typed URL must not bypass their hidden navigation links.
      if (TillBinding.current != null &&
          (path == '/products' ||
              path.startsWith('/products/') ||
              path == '/promos' ||
              path == '/floorplan')) {
        return '/settings';
      }

      // Role gate. Hiding a screen from the navigation is presentation; this
      // is the part that actually holds, because a URL typed into the browser
      // (the demo runs on the web) bypasses every hidden button. Unknown paths
      // fall through to go_router's own 404 rather than being redirected —
      // silently sending a typo to the dashboard hides real broken links.
      final required = routePermissions[path];
      if (required != null && settings.valueOrNull?.can(required) != true) {
        return home;
      }

      // Store-capability gate, for the same reason as the role gate above: the
      // Tables tab is gone from the navigation when the store has no floor
      // plan, but /tables typed into the address bar would still open a board
      // of tables the business does not have.
      if (tableServiceRoutes.contains(path) &&
          settings.valueOrNull?.tableServiceEnabled != true) {
        return home;
      }

      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashPage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      ShellRoute(
        builder: (context, state, child) => MainShell(child: child),
        routes: [
          GoRoute(
            path: '/',
            name: 'pos',
            // Tab routes use pageBuilder + NoTransitionPage, not builder.
            // With builder, go_router wraps the page in a plain MaterialPage,
            // which inherits the platform pageTransitionsTheme (zoom/fade on
            // Android, slide on iOS) — the old page visibly animates under
            // the new one on every tab switch. Tab switches must be instant.
            pageBuilder: (_, state) =>
                NoTransitionPage(key: state.pageKey, child: const PosPage()),
          ),
          GoRoute(
            path: '/orders',
            name: 'orders',
            pageBuilder: (_, state) =>
                NoTransitionPage(key: state.pageKey, child: const OrdersPage()),
          ),
          GoRoute(
            path: '/tables',
            name: 'tables',
            pageBuilder: (_, state) =>
                NoTransitionPage(key: state.pageKey, child: const TablesPage()),
          ),
          GoRoute(
            path: '/dashboard',
            name: 'dashboard',
            pageBuilder: (_, state) => NoTransitionPage(
              key: state.pageKey,
              child: const DashboardPage(),
            ),
          ),
          GoRoute(
            path: '/settings',
            name: 'settings',
            pageBuilder: (_, state) => NoTransitionPage(
              key: state.pageKey,
              child: const SettingsPage(),
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/orders/:id',
        name: 'orderDetail',
        // Pushed route — iOS-style right-to-left slide. Tab switches inside
        // the ShellRoute stay instant (no pageBuilder here for them).
        pageBuilder: (context, state) => _iosSlidePage(
          key: state.pageKey,
          child: OrderDetailPage(orderId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: '/recovery',
        name: 'recovery',
        pageBuilder: (context, state) => _iosSlidePage(
          key: state.pageKey,
          child: const RecoveryCenterPage(),
        ),
      ),
      GoRoute(
        path: '/report',
        name: 'report',
        pageBuilder: (context, state) =>
            _iosSlidePage(key: state.pageKey, child: const ReportPage()),
      ),
      GoRoute(
        path: '/shift',
        name: 'shift',
        pageBuilder: (context, state) =>
            _iosSlidePage(key: state.pageKey, child: const ShiftPage()),
      ),
      GoRoute(
        path: '/employees',
        name: 'employees',
        pageBuilder: (context, state) => _iosSlidePage(
          key: state.pageKey,
          child: const EmployeeManagementPage(),
        ),
      ),
      GoRoute(
        path: '/outlets',
        name: 'outlets',
        pageBuilder: (context, state) => _iosSlidePage(
          key: state.pageKey,
          child: const OutletManagementPage(),
        ),
      ),
      GoRoute(
        path: '/registers',
        name: 'registers',
        // The branch whose tills to show arrives as `?outlet=`, not as a path
        // segment: a query parameter leaves `state.uri.path` alone, so the one
        // exact-match row in [routePermissions] still covers this route.
        // Absent means the branch this device is standing in.
        pageBuilder: (context, state) => _iosSlidePage(
          key: state.pageKey,
          child: RegisterManagementPage(
            outletId: state.uri.queryParameters['outlet'],
          ),
        ),
      ),
      GoRoute(
        path: '/floorplan',
        name: 'floorplan',
        // Same query-param shape as `/registers`: the branch to configure
        // arrives as `?outlet=`, not a path segment, so the exact-match row
        // in [routePermissions] still covers it. Absent means the branch
        // this device is standing in.
        pageBuilder: (context, state) => _iosSlidePage(
          key: state.pageKey,
          child: TableManagementPage(
            outletId: state.uri.queryParameters['outlet'],
          ),
        ),
      ),
      GoRoute(
        path: '/products',
        name: 'products',
        pageBuilder: (context, state) => _iosSlidePage(
          key: state.pageKey,
          child: const ProductManagementPage(),
        ),
      ),
      GoRoute(
        path: '/inventory',
        name: 'inventory',
        pageBuilder: (context, state) =>
            _iosSlidePage(key: state.pageKey, child: const InventoryPage()),
      ),
      GoRoute(
        path: '/promos',
        name: 'promos',
        pageBuilder: (context, state) => _iosSlidePage(
          key: state.pageKey,
          child: const PromoManagementPage(),
        ),
      ),
    ],
  );
});

/// Bridges Riverpod settings into a [Listenable] for go_router refresh.
class _SettingsListenable extends ChangeNotifier {
  _SettingsListenable(Ref ref) {
    ref.listen<AsyncValue<SettingsState>>(settingsProvider, (_, _) {
      notifyListeners();
    });
  }
}
