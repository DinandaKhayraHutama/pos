import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:nti_pos/core/localization/l10n.dart';
import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/core/theme/app_theme.dart';
import 'package:nti_pos/core/widgets/glass/glass_buttons.dart';
import 'package:nti_pos/features/products/product_management_page.dart';
import 'package:nti_pos/features/settings/settings_page.dart';
import 'package:nti_pos/l10n/gen/app_localizations.dart';
import 'package:nti_pos/providers/settings_provider.dart';

/// Widget tests for [SettingsPage].
///
/// Locale-agnostic by design:
/// - Theme chips are matched by their leading [IconData]
///   (`Icons.light_mode_rounded`, `Icons.dark_mode_rounded`,
///   `Icons.brightness_auto_rounded`) and tapped by icon — never by localized
///   label text.
/// - Brand swatches are matched by their `Tooltip(message: p.name)`, where
///   `p.name` is DATA ('Flame', 'Crimson', 'Royal', 'Ocean', 'Forest',
///   'Amber') — not a localized string.
/// - Language tiles are matched by their two-letter `code` Text ('EN' / 'ID')
///   — DATA, not a localized label. The selected indicator
///   (`Icons.check_circle_rounded`) appears exactly once regardless of which
///   language is active, so its count is a stable visual invariant.
/// - Business / tax edit dialogs are matched by widget type
///   ([AlertDialog], [TextField], [FilledButton], [TextButton]); their
///   save/cancel labels are localized and never asserted.
/// - Setter invocation is verified by reading back the resulting state from
///   `container.read(settingsProvider).valueOrNull?.<field>` — locale-agnostic
///   and deterministic.
///
/// Production [SettingsNotifier.build] calls `AppPreferences.instance()` and
/// caches the singleton on a private `late` field; every setter then awaits a
/// `_prefs.setX(...)` call. The real `build` is bypassed here by
/// [_SpySettingsNotifier], which returns the seeded state directly AND
/// overrides each setter to mutate state without touching SharedPreferences —
/// so reading the state back after a tap reflects what the user did, and the
/// notifier never touches `AppPreferences` or the disk.
class _SpySettingsNotifier extends SettingsNotifier {
  _SpySettingsNotifier(this._initial, {this.onResetDemoData});
  final SettingsState _initial;
  final VoidCallback? onResetDemoData;

  @override
  Future<SettingsState> build() async => _initial;

  @override
  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.whenData((s) => s.copyWith(themeMode: mode));
  }

  @override
  Future<void> setBrand(BrandPreset brand) async {
    state = state.whenData((s) => s.copyWith(brand: brand));
  }

  @override
  Future<void> setLocale(Locale locale) async {
    state = state.whenData((s) => s.copyWith(locale: locale));
  }

  @override
  Future<void> setPb1Rate(double v) async {
    state = state.whenData((s) => s.copyWith(pb1Rate: v));
  }

  @override
  Future<void> setServiceChargeEnabled(bool v) async {
    state = state.whenData((s) => s.copyWith(serviceChargeEnabled: v));
  }

  @override
  Future<void> setServiceChargeRate(double v) async {
    state = state.whenData((s) => s.copyWith(serviceChargeRate: v));
  }

  @override
  Future<void> setCurrency(String v) async {
    state = state.whenData((s) => s.copyWith(currency: v));
  }

  @override
  Future<void> setStoreName(String v) async {
    state = state.whenData((s) => s.copyWith(storeName: v));
  }

  @override
  Future<void> setStoreAddress(String v) async {
    state = state.whenData((s) => s.copyWith(storeAddress: v));
  }

  @override
  Future<void> setCashierName(String v) async {
    state = state.whenData((s) => s.copyWith(cashierName: v));
  }

  @override
  Future<void> setLoggedIn(bool v) async {
    state = state.whenData((s) => s.copyWith(loggedIn: v));
  }

  /// Logging out no longer routes through [setLoggedIn]: it also has to clear
  /// the signed-in employee, or the next person's sales would be attributed to
  /// whoever used the till last. Overridden here so the spy does not fall
  /// through to the real implementation and hit SharedPreferences.
  @override
  Future<void> logout() async {
    state = state.whenData(
      (s) => s.copyWith(loggedIn: false, employeeId: ''),
    );
  }

  @override
  Future<void> resetDemoData() async {
    // Captured via callback rather than touching AppDatabase. The production
    // implementation calls `AppDatabase.instance.reset()`, which needs
    // sqflite_common_ffi wiring the settings screen otherwise has no DB
    // dependency — the spy keeps the test out of the DB layer entirely.
    onResetDemoData?.call();
  }
}

/// Fake whose `build` never completes so the provider stays in `AsyncLoading`.
/// Used to exercise the `settings.when(loading:)` branch.
class _HangingSettingsNotifier extends SettingsNotifier {
  _HangingSettingsNotifier();
  @override
  Future<SettingsState> build() => Completer<SettingsState>().future;
}

SettingsState _state({
  ThemeMode themeMode = ThemeMode.light,
  BrandPreset? brand,
  Locale locale = const Locale('en'),
  double pb1Rate = 10.0,
  bool serviceChargeEnabled = false,
  double serviceChargeRate = 0,
  String currency = 'IDR',
  String storeName = 'Test Store',
  String storeAddress = 'Jl. Contoh No. 1',
  String cashierName = 'Cashier Demo',
  bool loggedIn = true,
}) {
  return SettingsState(
    themeMode: themeMode,
    brand: brand ?? BrandPreset.presets.first,
    locale: locale,
    pb1Rate: pb1Rate,
    serviceChargeEnabled: serviceChargeEnabled,
    serviceChargeRate: serviceChargeRate,
    currency: currency,
    storeName: storeName,
    storeAddress: storeAddress,
    cashierName: cashierName,
    loggedIn: loggedIn,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  Future<void> pumpSettings(
    WidgetTester tester, {
    SettingsState? initial,
    VoidCallback? onResetDemoData,
    List<Override> extraOverrides = const [],
    bool settle = true,
    bool withRouter = false,
  }) async {
    final brand = (initial ?? _state()).brand;
    // The spy notifier is used unless the caller explicitly overrides
    // `settingsProvider` themselves (loading test, etc.).
    final hasSettingsOverride = extraOverrides.any(
      (o) => o.toString().contains('settingsProvider'),
    );
    final overrides = <Override>[
      if (!hasSettingsOverride)
        settingsProvider.overrideWith(
          () => _SpySettingsNotifier(
            initial ?? _state(),
            onResetDemoData: onResetDemoData,
          ),
        ),
      ...extraOverrides,
    ];
    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);

    // Phone-class surface. Settings is a single ListView so it scales; no
    // tablet split-view to exercise here.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const localizations = <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];

    // Most tests only need SettingsPage on its own. The product-management tap
    // navigates with `context.push('/products')`, which asserts unless a
    // GoRouter is in scope — so that one test opts into a two-route router
    // mirroring the real one (`/products` lives outside the shell).
    final Widget app = withRouter
        ? MaterialApp.router(
            theme: AppTheme.light(brand),
            locale: const Locale('en'),
            supportedLocales: kSupportedLocales,
            localizationsDelegates: localizations,
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (context, state) => const SettingsPage(),
                ),
                GoRoute(
                  path: '/products',
                  builder: (context, state) => const ProductManagementPage(),
                ),
              ],
            ),
          )
        : MaterialApp(
            theme: AppTheme.light(brand),
            locale: const Locale('en'),
            supportedLocales: kSupportedLocales,
            localizationsDelegates: localizations,
            home: const SettingsPage(),
          );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: app),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  group('appearance — theme chips', () {
    testWidgets(
        'tapping the dark-mode chip calls setThemeMode(ThemeMode.dark) '
        'and updates the selected chip indicator', (tester) async {
      await pumpSettings(tester);

      // Three theme chips mount with distinct leading icons; none of the
      // labels is asserted.
      expect(find.byIcon(Icons.light_mode_rounded), findsOneWidget);
      expect(find.byIcon(Icons.dark_mode_rounded), findsOneWidget);
      expect(find.byIcon(Icons.brightness_auto_rounded), findsOneWidget);

      // Initial state from the seed is ThemeMode.light.
      expect(
        container.read(settingsProvider).valueOrNull?.themeMode,
        ThemeMode.light,
      );

      await tester.tap(find.byIcon(Icons.dark_mode_rounded));
      await tester.pumpAndSettle();

      // State read-back is locale-agnostic and deterministic.
      expect(
        container.read(settingsProvider).valueOrNull?.themeMode,
        ThemeMode.dark,
      );
    });
  });

  group('appearance — brand swatches', () {
    testWidgets(
        'tapping the Crimson swatch calls setBrand(crimson) and moves the '
        'selected indicator', (tester) async {
      await pumpSettings(tester);

      // One GestureDetector-wrapped swatch per BrandPreset. Each swatch wraps
      // a Tooltip whose message is the preset's `name` (data, not localized).
      // The initial seed is `BrandPreset.presets.first` (flame) → exactly one
      // `Icons.check_rounded` is painted (on the flame swatch).
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);

      final crimson = find.byTooltip(BrandPreset.presets[1].name);
      expect(crimson, findsOneWidget);

      await tester.tap(crimson);
      await tester.pumpAndSettle();

      // State read-back confirms the brand id changed.
      expect(
        container.read(settingsProvider).valueOrNull?.brand.id,
        BrandPreset.presets[1].id,
      );
      // Still exactly one check icon — it just moved to the Crimson swatch.
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    });
  });

  group('language tiles', () {
    testWidgets(
        'tapping the ID tile calls setLocale(Locale(id)) and moves the '
        'selected indicator', (tester) async {
      await pumpSettings(tester);

      // Two _LangTile rows identified by their data code text ('EN', 'ID').
      expect(find.text('EN'), findsOneWidget);
      expect(find.text('ID'), findsOneWidget);

      // Initial: EN is selected → check_circle_rounded paints once (on EN).
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(
        container.read(settingsProvider).valueOrNull?.locale.languageCode,
        'en',
      );

      // Tap the ID tile. The tile's own InkWell sits inside the GlassCard
      // InkWell that wraps the whole language section, so `find.ancestor`
      // would match two InkWells; tapping the 'ID' Text directly lets the
      // gesture arena resolve to the nearest (innermost) InkWell instead.
      await tester.tap(find.text('ID'));
      await tester.pumpAndSettle();

      expect(
        container.read(settingsProvider).valueOrNull?.locale.languageCode,
        'id',
      );
      // Selected indicator still exactly one — now on ID.
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });
  });

  group('business edit dialogs', () {
    testWidgets(
        'tapping the store-name tile opens an AlertDialog; entering text '
        'and tapping save calls setStoreName', (tester) async {
      await pumpSettings(tester);

      // Tile matched by leading icon, not by localized title/value.
      await tester.tap(find.byIcon(Icons.storefront_outlined));
      await tester.pumpAndSettle();

      // Dialog mounts with a TextField and exactly two action buttons —
      // TextButton (cancel) + FilledButton (save). The buttons are matched
      // by type, never by translated label.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);

      // Initial store name is the seed ('Test Store').
      expect(
        container.read(settingsProvider).valueOrNull?.storeName,
        'Test Store',
      );

      await tester.enterText(find.byType(TextField), 'Warung Baru');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      // Dialog dismissed, setter fired.
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        container.read(settingsProvider).valueOrNull?.storeName,
        'Warung Baru',
      );
    });

    testWidgets(
        'cancel on the store-name dialog dismisses without mutating state',
        (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byIcon(Icons.storefront_outlined));
      await tester.pumpAndSettle();

      // Tapping cancel pops the dialog with no value → onSave never fires.
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(
        container.read(settingsProvider).valueOrNull?.storeName,
        'Test Store',
      );
    });

    testWidgets(
        'the PB1-rate dialog parses the entered number and calls setPb1Rate',
        (tester) async {
      await pumpSettings(tester);

      // The PB1 tile is matched by its percent icon — service charge is off
      // by default in this fixture, so its own percent tile is not rendered
      // and this icon is unambiguous.
      await tester.tap(find.byIcon(Icons.percent_outlined));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      // Initial seed is 10.0.
      expect(
        container.read(settingsProvider).valueOrNull?.pb1Rate,
        10.0,
      );

      // `enterText` replaces the field contents — `double.tryParse('8.5')`
      // succeeds in the production `_editNumber` onSave path.
      await tester.enterText(find.byType(TextField), '8.5');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(
        container.read(settingsProvider).valueOrNull?.pb1Rate,
        8.5,
      );
    });

    testWidgets(
        'the currency tile opens an edit dialog and setCurrency fires on save',
        (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.byIcon(Icons.payments_outlined));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'USD');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      expect(
        container.read(settingsProvider).valueOrNull?.currency,
        'USD',
      );
    });
  });

  group('reset demo data', () {
    testWidgets(
        'tapping the reset tile opens a confirm dialog; tapping confirm '
        'calls resetDemoData once', (tester) async {
      var resetCalls = 0;
      await pumpSettings(
        tester,
        onResetDemoData: () => resetCalls++,
      );

      // The reset tile is matched by its restart icon.
      await tester.tap(find.byIcon(Icons.restart_alt_rounded));
      await tester.pumpAndSettle();

      // Confirm dialog mounts with TextButton (cancel) + FilledButton
      // (confirm) — the FilledButton uses `colorScheme.error` background per
      // the production `_confirmReset` builder. Match by type, never label.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);

      expect(resetCalls, 0);

      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();

      // The production `_confirmReset` awaits resetDemoData() then calls
      // `ref.invalidate(settingsProvider)` — but our spy's resetDemoData
      // callback is the source of truth here (the invalidate rebuilds the
      // notifier but the outer `resetCalls` counter was already incremented
      // by the time the original notifier was disposed).
      expect(resetCalls, 1);
    });

    testWidgets(
        'cancelling the reset dialog does not call resetDemoData',
        (tester) async {
      var resetCalls = 0;
      await pumpSettings(
        tester,
        onResetDemoData: () => resetCalls++,
      );

      await tester.tap(find.byIcon(Icons.restart_alt_rounded));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(resetCalls, 0);
    });
  });

  group('logout', () {
    testWidgets(
        'the DangerButton at the bottom calls logout → setLoggedIn(false)',
        (tester) async {
      await pumpSettings(tester);

      // Exactly one DangerButton on the page (the logout action).
      expect(find.byType(DangerButton), findsOneWidget);
      expect(
        container.read(settingsProvider).valueOrNull?.loggedIn,
        true,
      );

      // Scrolled into view rather than tapped where it happens to sit: this
      // is the last row of a growing list, and every setting added above it
      // pushed it further off a phone-sized test viewport.
      await tester.scrollUntilVisible(find.byType(DangerButton), 300);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DangerButton));
      await tester.pumpAndSettle();

      expect(
        container.read(settingsProvider).valueOrNull?.loggedIn,
        false,
      );
    });
  });

  group('product management navigation', () {
    testWidgets(
        'tapping the product-management tile pushes ProductManagementPage',
        (tester) async {
      // Needs a router in scope: the tile navigates with `context.push`, not a
      // bare Navigator.push. Going through the router is the point — a raw
      // MaterialPageRoute left the browser URL untouched, so on web Back
      // skipped past Settings entirely.
      await pumpSettings(tester, withRouter: true);

      // The inventory tile is matched by its leading icon.
      expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
      expect(find.byType(ProductManagementPage), findsNothing);

      await tester.tap(find.byIcon(Icons.inventory_2_outlined));
      // We can't `pumpAndSettle` here: the pushed page's `_ProductsTab` /
      // `_CategoriesTab` paint `LoadingIndicator.skeleton` bars while the
      // catalog provider resolves, and the `_Shimmer` ticker loops forever
      // (no DB is wired in this test). The ProductManagementPage itself
      // mounts without touching any provider in its build, so a couple of
      // finite pumps are enough to land its first frame and assert its
      // presence — the route push is the behaviour under test, not the
      // destination's data state.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ProductManagementPage), findsOneWidget);
    });
  });

  group('loading', () {
    testWidgets(
        'AsyncLoading paints the CircularProgressIndicator and no settings '
        'tiles', (tester) async {
      await pumpSettings(
        tester,
        settle: false,
        extraOverrides: [
          settingsProvider.overrideWith(() => _HangingSettingsNotifier()),
        ],
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // None of the data widgets should be mounted while loading.
      expect(find.byIcon(Icons.storefront_outlined), findsNothing);
      expect(find.byIcon(Icons.restart_alt_rounded), findsNothing);
      expect(find.byType(DangerButton), findsNothing);
    });
  });
}
