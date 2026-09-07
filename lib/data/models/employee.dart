/// Who an employee is, which decides what the app lets them reach.
///
/// Three levels because a restaurant genuinely has three jobs, not because
/// more roles look better on a feature list. Each one answers a different
/// question:
///
///   * [cashier] — "can this person take money?"
///   * [manager] — "can this person fix a mistake on the floor?"
///   * [owner]   — "can this person change what the business sells and see
///     what it earned?"
///
/// The actual capability list lives in `core/auth/permissions.dart`. Screens
/// ask for a permission, never for a role, so adding a fourth role later means
/// adding one row to that table rather than hunting `== EmployeeRole.manager`
/// through the UI.
enum EmployeeRole {
  /// Sells, opens and closes their own till session. Sees only their own
  /// sales, cannot discount, void, refund or touch the catalogue.
  cashier,

  /// A cashier who can also unstick the floor: void, refund, discount by hand,
  /// check the drawer mid-shift and correct stock.
  manager,

  /// Full control of the business: catalogue and prices, financial reports,
  /// inventory, staff accounts and promotions.
  owner,
}

extension EmployeeRoleX on EmployeeRole {
  String get wire => name;

  static EmployeeRole fromWire(String v) => EmployeeRole.values.firstWhere(
    (e) => e.name == v,
    orElse: () => EmployeeRole.cashier,
  );
}

/// A person who can sign in to the till.
class Employee {
  const Employee({
    required this.id,
    required this.name,
    required this.pin,
    required this.role,
    this.active = true,
    this.sortOrder = 0,
  });

  final String id;
  final String name;

  /// 4-digit PIN, stored as entered.
  ///
  /// Plain text is a deliberate, documented shortcut for a local demo till with
  /// no accounts and no network: hashing it here would protect nothing, since
  /// anyone who can read the SQLite file can also read the app's own code. Real
  /// deployments must move authentication behind the API — see AGENTS.md.
  final String pin;

  final EmployeeRole role;
  final bool active;
  final int sortOrder;

  factory Employee.fromMap(Map<String, dynamic> m) => Employee(
    id: m['id'] as String,
    name: m['name'] as String,
    pin: m['pin'] as String,
    role: EmployeeRoleX.fromWire(m['role'] as String),
    active: ((m['active'] as int?) ?? 1) == 1,
    sortOrder: (m['sort_order'] as int?) ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'pin': pin,
    'role': role.wire,
    'active': active ? 1 : 0,
    'sort_order': sortOrder,
  };

  Employee copyWith({
    String? id,
    String? name,
    String? pin,
    EmployeeRole? role,
    bool? active,
    int? sortOrder,
  }) => Employee(
    id: id ?? this.id,
    name: name ?? this.name,
    pin: pin ?? this.pin,
    role: role ?? this.role,
    active: active ?? this.active,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}
