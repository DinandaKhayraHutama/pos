import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_colors.dart';

/// Persisted application preferences. Stored in SharedPreferences so the
/// backend team can later mirror these to a REST endpoint if needed.
class AppPreferences {
  AppPreferences._(this._prefs);
  static AppPreferences? _instance;

  final SharedPreferences _prefs;

  static Future<AppPreferences> instance() async {
    if (_instance != null) return _instance!;
    final prefs = await SharedPreferences.getInstance();
    return _instance = AppPreferences._(prefs);
  }

  /// Test-only: clears the cached singleton so the next [instance] call
  /// re-reads from `SharedPreferences` (whose values a test has mocked).
  ///
  /// Production code never needs this — there is exactly one preferences
  /// instance per process lifetime. Behaviour-identical for production:
  /// calling this in production would simply force a one-time re-read on
  /// the next [instance] call, with the same backing store.
  @visibleForTesting
  static void resetForTest() => _instance = null;

  // Theme mode --------------------------------------------------------------
  static const _kThemeMode = 'theme_mode';

  ThemeMode get themeMode {
    final v = _prefs.getString(_kThemeMode) ?? 'system';
    return switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setThemeMode(ThemeMode mode) =>
      _prefs.setString(_kThemeMode, mode.name);

  // Brand color -------------------------------------------------------------
  static const _kBrandId = 'brand_id';

  /// Defaults to NTI's own deep blue. Only affects a fresh install — anyone
  /// who has picked a brand keeps it, since the stored id wins.
  BrandPreset get brand =>
      BrandPreset.byId(_prefs.getString(_kBrandId) ?? 'nti');

  Future<void> setBrandId(String id) => _prefs.setString(_kBrandId, id);

  // Locale ------------------------------------------------------------------
  static const _kLocale = 'locale_code';

  Locale get locale {
    final code = _prefs.getString(_kLocale);
    if (code == null) return const Locale('en');
    return Locale(code);
  }

  Future<void> setLocale(Locale locale) =>
      _prefs.setString(_kLocale, locale.languageCode);

  // Business settings -------------------------------------------------------
  static const _kPb1Rate = 'tax_rate'; // key unchanged — was the flat tax rate
  static const _kCurrency = 'currency';
  static const _kStoreName = 'store_name';
  static const _kStoreAddress = 'store_address';
  static const _kServiceChargeEnabled = 'service_charge_enabled';
  static const _kServiceChargeRate = 'service_charge_rate';

  /// PB1 (Pajak Restoran). Defaults to 10% for an install that has NEVER
  /// touched this setting (the key is absent) — most Indonesian F&B
  /// businesses owe 10%, so a never-configured receipt is right the first
  /// time nobody visits Settings. An install that already set this —
  /// including a deliberate 0 — keeps exactly that value: `containsKey` is
  /// what makes "never configured" distinguishable from "explicitly set to
  /// 0.0", which a plain `?? 10.0` fallback could not do.
  double get pb1Rate {
    if (!_prefs.containsKey(_kPb1Rate)) return 10.0;
    return _prefs.getDouble(_kPb1Rate) ?? 10.0;
  }

  Future<void> setPb1Rate(double v) => _prefs.setDouble(_kPb1Rate, v);

  /// Off for both a fresh install and an upgrading one. An opt-in charge
  /// must never silently start appearing on a bill nobody configured.
  bool get serviceChargeEnabled =>
      _prefs.getBool(_kServiceChargeEnabled) ?? false;
  Future<void> setServiceChargeEnabled(bool v) =>
      _prefs.setBool(_kServiceChargeEnabled, v);

  /// Defaults to 5% while unconfigured, not 0% — a 0% pre-fill would make
  /// "enabled" and "disabled" behave identically the moment an owner flips
  /// the toggle on, until they also remember to type a rate.
  double get serviceChargeRate =>
      _prefs.getDouble(_kServiceChargeRate) ?? 5.0;
  Future<void> setServiceChargeRate(double v) =>
      _prefs.setDouble(_kServiceChargeRate, v);

  String get currency => _prefs.getString(_kCurrency) ?? 'Rp';
  Future<void> setCurrency(String v) => _prefs.setString(_kCurrency, v);

  String get storeName => _prefs.getString(_kStoreName) ?? 'Restoran NTI';
  Future<void> setStoreName(String v) => _prefs.setString(_kStoreName, v);

  String get storeAddress =>
      _prefs.getString(_kStoreAddress) ?? 'Jl. Contoh No. 1, Jakarta';
  Future<void> setStoreAddress(String v) => _prefs.setString(_kStoreAddress, v);

  static const _kTableService = 'table_service_enabled';
  static const _kTableServiceMigrated = 'table_service_migrated_to_registers';

  /// Whether table service was switched OFF store-wide before it became a
  /// per-register setting.
  ///
  /// Not a setting any more — nothing writes it, and the value the app acts on
  /// now comes from `pos_registers.table_service`. It survives only as
  /// migration input: the switch lived in SharedPreferences, which a DB
  /// migration cannot reach, so the one-shot reconciliation in
  /// `SettingsNotifier` reads it here and applies it to the registers instead.
  ///
  /// Null when it was never set, which is different from `false` — a store
  /// that never touched the switch has nothing to carry over.
  bool? get legacyTableServiceOff {
    final v = _prefs.getBool(_kTableService);
    return v == null ? null : !v;
  }

  /// Whether the store-wide switch has already been folded into the registers.
  ///
  /// Guards a one-shot: without it, the reconciliation would run on every
  /// launch and keep overwriting a per-till setting somebody has since
  /// changed by hand.
  bool get tableServiceMigrated =>
      _prefs.getBool(_kTableServiceMigrated) ?? false;
  Future<void> setTableServiceMigrated(bool v) =>
      _prefs.setBool(_kTableServiceMigrated, v);

  static const _kPosSessionId = 'pos_session_id';

  /// Which POS session THIS device is signed on to.
  ///
  /// Device-local for the same reason as [outletId], and one more: the session
  /// belongs to the till, not to the person. A cashier handing over mid-order
  /// keeps this device on the same drawer, and a restart resumes it rather
  /// than asking which till this is all over again.
  ///
  /// Cleared on sign-out. That is what makes the lock real: the next person to
  /// sign in on this device goes through the picker, where a till somebody
  /// else is holding is shown as taken instead of silently inherited.
  ///
  /// Empty means "not signed on to a till", which the router treats as
  /// "cannot sell yet".
  String get posSessionId => _prefs.getString(_kPosSessionId) ?? '';
  Future<void> setPosSessionId(String v) =>
      _prefs.setString(_kPosSessionId, v);

  static const _kOutletId = 'outlet_id';

  /// Which outlet THIS device is standing in.
  ///
  /// Device-local on purpose, and the one preference here that must never
  /// become a business-wide setting: the tablet in Bintaro and the tablet in
  /// Kemang are in different shops and have to answer differently. A shared
  /// value would file every sale under one branch and show each shop the
  /// other's stock.
  ///
  /// Empty means "never chosen", which the app resolves to the first open
  /// outlet rather than refusing to sell.
  String get outletId => _prefs.getString(_kOutletId) ?? '';
  Future<void> setOutletId(String v) => _prefs.setString(_kOutletId, v);

  // Layout ------------------------------------------------------------------
  static const _kNavRailExpanded = 'nav_rail_expanded';

  /// Whether the tablet/desktop side rail shows labels.
  ///
  /// Deliberately nullable: null means "never chosen", which lets the shell
  /// pick a sensible default from the window width instead of forcing one.
  /// A stored `false` on a wide screen is a real choice and must be kept.
  bool? get navRailExpanded => _prefs.getBool(_kNavRailExpanded);
  Future<void> setNavRailExpanded(bool v) =>
      _prefs.setBool(_kNavRailExpanded, v);

  // Auth --------------------------------------------------------------------
  static const _kCashierName = 'cashier_name';
  static const _kLoggedIn = 'logged_in';

  String get cashierName => _prefs.getString(_kCashierName) ?? 'Kasir Demo';
  Future<void> setCashierName(String v) => _prefs.setString(_kCashierName, v);

  bool get isLoggedIn => _prefs.getBool(_kLoggedIn) ?? false;
  Future<void> setLoggedIn(bool v) => _prefs.setBool(_kLoggedIn, v);

  static const _kEmployeeId = 'employee_id';

  /// Who is signed in. Empty when nobody is, or when the session predates
  /// per-employee sign-in — callers fall back to [cashierName] in that case so
  /// an upgraded install is never left with a blank cashier on its receipts.
  String get employeeId => _prefs.getString(_kEmployeeId) ?? '';
  Future<void> setEmployeeId(String v) => _prefs.setString(_kEmployeeId, v);
}
