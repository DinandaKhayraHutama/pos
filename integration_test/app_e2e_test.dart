import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'helpers/pos_session.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/main.dart' as app;
import 'package:nti_pos/providers/settings_provider.dart';

/// E2E test yang verify semua halaman + flow utama bekerja.
/// Output: screenshots di build/, log di console.
///
/// Run:
///   flutter test integration_test/app_e2e_test.dart \
///     -d 810AB071-8AFC-41C5-B526-02246E314C4B
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('JustClick POS - All pages smoke test', () {
    testWidgets('Login + POS + each tab navigation', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Force logout to test login flow from scratch
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
      await container.read(settingsProvider.notifier).logout();
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // === STEP 1: Login page (account picker, then the number pad) ===
      print('=== STEP 1: Login page ===');
      // Sign-in is two steps now, and the PIN is checked against the CHOSEN
      // account — so this has to pick the CASHIER whose PIN is typed below.
      // It used to tap the manager tile and then type `2345`, which can never
      // succeed. Anchored on the role icon rather than a name: the icon is
      // stable, the name is seed data that has already changed once.
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(
        find.byIcon(Icons.person_outline_rounded),
        findsWidgets,
        reason: 'the account picker should list the cashiers',
      );
      await pickFirstCashierAccount(tester);

      // PIN pad has digits 0-9 - find them by exact text
      expect(find.text('1'), findsWidgets, reason: 'PIN pad 1 should exist');
      expect(find.text('2'), findsWidgets, reason: 'PIN pad 2 should exist');

      // Tap PIN 2345 (a cashier's PIN)
      // A cashier, not the manager: since managers lost `sell`, 1234 now
      // lands on the Dashboard and never reaches the till this test drives.
      for (final digit in ['2', '3', '4', '5']) {
        await tester.tap(find.text(digit).first);
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pumpAndSettle(const Duration(seconds: 2));
      // Selling now needs an open POS session, so a cashier lands on the till
      // picker rather than on the catalogue. Setup, not the assertion.
      await openPosSessionIfNeeded(tester, container);
      addTearDown(() => closePosSessionIfAny(tester, container));
      await IntegrationTestWidgetsFlutterBinding.instance
          .takeScreenshot('01_after_login');

      // Debug: what icons are visible?
      print('=== DEBUG: Icons visible ===');
      final iconWidgets = find.byType(Icon);
      final iconCount = iconWidgets.evaluate().length;
      print('Total Icon widgets: $iconCount');

      // === STEP 2: POS page ===
      print('=== STEP 2: POS page ===');
      // ProductCard grid is the POS signature — assert it directly (the
      // redesign kept GridView + ProductCard; only the nav bar changed).
      expect(find.byType(GridView), findsOneWidget,
          reason: 'POS catalog grid should be mounted');
      expect(
        find.byType(ProductCard),
        findsWidgets,
        reason: 'Product cards should render',
      );
      await IntegrationTestWidgetsFlutterBinding.instance
          .takeScreenshot('02_pos_page');
      print('POS page OK - product cards rendered');

      // === STEP 3: Tap a product card to add to cart ===
      print('=== STEP 3: Tap product to add to cart ===');
      // Tap the first ProductCard. GlassCard wraps the card's tap handler in
      // an InkWell, so this still lands on a real tap target.
      await tester.tap(find.byType(ProductCard).first);
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      // === STEP 4: Navigate to each tab ===
      print('=== STEP 4: Navigate to each tab ===');
      await _tapNavDestination(tester, 1); // Orders
      await tester.pumpAndSettle();
      await IntegrationTestWidgetsFlutterBinding.instance
          .takeScreenshot('03_orders_page');
      // Should show AppBar (any page)
      expect(find.byType(AppBar), findsWidgets);
      print('Orders page OK');

      await _tapNavDestination(tester, 2); // Tables
      await tester.pumpAndSettle();
      await IntegrationTestWidgetsFlutterBinding.instance
          .takeScreenshot('04_tables_page');
      expect(find.byType(AppBar), findsWidgets);
      print('Tables page OK');

      await _tapNavDestination(tester, 3); // Dashboard
      await tester.pumpAndSettle();
      await IntegrationTestWidgetsFlutterBinding.instance
          .takeScreenshot('05_dashboard_page');
      expect(find.byType(AppBar), findsWidgets);
      print('Dashboard page OK');

      await _tapNavDestination(tester, 4); // Settings
      await tester.pumpAndSettle();
      await IntegrationTestWidgetsFlutterBinding.instance
          .takeScreenshot('06_settings_page');
      expect(find.byType(AppBar), findsWidgets);
      print('Settings page OK');

      // === STEP 5: Changing a setting must not navigate away ===
      print('=== STEP 5: Settings changes keep you on the Settings tab ===');
      final settings = container.read(settingsProvider.notifier);
      final changes = <(String, Future<void> Function())>[
        ('theme', () => settings.setThemeMode(ThemeMode.dark)),
        ('brand colour', () => settings.setBrand(BrandPreset.presets.last)),
        ('language', () => settings.setLocale(const Locale('en'))),
        ('store name', () => settings.setStoreName('Warung Demo')),
      ];
      for (final (label, apply) in changes) {
        await apply();
        await tester.pumpAndSettle(const Duration(milliseconds: 600));
        expect(
          _selectedNavIndex(tester),
          4,
          reason: 'Changing the $label must not throw the user back to POS',
        );
        print('  $label changed - still on Settings');
      }
      await IntegrationTestWidgetsFlutterBinding.instance
          .takeScreenshot('07_settings_after_changes');

      // === STEP 6: Back to POS ===
      print('=== STEP 6: Back to POS ===');
      await _tapNavDestination(tester, 0);
      await tester.pumpAndSettle();
      final stillOnPos = find.byType(GridView).evaluate().isNotEmpty;
      expect(stillOnPos, true, reason: 'Should be back on POS page');
      print('Back to POS OK');

      print('=== ALL E2E TESTS PASSED ===');
    });
  });
}

/// Which bottom-nav tab is currently selected. Index-based so the assertion
/// stays locale-agnostic even after the language is switched mid-test.
///
/// The shell renders [GlassNav] on phones and [GlassNavRail] on tablets —
/// both expose the active `index`. The integration test runs on an iPhone
/// simulator (phone width), so [GlassNav] is the mounted widget.
int _selectedNavIndex(WidgetTester tester) =>
    tester.widget<GlassNav>(find.byType(GlassNav)).index;

/// Tap a [GlassNav] destination by zero-based index.
///
/// [GlassNav] is not a `NavigationBar` — its destinations are `InkWell`s
/// inside a `Row`, so we find them by descending from the [GlassNav] widget
/// (same pattern as `integration_test/screenshots_test.dart`). Icons are not
/// used as the finder because the active/inactive pair swaps on tap; the
/// index is stable and locale-agnostic.
Future<void> _tapNavDestination(WidgetTester tester, int index) async {
  final navBar = find.byType(GlassNav);
  expect(navBar, findsOneWidget,
      reason: 'GlassNav bottom bar should be mounted');
  final destinations = find.descendant(
    of: navBar,
    matching: find.byType(InkWell),
  );
  await tester.tap(destinations.at(index));
  await tester.pumpAndSettle(const Duration(milliseconds: 800));
}
