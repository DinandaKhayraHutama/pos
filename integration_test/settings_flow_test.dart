import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/widgets/glass/glass_buttons.dart';
import 'package:nti_pos/core/widgets/glass/glass_nav.dart';
import 'package:nti_pos/data/preferences/app_preferences.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/main.dart' as app;
import 'package:nti_pos/providers/settings_provider.dart';

/// Integration test for the settings-persistence flow: change theme, brand
/// colour, and language, assert each applies live (theme brightness flips,
/// brand primary changes), assert the choices persisted to the on-device
/// preference store (read back through [AppPreferences]), and finally log out
/// back to the login screen.
///
/// Persistence is verified by re-reading [AppPreferences] (the same backing
/// store the next app launch reads) rather than by restarting the process -
/// the integration binding cannot reboot the app under test mid-run, and the
/// getters read the real on-device SharedPreferences the setters wrote.
///
/// Locale-agnostic throughout: theme and language are applied via fixed icon
/// / code anchors (`dark_mode_rounded`, the `ID` language-code badge), the
/// brand swatch is found by its data tooltip (`BrandPreset.name`), and live
/// application is asserted on `Theme.brightness` / `colorScheme.primary` -
/// never on a translated label. The reset-demo-data path is exercised by the
/// settings widget tests and is omitted here to avoid re-seeding the shared
/// simulator DB mid-suite.
///
/// Run:
///   flutter test integration_test/settings_flow_test.dart \
///     -d 810AB071-8AFC-41C5-B526-02246E314C4B
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('theme/brand/language apply live and persist; logout works',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container.read(settingsProvider.notifier).logout();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 1: Login -> Settings ===
    for (final digit in ['1', '2', '3', '4']) {
      await tester.tap(find.text(digit).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await _tapNavDestination(tester, 4); // Settings
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === STEP 2: Theme -> dark (applies live) ===
    print('=== STEP 2: Theme dark ===');
    await tester.tap(find.byIcon(Icons.dark_mode_rounded));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(_brightness(tester), Brightness.dark,
        reason: 'Selecting the dark theme must flip the live theme to dark');
    print('Theme applied: dark');

    // === STEP 3: Brand colour (applies live) ===
    print('=== STEP 3: Brand colour ===');
    final primaryBefore = _primary(tester);
    final newBrand = BrandPreset.presets[1];
    await tester.ensureVisible(find.byTooltip(newBrand.name));
    await tester.tap(find.byTooltip(newBrand.name));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(_primary(tester), isNot(primaryBefore),
        reason: 'Selecting a different brand must change the live primary');
    print('Brand applied: ${newBrand.id}');

    // === STEP 4: Language -> ID ===
    print('=== STEP 4: Language ID ===');
    // The ID language tile carries a 'ID' code badge (data, not a translation).
    await tester.tap(find.text('ID'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    print('Language applied: id');

    // === STEP 5: Persistence (read back the on-device store) ===
    print('=== STEP 5: Assert persisted ===');
    final prefs = await AppPreferences.instance();
    expect(prefs.themeMode, ThemeMode.dark,
        reason: 'Dark theme must persist to preferences');
    expect(prefs.brand.id, newBrand.id,
        reason: 'The chosen brand must persist to preferences');
    expect(prefs.locale, const Locale('id'),
        reason: 'The id locale must persist to preferences');
    print('Settings persisted across the preference store');

    // === STEP 6: Logout -> login screen ===
    print('=== STEP 6: Logout ===');
    // The DangerButton sits at the bottom of the lazy settings list, so scroll
    // it into view first.
    await tester.scrollUntilVisible(find.byType(DangerButton), 300);
    // scrollUntilVisible only guarantees the widget is built (cacheExtent),
    // not that it is hit-testable. The DangerButton is the last list item, so
    // a plain reveal leaves it resting on the GlassNav (tap misses); scroll it
    // to the vertical center of the viewport, clear of the nav, before tapping.
    await Scrollable.ensureVisible(
      tester.element(find.byType(DangerButton)),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DangerButton));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.text('1'), findsWidgets,
        reason: 'PIN pad should be visible after logout');
    expect(find.byType(ProductCard), findsNothing,
        reason: 'Logout must leave the POS catalog');
    print('Logged out to login');

    print('=== SETTINGS FLOW TEST PASSED ===');
  });
}

Brightness _brightness(WidgetTester t) =>
    Theme.of(t.element(find.byType(Scaffold).first)).brightness;

Color _primary(WidgetTester t) =>
    Theme.of(t.element(find.byType(Scaffold).first)).colorScheme.primary;

/// Tap a [GlassNav] destination by zero-based index (same pattern as
/// `integration_test/app_e2e_test.dart`).
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
