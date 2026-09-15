import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'helpers/pos_session.dart';

import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/main.dart' as app;
import 'package:nti_pos/providers/settings_provider.dart';

/// Visual verification of the redesigned (glassmorphism) screens.
///
/// Boots the app, force-logs-out so the login page is reached, then walks
/// every main screen — login → POS → cart → orders → tables → dashboard →
/// settings → product management — capturing a PNG at each stop.
///
/// All finds are locale-agnostic (digit text, Icon types, widget types) so
/// the test still passes after a language switch.
///
/// `flutter test` does not flush `binding.takeScreenshot` bytes to disk, so
/// each captured PNG is also written to `build/screenshots/<name>.png`.
///
/// Run:
///   flutter test integration_test/screenshots_test.dart \
///     -d 810AB071-8AFC-41C5-B526-02246E314C4B
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture screenshot of every redesigned screen', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Force logout so we start on the login page regardless of saved state.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container.read(settingsProvider.notifier).logout();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // 01 — Login page.
    expect(find.text('1'), findsWidgets, reason: 'PIN pad should render');
    await _shoot('01_login');

    // Pick the account, then enter PIN 2345 (a cashier — managers no longer
    // reach the till). The PIN is verified against the chosen row, so the pick
    // is not optional. Digits are not localized, safe to find by text.
    await pickFirstCashierAccount(tester);
    for (final digit in ['2', '3', '4', '5']) {
      await tester.tap(find.text(digit).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // Selling needs an open POS session, so a cashier lands on the till picker
    // rather than on the catalogue.
    await openPosSessionIfNeeded(tester, container, requireTableService: true);
    addTearDown(() => closePosSessionIfAny(tester, container));

    // 02 — POS page (catalog grid).
    expect(find.byType(ProductCard), findsWidgets,
        reason: 'Should land on POS with product cards');
    await _shoot('02_pos');

    // 03 — POS with an item in the cart.
    await tester.tap(find.byType(ProductCard).first);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    await _shoot('03_pos_with_cart');

    // 04 — Orders.
    await _tapGlassNav(tester, 1);
    await tester.pumpAndSettle();
    await _shoot('04_orders');

    // 05 — Order detail (only if any order tiles exist; demo data ships none,
    // so this step is opportunistic). The GlassNav bar also renders the
    // `receipt_long_outlined` icon in its inactive state, so we require at
    // least two hits before treating one as an order tile.
    final orderIcons = find.byIcon(Icons.receipt_long_outlined);
    if (orderIcons.evaluate().length > 1) {
      await tester.tap(orderIcons.last);
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await _shoot('05_order_detail');
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    // 06 — Tables.
    await _tapGlassNav(tester, 2);
    await tester.pumpAndSettle();
    await _shoot('06_tables');

    // 07 — Dashboard.
    await _tapGlassNav(tester, 3);
    await tester.pumpAndSettle();
    await _shoot('07_dashboard');

    // 08 — Settings.
    await _tapGlassNav(tester, 4);
    await tester.pumpAndSettle();
    await _shoot('08_settings');

    // 09 — Product management (pushed route from Settings tile).
    // The tile lives in the "Data" section, below the fold on a phone —
    // scroll until it is visible before tapping.
    await tester.scrollUntilVisible(
      find.byIcon(Icons.inventory_2_outlined),
      200.0,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final productMgmtTile = find.byIcon(Icons.inventory_2_outlined);
    expect(productMgmtTile, findsWidgets,
        reason: 'Settings should expose the product management tile');
    await tester.tap(productMgmtTile.first);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _shoot('09_product_mgmt');
  });
}

/// Capture a PNG both to the integration binding (for the JSON report) and
/// into the simulator's writable temp dir at `<systemTemp>/screenshots/<name>.png`.
///
/// The test runs inside the iOS app sandbox, where the project's `build/`
/// folder is read-only — so we cannot write there directly from the test.
/// After the test, copy the PNGs out with:
///   xcrun simctl get_app_container booted com.example.ntiPos data
///   # then look under tmp/screenshots/
Future<void> _shoot(String name) async {
  final bytes = await IntegrationTestWidgetsFlutterBinding.instance
      .takeScreenshot(name);
  final dir = Directory('${Directory.systemTemp.path}/screenshots');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  final file = File('${dir.path}/$name.png');
  await file.writeAsBytes(bytes);
  // ignore: avoid_print
  print('screenshot: ${file.path} (${bytes.length} bytes)');
}

/// Tap a [GlassNav] destination by zero-based index.
///
/// [GlassNav] is not a `NavigationBar` — its destinations are `InkWell`s
/// inside a `Row`, so we find them by descending from the [GlassNav] widget.
Future<void> _tapGlassNav(WidgetTester tester, int index) async {
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
