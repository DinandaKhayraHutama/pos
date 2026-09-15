import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nti_pos/core/theme/app_colors.dart';
import 'package:nti_pos/data/preferences/app_preferences.dart';
import 'package:nti_pos/providers/settings_provider.dart';

import '../helpers/provider_helpers.dart';

/// Pref key constants mirror the private constants in [AppPreferences].
/// They are duplicated here so a rename in production code surfaces as a
/// failing test, not a silent mismatch.
const _kThemeMode = 'theme_mode';
const _kBrandId = 'brand_id';
const _kLocale = 'locale_code';
const _kPb1Rate = 'tax_rate'; // key unchanged — was the flat tax rate
const _kServiceChargeEnabled = 'service_charge_enabled';
const _kServiceChargeRate = 'service_charge_rate';
const _kCurrency = 'currency';
const _kStoreName = 'store_name';
const _kStoreAddress = 'store_address';
const _kCashierName = 'cashier_name';
const _kLoggedIn = 'logged_in';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainerWithPrefs(Map<String, Object> prefs) {
    // Reset the cached singleton BEFORE seeding mock values so the next
    // `AppPreferences.instance()` re-reads from the mocked store.
    AppPreferences.resetForTest();
    SharedPreferences.setMockInitialValues(prefs);
    return makeContainer();
  }

  group('settingsProvider build — reads seeded prefs', () {
    late ProviderContainer container;

    setUp(() {
      container = makeContainerWithPrefs({
        _kThemeMode: 'dark',
        _kBrandId: 'ocean',
        _kLocale: 'id',
        _kPb1Rate: 11.0,
        _kServiceChargeEnabled: true,
        _kServiceChargeRate: 7.5,
        _kCurrency: 'Rp',
        _kStoreName: 'Warung Segar',
        _kStoreAddress: 'Jl. Mawar No. 9',
        _kCashierName: 'Budi',
        _kLoggedIn: true,
      });
    });

    tearDown(() => container.dispose());

    test('resolves to a SettingsState matching the seeded values', () async {
      final state = await container.read(settingsProvider.future);

      expect(state.themeMode, ThemeMode.dark);
      expect(state.brand.id, 'ocean');
      expect(state.locale, const Locale('id'));
      expect(state.pb1Rate, 11.0);
      expect(state.serviceChargeEnabled, isTrue);
      expect(state.serviceChargeRate, 7.5);
      expect(state.currency, 'Rp');
      expect(state.storeName, 'Warung Segar');
      expect(state.storeAddress, 'Jl. Mawar No. 9');
      expect(state.cashierName, 'Budi');
      expect(state.loggedIn, isTrue);
    });

    test('defaults when prefs empty match the AppPreferences fallbacks',
        () async {
      // Fresh container with no seeded values.
      final empty = makeContainerWithPrefs({});
      addTearDown(empty.dispose);

      final state = await empty.read(settingsProvider.future);

      expect(state.themeMode, ThemeMode.system);
      // NTI's own deep blue, and also `BrandPreset.presets.first` — the two
      // are kept in step deliberately, so `byId`'s fallback and the stated
      // default cannot drift apart.
      expect(state.brand.id, 'nti');
      expect(state.brand.id, BrandPreset.presets.first.id);
      expect(state.locale, const Locale('en'));
      // Never configured (the key is absent) — defaults to 10%, not 0%. Most
      // Indonesian F&B businesses owe 10% PB1, so a fresh install's receipt
      // is right on day one without a trip to Settings.
      expect(state.pb1Rate, 10.0);
      expect(state.serviceChargeEnabled, isFalse);
      expect(state.serviceChargeRate, 5.0);
      expect(state.currency, 'Rp');
      expect(state.storeName, 'Restoran NTI');
      expect(state.storeAddress, 'Jl. Contoh No. 1, Jakarta');
      expect(state.cashierName, 'Kasir Demo');
      expect(state.loggedIn, isFalse);
    });

    test(
      'a PB1 rate explicitly set to 0.0 stays 0.0 — never bumped to the '
      '10% "unconfigured" default',
      () async {
        // The key IS present here (unlike the empty-prefs case above), so
        // this is the "deliberately zero-rated store" case, not "never
        // configured". AppPreferences.pb1Rate distinguishes the two via
        // `containsKey`, not just `getDouble(...) ?? 10.0`.
        final zeroRated = makeContainerWithPrefs({_kPb1Rate: 0.0});
        addTearDown(zeroRated.dispose);

        final state = await zeroRated.read(settingsProvider.future);
        expect(state.pb1Rate, 0.0);
      },
    );
  });

  group('settingsProvider setters — state + prefs update together', () {
    late ProviderContainer container;

    setUp(() {
      container = makeContainerWithPrefs({});
    });

    tearDown(() => container.dispose());

    Future<SettingsState> get() =>
        container.read(settingsProvider.future);

    test('setThemeMode updates state and persists', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setThemeMode(ThemeMode.light);

      final state = await get();
      expect(state.themeMode, ThemeMode.light);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kThemeMode), 'light');
    });

    test('setBrand updates state and persists brand id', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      final newBrand = BrandPreset.byId('royal');
      await notifier.setBrand(newBrand);

      final state = await get();
      expect(state.brand.id, 'royal');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kBrandId), 'royal');
    });

    test('setLocale updates state and persists language code', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setLocale(const Locale('id'));

      final state = await get();
      expect(state.locale, const Locale('id'));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kLocale), 'id');
    });

    test('setPb1Rate updates state and persists', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setPb1Rate(12.5);

      final state = await get();
      expect(state.pb1Rate, 12.5);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_kPb1Rate), 12.5);
    });

    test('setServiceChargeEnabled updates state and persists', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setServiceChargeEnabled(true);

      final state = await get();
      expect(state.serviceChargeEnabled, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_kServiceChargeEnabled), isTrue);
    });

    test('setServiceChargeRate updates state and persists', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setServiceChargeRate(6.0);

      final state = await get();
      expect(state.serviceChargeRate, 6.0);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_kServiceChargeRate), 6.0);
    });

    test('setCurrency updates state and persists', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setCurrency('USD');

      final state = await get();
      expect(state.currency, 'USD');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kCurrency), 'USD');
    });

    test('setStoreName updates state and persists', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setStoreName('Cafe Bahagia');

      final state = await get();
      expect(state.storeName, 'Cafe Bahagia');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kStoreName), 'Cafe Bahagia');
    });

    test('setStoreAddress updates state and persists', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setStoreAddress('Jl. Melati');

      final state = await get();
      expect(state.storeAddress, 'Jl. Melati');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kStoreAddress), 'Jl. Melati');
    });

    test('setCashierName updates state and persists', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setCashierName('Siti');

      final state = await get();
      expect(state.cashierName, 'Siti');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_kCashierName), 'Siti');
    });

    test('setLoggedIn(true) updates state and persists', () async {
      await container.read(settingsProvider.future);
      final notifier = container.read(settingsProvider.notifier);
      await notifier.setLoggedIn(true);

      final state = await get();
      expect(state.loggedIn, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_kLoggedIn), isTrue);
    });

    test('logout flips loggedIn to false', () async {
      // Seed logged-in, then logout.
      final loggedInContainer = makeContainerWithPrefs({
        _kLoggedIn: true,
        _kCashierName: 'BeforeLogout',
      });
      addTearDown(loggedInContainer.dispose);

      await loggedInContainer.read(settingsProvider.future);
      final notifier = loggedInContainer.read(settingsProvider.notifier);
      await notifier.logout();

      final state = await loggedInContainer.read(settingsProvider.future);
      expect(state.loggedIn, isFalse);

      // Other fields are untouched.
      expect(state.cashierName, 'BeforeLogout');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(_kLoggedIn), isFalse);
    });
  });
}
