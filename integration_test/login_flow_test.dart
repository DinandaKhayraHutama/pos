import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'helpers/pos_session.dart';

import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/features/pos/product_card.dart';
import 'package:nti_pos/main.dart' as app;
import 'package:nti_pos/providers/settings_provider.dart';

/// Integration test for the login flow: wrong PIN stays on login with an
/// error signal, correct PIN lands on POS.
///
/// Locale-agnostic throughout: PIN digits are plain text ('1'..'9'), the
/// wrong-PIN signal is read off the PIN-dot [AnimatedContainer] decoration
/// color (compared against the theme's `design.error` token) rather than the
/// translated `authWrongPin` string, and POS is anchored on [ProductCard] /
/// [GridView] widget types.
///
/// Run:
///   flutter test integration_test/login_flow_test.dart \
///     -d 810AB071-8AFC-41C5-B526-02246E314C4B
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('wrong PIN shows error and stays on login, correct PIN reaches POS',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Force logout to reach the login page from scratch, regardless of
    // whatever session state was left over from a previous test run.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await container.read(settingsProvider.notifier).logout();
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // === Sanity: login page mounted, and an account is chosen ===
    // Sign-in is two steps, and the PIN is verified against the CHOSEN row —
    // so the keypad does not exist until an account is picked. Both the wrong
    // PIN below and the correct one are therefore tested against the same
    // cashier, which is what makes the wrong-PIN case meaningful.
    await pickFirstCashierAccount(tester);
    expect(find.text('1'), findsWidgets, reason: 'PIN pad 1 should exist');
    expect(find.text('4'), findsWidgets, reason: 'PIN pad 4 should exist');

    // === STEP 1: Wrong PIN (1111) ===
    print('=== STEP 1: Wrong PIN ===');
    for (final digit in ['1', '1', '1', '1']) {
      await tester.tap(find.text(digit).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    // The login page auto-verifies at 4 digits.
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Anchor 1: still on login. ProductCard (POS-only) must be absent, and
    // the PIN pad digit '1' must still be rendered — the login page did not
    // navigate away.
    expect(find.byType(ProductCard), findsNothing,
        reason: 'Wrong PIN must not reach POS');
    expect(find.text('1'), findsWidgets,
        reason: 'PIN pad should still be visible on login after wrong PIN');

    // Anchor 2: structural error signal. LoginPage renders exactly 4 PIN-dot
    // AnimatedContainers; on a wrong PIN, `_pin` resets to '' and `_error`
    // becomes true, so every dot's BoxDecoration.color switches to
    // `design.error` (see _LoginPageState.build in login_page.dart). This is
    // a color/structural check, never the translated error text.
    final dotFinder = find.byType(AnimatedContainer);
    expect(dotFinder, findsNWidgets(4),
        reason: 'Login page should render exactly 4 PIN dots');
    final design = tester
        .element(dotFinder.first)
        .design;
    for (final element in dotFinder.evaluate()) {
      final widget = element.widget as AnimatedContainer;
      final decoration = widget.decoration as BoxDecoration;
      expect(decoration.color, design.error,
          reason: 'PIN dot should turn the error color after a wrong PIN');
    }
    print('Wrong PIN correctly rejected - error signal + still on login');

    // === STEP 2: Correct PIN (2345, a cashier) ===
    print('=== STEP 2: Correct PIN ===');
    for (final digit in ['2', '3', '4', '5']) {
      await tester.tap(find.text(digit).first);
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // A correct PIN now lands on the till picker, not the catalogue — selling
    // needs an open session. Opening one is setup; what this test asserts is
    // that the PIN got past the login page at all.
    await openPosSessionIfNeeded(tester, container);
    addTearDown(() => closePosSessionIfAny(tester, container));

    // Login page has unmounted, so the only GridView left is the POS catalog.
    expect(find.byType(GridView), findsOneWidget,
        reason: 'POS catalog grid should be mounted');
    expect(find.byType(ProductCard), findsWidgets,
        reason: 'Product cards should render after a correct PIN');
    print('Correct PIN logged in - POS catalog rendered');

    print('=== LOGIN FLOW TEST PASSED ===');
  });
}
