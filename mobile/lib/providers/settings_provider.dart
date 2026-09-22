import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/permissions.dart';
import '../core/theme/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../data/database/app_database.dart';
import '../data/device/till_binding.dart';
import '../data/device/till_coordinator.dart';
import '../data/models/employee.dart';
import '../data/models/outlet.dart';
import '../data/preferences/app_preferences.dart';
import '../data/repositories/employee_repository.dart';
import '../data/repositories/outlet_repository.dart';
import '../data/repositories/pos_register_repository.dart';
import '../data/repositories/shift_repository.dart';

/// Async-loaded preferences singleton.
final preferencesProvider = FutureProvider<AppPreferences>((ref) {
  return AppPreferences.instance();
});

/// Reactive application settings (theme, brand, locale, business config).
/// Loaded async from SharedPreferences. Routes & UI can watch the [data]
/// state; the splash screen handles loading/error.
class SettingsState {
  const SettingsState({
    required this.themeMode,
    required this.brand,
    required this.locale,
    required this.pb1Rate,
    required this.serviceChargeEnabled,
    required this.serviceChargeRate,
    required this.currency,
    required this.storeName,
    required this.storeAddress,
    required this.cashierName,
    required this.loggedIn,
    // Defaulted rather than required: "nobody identified yet" is a real state
    // (a session created before per-employee sign-in, or a test that only
    // cares about theme), and forcing every construction site to spell it out
    // would say nothing extra.
    this.employeeId = '',
    this.employeeRole = EmployeeRole.owner,
    this.navRailExpanded,
    // Also defaulted, for the same reason and one more: ON is what an install
    // that predates the setting has always behaved like.
    this.tableServiceEnabled = true,
    this.outletId = '',
    this.posSessionId = '',
    this.posRegisterId = '',
    this.posRegisterName = '',
  });

  final ThemeMode themeMode;
  final BrandPreset brand;
  final Locale locale;
  final double pb1Rate;
  final bool serviceChargeEnabled;
  final double serviceChargeRate;
  final String currency;
  final String storeName;
  final String storeAddress;
  final String cashierName;

  /// Id of the signed-in employee, or empty for a session that predates
  /// per-employee sign-in. [cashierName] stays the display name either way, so
  /// receipts and order attribution never go blank on an upgraded install.
  final String employeeId;

  /// Role of the signed-in employee.
  ///
  /// Defaults to owner when unknown. That is the permissive default on
  /// purpose: the only way to reach it is a session created before roles
  /// existed, and silently demoting such a user would take away screens they
  /// were using yesterday. Signing out and back in resolves a real role.
  final EmployeeRole employeeRole;

  final bool loggedIn;

  /// Whether the till this session is standing at seats guests at tables.
  ///
  /// A capability, not a permission: it answers "does this business seat
  /// anyone here", where [AppPermission.manageTables] answers "may this person
  /// seat them". The Tables tab needs both to be true.
  ///
  /// DERIVED, not stored. The store-wide switch this used to read is gone —
  /// table service is now a per-register setting, so a restaurant can run a
  /// dine-in till and a takeaway counter side by side. What is resolved into
  /// this field, in order:
  ///
  ///   1. The register of the open POS session, when there is one. That is the
  ///      till the cashier is actually standing at, and the only answer that
  ///      can be right during a sale.
  ///   2. Otherwise, whether ANY active register at the active outlet runs
  ///      table service. This is the answer for a manager or owner, who never
  ///      hold a session and are asking about the branch rather than a till.
  ///   3. True when the branch has no registers at all — an unconfigured store
  ///      behaves exactly as it always has, rather than losing its floor plan
  ///      to a missing row.
  ///
  /// Keeping the field name is deliberate: every consumer (the Tables tab, the
  /// router gate, the table row in the cart, `placeOrderFromCart`) already
  /// reads one resolved flag, so only the SOURCE moved.
  final bool tableServiceEnabled;

  /// The POS session this device is signed on to, and the till it is for.
  ///
  /// Empty when nobody has opened one, which is what the router turns into
  /// "cannot reach the sell screen yet". [posRegisterId] is additionally empty
  /// for a session opened before registers existed — those stay sellable, and
  /// fall through to the outlet-level table-service answer above.
  final String posSessionId;
  final String posRegisterId;
  final String posRegisterName;

  /// Whether this device may sell: somebody has opened or resumed a session.
  bool get hasPosSession => posSessionId.isNotEmpty;

  /// Which outlet this DEVICE is standing in, or empty when nobody has
  /// chosen one.
  ///
  /// Device-local, unlike every other value here that describes the business:
  /// the tablet in Bintaro and the tablet in Kemang are in different shops.
  /// Empty resolves to the first open outlet rather than blocking the sale —
  /// see `activeOutletProvider`.
  final String outletId;

  /// Whether the side rail shows labels, or null when the user has never
  /// toggled it — the shell then defaults on window width. Null is meaningful
  /// here, so there is no [copyWith] path that clears it back.
  final bool? navRailExpanded;

  /// What this session is allowed to do. Screens ask [can]; nothing compares
  /// roles directly.
  Set<AppPermission> get permissions => permissionsFor(employeeRole);

  bool can(AppPermission permission) => permissions.contains(permission);

  /// Where this role belongs when a route is off-limits or after sign-in.
  String get homeRoute => homeRouteFor(employeeRole);

  ThemeData get lightTheme => AppTheme.light(brand);
  ThemeData get darkTheme => AppTheme.dark(brand);

  SettingsState copyWith({
    ThemeMode? themeMode,
    BrandPreset? brand,
    Locale? locale,
    double? pb1Rate,
    bool? serviceChargeEnabled,
    double? serviceChargeRate,
    String? currency,
    String? storeName,
    String? storeAddress,
    String? cashierName,
    String? employeeId,
    EmployeeRole? employeeRole,
    bool? loggedIn,
    bool? navRailExpanded,
    bool? tableServiceEnabled,
    String? outletId,
    String? posSessionId,
    String? posRegisterId,
    String? posRegisterName,
  }) => SettingsState(
    themeMode: themeMode ?? this.themeMode,
    brand: brand ?? this.brand,
    locale: locale ?? this.locale,
    pb1Rate: pb1Rate ?? this.pb1Rate,
    serviceChargeEnabled: serviceChargeEnabled ?? this.serviceChargeEnabled,
    serviceChargeRate: serviceChargeRate ?? this.serviceChargeRate,
    currency: currency ?? this.currency,
    storeName: storeName ?? this.storeName,
    storeAddress: storeAddress ?? this.storeAddress,
    cashierName: cashierName ?? this.cashierName,
    employeeId: employeeId ?? this.employeeId,
    employeeRole: employeeRole ?? this.employeeRole,
    loggedIn: loggedIn ?? this.loggedIn,
    navRailExpanded: navRailExpanded ?? this.navRailExpanded,
    tableServiceEnabled: tableServiceEnabled ?? this.tableServiceEnabled,
    outletId: outletId ?? this.outletId,
    posSessionId: posSessionId ?? this.posSessionId,
    posRegisterId: posRegisterId ?? this.posRegisterId,
    posRegisterName: posRegisterName ?? this.posRegisterName,
  );
}

/// The POS context this device resolves to: which session it is signed on to,
/// which till that is, and whether that till seats guests.
///
/// Bundled because the three are resolved together from one pair of queries
/// and are only ever meaningful together — a register name with no session is
/// a label for a till nobody is standing at.
typedef PosContext = ({
  String sessionId,
  String registerId,
  String registerName,
  bool tableService,
});

class SettingsNotifier extends AsyncNotifier<SettingsState> {
  late AppPreferences _prefs;

  @override
  Future<SettingsState> build() async {
    _prefs = await AppPreferences.instance();
    // Resolved once at bootstrap so the role is available before the first
    // frame; screens gate on it and must not flicker between permissions.
    final employeeId = _prefs.employeeId;
    final employee = employeeId.isEmpty
        ? null
        : await EmployeeRepository.instance.byId(employeeId);
    await _foldLegacyTableServiceIntoRegisters();
    // Resolved here too, and for the same reason: the router decides whether a
    // cashier may reach the sell screen from this, and a frame of "no session"
    // would bounce them off their own till on every cold start.
    final pos = await _resolvePosContext(employeeId: employeeId);
    return SettingsState(
      themeMode: _prefs.themeMode,
      brand: _prefs.brand,
      locale: _prefs.locale,
      pb1Rate: _prefs.pb1Rate,
      serviceChargeEnabled: _prefs.serviceChargeEnabled,
      serviceChargeRate: _prefs.serviceChargeRate,
      currency: _prefs.currency,
      storeName: _prefs.storeName,
      storeAddress: _prefs.storeAddress,
      cashierName: _prefs.cashierName,
      employeeId: _prefs.employeeId,
      employeeRole: employee?.role ?? EmployeeRole.owner,
      loggedIn: _prefs.isLoggedIn,
      navRailExpanded: _prefs.navRailExpanded,
      tableServiceEnabled: pos.tableService,
      // An activated device reports the outlet it is bound to, whatever a
      // saved preference says.
      outletId: TillBinding.current?.outletId ?? _prefs.outletId,
      posSessionId: pos.sessionId,
      posRegisterId: pos.registerId,
      posRegisterName: pos.registerName,
    );
  }

  /// Carries the retired store-wide table-service switch into the registers.
  ///
  /// The switch lived in SharedPreferences, which the DB migration that
  /// created `pos_registers` cannot read — so the two halves of this move meet
  /// here instead. Runs at most once per install: without the flag it would
  /// re-apply on every launch and keep stamping over a per-till setting
  /// somebody has since changed by hand.
  ///
  /// Only acts when the switch was explicitly OFF. Never having touched it,
  /// or having left it on, is already what the registers default to.
  Future<void> _foldLegacyTableServiceIntoRegisters() async {
    if (_prefs.tableServiceMigrated) return;
    if (_prefs.legacyTableServiceOff != true) {
      await _prefs.setTableServiceMigrated(true);
      return;
    }
    final outlets = await OutletRepository.instance.all();
    for (final outlet in outlets) {
      for (final r in await PosRegisterRepository.instance.byOutlet(
        outlet.id,
      )) {
        await PosRegisterRepository.instance.upsert(
          r.copyWith(tableService: false),
        );
      }
    }
    await _prefs.setTableServiceMigrated(true);
  }

  /// Works out which till this device is signed on to, and what that implies.
  ///
  /// Resolution order, each fallback deliberate:
  ///
  ///   1. The device's own saved session, if it is still open. A session that
  ///      somebody has since closed must stop counting, or a device would keep
  ///      selling into a drawer that has already been reconciled.
  ///   2. Otherwise this employee's own open session, adopted. This is what
  ///      makes "resume" work — signing back in puts you at the till you were
  ///      already standing at instead of asking again, and it is also what
  ///      picks up a session that was open across the upgrade to registers.
  ///      Only ever THEIR OWN: a session someone else holds is never inherited
  ///      here, which is what keeps the lock real.
  ///   3. Otherwise none, and the router sends a cashier to the picker.
  ///
  /// The table-service answer falls out of the same walk — see
  /// [SettingsState.tableServiceEnabled] for why it ends up here.
  Future<PosContext> _resolvePosContext({
    required String employeeId,
    String? sessionIdOverride,
  }) async {
    final shifts = ShiftRepository.instance;
    final saved = sessionIdOverride ?? _prefs.posSessionId;

    // Nobody signed in and no session: there is nothing to resolve and nobody
    // to resolve it for. Returning early keeps `build()` off the database on
    // the sign-in path, which is where it was before registers existed — a
    // bootstrap that queries when it has no question to answer is a bootstrap
    // that can fail for a reason the user cannot act on.
    if (saved.isEmpty && employeeId.isEmpty) {
      return (
        sessionId: '',
        registerId: '',
        registerName: '',
        tableService: true,
      );
    }

    // On an activated device, only a session on the bound register counts —
    // saved or adopted. A session on any other till is one the server would
    // file under this till's register, so it is never resumed here.
    final boundRegister = TillBinding.current?.registerId;

    var session = saved.isEmpty ? null : await shifts.byId(saved);
    if (session != null && !session.isOpen) session = null;
    if (session != null &&
        boundRegister != null &&
        session.posId != boundRegister) {
      session = null;
    }

    if (session == null && employeeId.isNotEmpty) {
      session = await shifts.openShiftFor(employeeId, posId: boundRegister);
    }

    if (session == null) {
      if (saved.isNotEmpty) await _prefs.setPosSessionId('');
      return (
        sessionId: '',
        registerId: '',
        registerName: '',
        tableService: await _outletRunsTableService(),
      );
    }

    // An open row in `shifts` is not permission to sell into it. On a
    // coordinated till the server decides, and `holdsPermit` is the single
    // definition the picker asks too — see its doc comment for why having two
    // copies of this query made Resume a dead button.
    final db = await AppDatabase.instance.db;
    if (!await TillCoordinator.holdsPermit(db, session.id, employeeId)) {
      return (
        sessionId: '',
        registerId: '',
        registerName: '',
        tableService: await _outletRunsTableService(),
      );
    }

    if (session.id != saved) await _prefs.setPosSessionId(session.id);

    // A session opened before registers existed names no till. It stays
    // sellable — refusing would strand a cashier mid-shift over a column that
    // did not exist when they opened it — and falls through to the branch's
    // answer for tables.
    final register = session.posId == null
        ? null
        : await PosRegisterRepository.instance.byId(session.posId!);

    return (
      sessionId: session.id,
      registerId: register?.id ?? '',
      registerName: register?.name ?? session.posName ?? '',
      tableService: register?.tableService ?? await _outletRunsTableService(),
    );
  }

  /// Whether the branch this device stands in seats guests at any of its
  /// tills. The answer for someone who is not on a till themselves.
  Future<bool> _outletRunsTableService() async {
    final outlet = await _resolveOutlet();
    if (outlet == null) return true;
    final registers = await PosRegisterRepository.instance.byOutlet(
      outlet.id,
      onlyActive: true,
    );
    // No tills configured is not the same as no tables: an unconfigured store
    // keeps the floor plan it has always had.
    if (registers.isEmpty) return true;
    return registers.any((r) => r.tableService);
  }

  /// The branch this device is in, by the same rule `activeOutletProvider`
  /// uses. Duplicated as a private walk rather than read from that provider
  /// because this notifier is a root `AsyncNotifier` that the outlet provider
  /// itself watches — reading it back here would be a cycle.
  Future<Outlet?> _resolveOutlet() async {
    final repo = OutletRepository.instance;
    final binding = TillBinding.current;
    if (binding != null) return repo.byId(binding.outletId);
    final chosen = _prefs.outletId;
    if (chosen.isNotEmpty) {
      final outlet = await repo.byId(chosen);
      if (outlet != null && outlet.active) return outlet;
    }
    return repo.firstActive();
  }

  /// Re-resolves the POS context and folds it into the current state.
  ///
  /// Called after anything that can change the answer: moving the device to
  /// another branch, editing a register, opening or closing a session. There
  /// is no global invalidation layer here — the caller invalidates what it
  /// changed, and this is that call for the POS context.
  Future<void> refreshPosContext({String? sessionIdOverride}) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final pos = await _resolvePosContext(
      employeeId: current.employeeId,
      sessionIdOverride: sessionIdOverride,
    );
    state = AsyncValue.data(
      current.copyWith(
        posSessionId: pos.sessionId,
        posRegisterId: pos.registerId,
        posRegisterName: pos.registerName,
        tableServiceEnabled: pos.tableService,
      ),
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.whenData((s) => s.copyWith(themeMode: mode));
    await _prefs.setThemeMode(mode);
  }

  Future<void> setBrand(BrandPreset brand) async {
    state = state.whenData((s) => s.copyWith(brand: brand));
    await _prefs.setBrandId(brand.id);
  }

  Future<void> setLocale(Locale locale) async {
    state = state.whenData((s) => s.copyWith(locale: locale));
    await _prefs.setLocale(locale);
  }

  Future<void> setPb1Rate(double v) async {
    state = state.whenData((s) => s.copyWith(pb1Rate: v));
    await _prefs.setPb1Rate(v);
  }

  Future<void> setServiceChargeEnabled(bool v) async {
    state = state.whenData((s) => s.copyWith(serviceChargeEnabled: v));
    await _prefs.setServiceChargeEnabled(v);
  }

  Future<void> setServiceChargeRate(double v) async {
    state = state.whenData((s) => s.copyWith(serviceChargeRate: v));
    await _prefs.setServiceChargeRate(v);
  }

  Future<void> setCurrency(String v) async {
    state = state.whenData((s) => s.copyWith(currency: v));
    await _prefs.setCurrency(v);
  }

  Future<void> setStoreName(String v) async {
    state = state.whenData((s) => s.copyWith(storeName: v));
    await _prefs.setStoreName(v);
  }

  Future<void> setStoreAddress(String v) async {
    state = state.whenData((s) => s.copyWith(storeAddress: v));
    await _prefs.setStoreAddress(v);
  }

  Future<void> setCashierName(String v) async {
    state = state.whenData((s) => s.copyWith(cashierName: v));
    await _prefs.setCashierName(v);
  }

  /// Puts this device in an outlet.
  ///
  /// Stored per device, never shared: two tablets on the same business
  /// settings can be in different shops, and that is the entire point.
  ///
  /// Re-resolves the POS context afterwards, because the branch decides which
  /// tills exist — and therefore, for anyone not holding a session, whether
  /// this shop seats guests at tables at all.
  ///
  /// An activated device cannot be moved: it stands where its token is bound,
  /// and a different outlet here would move stock and takings the server
  /// files elsewhere. The call is ignored rather than trusted to hidden
  /// buttons.
  Future<void> setOutletId(String v) async {
    final binding = TillBinding.current;
    if (binding != null && v != binding.outletId) return;
    state = state.whenData((s) => s.copyWith(outletId: v));
    await _prefs.setOutletId(v);
    await refreshPosContext();
  }

  /// Signs this device on to a till.
  ///
  /// The session row is written by [ShiftRepository.open], which is where the
  /// "one open session per till" rule is enforced; this only remembers the
  /// result and re-resolves everything that hangs off it — most visibly
  /// whether the Tables tab exists, since that is now the till's setting.
  Future<void> openPosSession(String sessionId) async {
    await _prefs.setPosSessionId(sessionId);
    await refreshPosContext(sessionIdOverride: sessionId);
  }

  /// Signs this device off its till, releasing it for the next cashier.
  ///
  /// The session row is closed by [ShiftRepository.close] first — this is only
  /// the device forgetting it. Call it in that order: the resolver falls back
  /// to "this employee's own OPEN session", so clearing the pref before the
  /// row is actually closed would simply re-adopt the same session.
  Future<void> closePosSession() async {
    await _prefs.setPosSessionId('');
    await refreshPosContext(sessionIdOverride: '');
  }

  Future<void> setNavRailExpanded(bool v) async {
    state = state.whenData((s) => s.copyWith(navRailExpanded: v));
    await _prefs.setNavRailExpanded(v);
  }

  Future<void> setLoggedIn(bool v) async {
    state = state.whenData((s) => s.copyWith(loggedIn: v));
    await _prefs.setLoggedIn(v);
  }

  /// Signs [employee] in and remembers who they are.
  ///
  /// The display name is mirrored into `cashierName` so everything that
  /// already reads it — the dashboard greeting, receipts, order attribution —
  /// follows the signed-in person without each call site learning about
  /// employees.
  ///
  /// [keepPosSession] is what tells a handover apart from a sign-in, and the
  /// two want opposite things. The on-duty chip hands the till over mid-order
  /// at the same physical counter: the session stays, because the cash box
  /// does, and only the name on the next order changes. A sign-in from the
  /// login screen re-resolves instead, so the new person lands on their own
  /// session or on the picker — never silently inside somebody else's drawer.
  Future<void> signIn(Employee employee, {bool keepPosSession = false}) async {
    final coordinator = TillCoordinator.current;
    if (coordinator != null) {
      final session = state.valueOrNull?.posSessionId ?? '';
      if (keepPosSession && session.isNotEmpty) {
        await coordinator.handover(employee.id, session);
      } else {
        try { await coordinator.recover(employee.id); }
        on TillOperationException { /* Cached confirmed sessions remain available offline. */ }
      }
    }
    state = state.whenData(
      (s) => s.copyWith(
        loggedIn: true,
        employeeId: employee.id,
        employeeRole: employee.role,
        cashierName: employee.name,
      ),
    );
    await _prefs.setEmployeeId(employee.id);
    await _prefs.setCashierName(employee.name);
    await _prefs.setLoggedIn(true);
    if (!keepPosSession) await refreshPosContext();
  }

  /// Signs out and forgets who it was.
  ///
  /// Clearing the id matters: leaving it behind would attribute the next
  /// person's sales to whoever used the till last.
  ///
  /// The POS session is forgotten too, WITHOUT being closed. The drawer is
  /// still open and still owed a count — that is the cashier's to make — but
  /// this device is no longer signed on to it, so the next person to sign in
  /// meets the picker and finds that till shown as taken rather than inheriting
  /// it. Whoever opened it adopts it again the moment they sign back in.
  Future<void> logout() async {
    state = state.whenData(
      (s) => s.copyWith(
        loggedIn: false,
        employeeId: '',
        posSessionId: '',
        posRegisterId: '',
        posRegisterName: '',
      ),
    );
    await _prefs.setEmployeeId('');
    await _prefs.setPosSessionId('');
    await _prefs.setLoggedIn(false);
  }

  Future<void> resetDemoData() async {
    await AppDatabase.instance.reset();
  }
}

// ignore: dangling_library_references
final settingsProvider = AsyncNotifierProvider<SettingsNotifier, SettingsState>(
  SettingsNotifier.new,
);
