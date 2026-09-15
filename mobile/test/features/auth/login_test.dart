import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/pin_pad.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/preferences/app_preferences.dart';
import 'package:nti_pos/features/auth/login_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/settings_provider.dart';

import '../../helpers/db_helper.dart';

/// Widget tests for [LoginPage].
///
/// Sign-in is two steps now: pick an account, then type its PIN. Every test
/// therefore starts by tapping the seeded manager's tile — matched on the
/// employee's NAME, which is database content rather than a translated string,
/// so the assertion stays locale-agnostic.
///
/// PIN digits `1`..`9`, `0` are locale-neutral, so they are tapped via
/// `find.text(digit)`. The PIN auto-verifies at 4 digits and is resolved
/// against the CHOSEN employee row: `1234` is the manager's and signs in;
/// anything else fails, drives the dots to the error colour, clears `_pin`,
/// and fades the error caption in (`AnimatedOpacity.opacity == 1`).
///
/// Dot indicators are counted within the [PinPad] subtree specifically. They
/// used to be the only circular `AnimatedContainer`s in the tree, but the
/// chosen-account header carries a `CircleAvatar` — which is one too.
const _managerName = 'Siwi Wiyono Raharjo';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;

  setUpAll(() async {
    await initFfi();
  });

  setUp(() async {
    // Sign-in reads the employees table, so the page needs a real (in-memory)
    // database behind it. The seed includes the manager whose PIN is 1234.
    db = await openInMemoryAppDb(seed: true);
    await AppDatabase.instance.useTestDb(db);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  ProviderContainer makeContainer() {
    // Reset the cached prefs singleton BEFORE seeding mock values so the
    // next `AppPreferences.instance()` re-reads from the mocked store.
    AppPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    return ProviderContainer();
  }

  Future<void> pumpLogin(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    final brand = BrandPreset.presets.first;
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
          home: const LoginPage(),
        ),
      ),
    );
    // Let settingsProvider resolve before any interaction: `_verify`
    // calls `setLoggedIn`, which only mutates state when it is AsyncData.
    // LoginPage never watches settingsProvider itself, so we must prime the
    // notifier explicitly — otherwise `valueOrNull` stays null and the
    // post-verify assertion compares against null instead of `true`.
    await container.read(settingsProvider.future);
    // `pump`, not `pumpAndSettle`: while the account list loads, the picker
    // shows shimmering skeletons, and a repeating animation never settles.
    await tester.pump();

    // Step 1: choose the manager. The account list is a real database read, so
    // it needs a turn of the real clock before the tiles exist.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text(_managerName));
    // Settles now: the skeletons are gone with the picker.
    await tester.pumpAndSettle();
  }

  // Brand colours for the theme we pumped with. Dot `BoxDecoration` colours
  // are compared against these to decide "filled" vs "error".
  final primaryColor = AppTheme.light(BrandPreset.presets.first).colorScheme.primary;
  final errorColor = AppTheme.light(BrandPreset.presets.first).colorScheme.error;

  testWidgets('three digits fill three dots and do not verify', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await pumpLogin(tester, container);

    await tester.tap(find.text('1'));
    await tester.tap(find.text('2'));
    await tester.tap(find.text('3'));
    await tester.pump();

    expect(filledDotCount(tester, primaryColor), 3);
    // Still logged out: 4 digits were never reached.
    expect(container.read(settingsProvider).valueOrNull?.loggedIn, isFalse);
  });

  testWidgets('correct PIN 1234 sets loggedIn true', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await pumpLogin(tester, container);

    await tester.tap(find.text('1'));
    await tester.tap(find.text('2'));
    await tester.tap(find.text('3'));
    await tester.tap(find.text('4'));
    // `_verify` now resolves the PIN against the employees table. That is real
    // async I/O on the sqflite isolate, which pumpAndSettle alone does not
    // wait for — runAsync lets it actually complete before we assert.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider).valueOrNull?.loggedIn, isTrue);
  });

  testWidgets('wrong PIN drives dots to error colour and clears the pin',
      (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await pumpLogin(tester, container);

    await tester.tap(find.text('1'));
    await tester.tap(find.text('1'));
    await tester.tap(find.text('1'));
    await tester.tap(find.text('1'));
    // Same as above: the lookup is a real database round-trip.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pumpAndSettle();

    // Still logged out.
    expect(container.read(settingsProvider).valueOrNull?.loggedIn, isFalse);
    // The error caption is wrapped in a single AnimatedOpacity that targets
    // opacity 1 when `_error` is true.
    final opacity = tester
        .widget<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .opacity;
    expect(opacity, 1.0);
    // `_pin` has been cleared, so with `_error` still true every dot reads as
    // error and none is the primary colour. Matched on hue rather than the
    // exact colour: the cleared dots are the error colour at reduced alpha, so
    // that an empty field still LOOKS empty while it looks wrong. Four solid
    // red dots over an empty PIN read as "four digits still entered".
    expect(filledDotCount(tester, primaryColor), 0);
    expect(errorDotCount(tester, errorColor), 4);
    expect(
      solidErrorDotCount(tester, errorColor),
      0,
      reason: 'a cleared PIN must not paint filled-looking dots',
    );
  });

  testWidgets('backspace removes the last entered digit', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await pumpLogin(tester, container);

    await tester.tap(find.text('1'));
    await tester.pump();
    expect(filledDotCount(tester, primaryColor), 1);

    await tester.tap(find.byIcon(Icons.backspace_rounded));
    await tester.pump();
    expect(filledDotCount(tester, primaryColor), 0);
  });
}

/// Counts dot indicators whose target `BoxDecoration.color` matches [color].
///
/// Scoped to the [PinPad] subtree: a `CircleAvatar` is also an
/// `AnimatedContainer` with a circular `BoxDecoration`, and the chosen-account
/// header above the keypad has one.
int _dotCountWhere(WidgetTester tester, bool Function(Color?) test) {
  final matches = tester.widgetList<AnimatedContainer>(
    find.descendant(
      of: find.byType(PinPad),
      matching: find.byWidgetPredicate((w) {
        if (w is! AnimatedContainer) return false;
        final deco = w.decoration;
        return deco is BoxDecoration && deco.shape == BoxShape.circle;
      }),
    ),
  );
  return matches
      .where((c) {
        final deco = c.decoration as BoxDecoration;
        return test(deco.color);
      })
      .length;
}

int filledDotCount(WidgetTester tester, Color primary) =>
    _dotCountWhere(tester, (c) => c == primary);

/// Dots painted in the error hue at any opacity — filled or cleared.
int errorDotCount(WidgetTester tester, Color error) => _dotCountWhere(
  tester,
  (c) => c != null && c.withValues(alpha: 1) == error.withValues(alpha: 1),
);

/// Dots painted in the error hue at FULL opacity, i.e. ones that still read
/// as holding a digit.
int solidErrorDotCount(WidgetTester tester, Color error) =>
    _dotCountWhere(tester, (c) => c == error);
