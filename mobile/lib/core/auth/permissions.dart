/// What each role is allowed to do.
///
/// One table, read by everything. Screens ask `settings.can(AppPermission.x)`
/// and never compare roles directly — a role check scattered through the UI is
/// how a fourth role turns into a week of grep, and how a screen quietly keeps
/// working for someone who should have lost it.
library;

import '../../data/models/employee.dart';

/// A single capability. Deliberately phrased as an action ("void an order"),
/// not as a screen ("the orders screen"): two roles can share a screen and
/// still differ on what the buttons do, which is exactly what happens on the
/// order detail page.
enum AppPermission {
  /// Ring up a sale on the POS screen.
  sell,

  /// Seat and clear tables.
  manageTables,

  /// Open a till session with a float and close it against a count.
  openCloseShift,

  /// See the orders this person rang up, for the current day.
  viewOwnOrders,

  /// See every order from every cashier, with no date limit.
  viewAllOrders,

  /// Cancel an order that has already been rung up, returning its stock.
  voidOrder,

  /// Give money back on a completed order.
  refundOrder,

  /// Type a discount into the cart by hand, outside any configured promo.
  applyManualDiscount,

  /// Read the expected drawer contents without ending the shift.
  viewCashDrawer,

  /// Book stock in or out with a reason (delivery, waste, recount).
  adjustStock,

  /// Create and edit products, prices, categories and variants.
  manageCatalogue,

  /// Create, edit and deactivate staff accounts and their PINs.
  manageEmployees,

  /// Create and retire promotions.
  managePromos,

  /// The day's takings: dashboard tiles, top products, recent activity.
  viewDailySummary,

  /// The money view: date-ranged sales report, profit and loss, CSV export.
  viewFinancialReports,

  /// Store identity, tax, currency and demo-data reset.
  manageSettings,

  /// Open, rename and close the branches the business trades from, and see
  /// the chain rather than one shop.
  ///
  /// A manager's, not only the owner's: whoever runs more than one shop needs
  /// to compare them, and that is the job this permission describes.
  manageOutlets,

  /// Create, edit, deactivate, import, export and merge customers.
  manageCustomers,

  /// Ring up a line that has no catalogue product behind it.
  enterCustomAmount,
}

/// Running the till: taking money, and being accountable for a drawer.
///
/// Held ONLY by cashiers. A manager or owner covering the counter signs in on
/// a cashier account, which is also the honest outcome for attribution — the
/// sale belongs to whoever was actually at the till, and the drawer belongs to
/// whoever counted it.
const _till = <AppPermission>{AppPermission.sell, AppPermission.openCloseShift};

/// A cashier's world: the till, the floor, and their own day's sales.
const _cashier = <AppPermission>{
  ..._till,
  AppPermission.manageTables,
  AppPermission.viewOwnOrders,
};

/// A manager runs the floor and the money — and deliberately NOT the till.
///
/// Spelled out rather than spread from [_cashier], because it is no longer a
/// superset of one: a manager's job is the numbers and the exceptions, not
/// ringing up sales, so `sell` and `openCloseShift` are absent by design. The
/// screens they do not need are screens they cannot mis-tap during service.
///
/// Still NOT the catalogue or the financial reports — those are the owner's,
/// and keeping them out is the whole reason this role exists.
///
/// [AppPermission.manageTables] stays: a manager watching service needs the
/// board, and clearing a table someone walked away from is floor work rather
/// than till work.
const _manager = <AppPermission>{
  AppPermission.manageTables,
  AppPermission.viewAllOrders,
  AppPermission.voidOrder,
  AppPermission.refundOrder,
  AppPermission.applyManualDiscount,
  AppPermission.viewCashDrawer,
  AppPermission.adjustStock,
  AppPermission.viewDailySummary,
  AppPermission.manageOutlets,
  AppPermission.manageCustomers,
};

/// The owner has everything except the till.
///
/// Derived from the full enum rather than hand-kept, so a newly added
/// permission reaches the owner automatically — the alternative is a new
/// feature that its own owner cannot open. [_till] is subtracted for the same
/// reason it is absent from [_manager]: an owner's focus is the data and the
/// money, and a sale rung up under the owner's name is attribution nobody
/// wanted.
final _owner = AppPermission.values.toSet().difference(_till);

/// Effective access resolved from a system role or a synced custom role.
class EmployeeAccess {
  const EmployeeAccess({required this.permissions, required this.posAccess});

  final Set<AppPermission> permissions;
  final bool posAccess;

  bool can(AppPermission permission) => permissions.contains(permission);

  static EmployeeAccess system(EmployeeRole role) => EmployeeAccess(
    permissions: permissionsFor(role),
    posAccess: role != EmployeeRole.custom,
  );

  static EmployeeAccess custom(
    Iterable<String> names, {
    required bool posAccess,
  }) {
    final known = <AppPermission>{};
    for (final name in names) {
      for (final permission in AppPermission.values) {
        if (permission.name == name) known.add(permission);
      }
    }
    return EmployeeAccess(permissions: known, posAccess: posAccess);
  }

  static const locked = EmployeeAccess(
    permissions: <AppPermission>{},
    posAccess: false,
  );
}

/// The permissions [role] carries.
Set<AppPermission> permissionsFor(EmployeeRole role) => switch (role) {
  EmployeeRole.cashier => _cashier,
  EmployeeRole.manager => _manager,
  EmployeeRole.owner => _owner,
  EmployeeRole.custom => const <AppPermission>{},
};

/// True when [role] can authorize an action a cashier is blocked from.
///
/// Used by the override prompt: a cashier hands the till to someone senior,
/// who types their own PIN to approve one action without signing anyone out.
bool canAuthorizeOverrides(EmployeeRole role) =>
    role == EmployeeRole.manager || role == EmployeeRole.owner;

/// Where someone lands after signing in.
///
/// A cashier opens on the till because that is the job. Everyone else opens on
/// the numbers — and now must, since neither an owner nor a manager can reach
/// the sell screen at all. Also the safety net when a deep link points at a
/// screen the signed-in role cannot open, so it must never return a route the
/// role would itself be bounced out of.
String homeRouteFor(EmployeeRole role) => role == EmployeeRole.cashier
    ? '/'
    : role == EmployeeRole.custom
    ? '/settings'
    : '/dashboard';

/// [homeRouteFor] for a resolved access, custom roles included. The same
/// never-bounced rule decides the fallback: a custom role that can neither
/// sell nor read the day's summary lands on `/settings`, which no permission
/// guards — `/dashboard` would bounce it straight back to itself.
String homeRouteForAccess(EmployeeAccess access) =>
    access.can(AppPermission.sell)
    ? '/'
    : access.can(AppPermission.viewDailySummary)
    ? '/dashboard'
    : '/settings';
