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
    this.pin = '',
    this.pinHash,
    required this.role,
    this.active = true,
    this.sortOrder = 0,
  });

  final String id;
  final String name;

  /// Legacy plain-text PIN, for demo and pre-backend accounts.
  ///
  /// Plain text was a deliberate, documented shortcut for a local till with no
  /// accounts and no network: hashing it here protects nothing, since anyone
  /// who can read the SQLite file can also read the app's own code.
  ///
  /// Empty for any account that arrived from the server — those carry
  /// [pinHash] instead. Both are kept because a device that has not synced yet
  /// still has to let its cashiers in; see the v23 migration.
  final String pin;

  /// bcrypt hash pushed down from the server.
  ///
  /// When set, this is the credential and [pin] is ignored. Verified on-device
  /// so signing in needs no network at all — the whole point of the offline
  /// till.
  final String? pinHash;

  final EmployeeRole role;
  final bool active;
  final int sortOrder;

  /// True when this account's credential came from the server.
  bool get usesHashedPin => pinHash != null && pinHash!.isNotEmpty;

  factory Employee.fromMap(Map<String, dynamic> m) => Employee(
    id: m['id'] as String,
    name: m['name'] as String,
    pin: (m['pin'] as String?) ?? '',
    pinHash: m['pin_hash'] as String?,
    role: EmployeeRoleX.fromWire(m['role'] as String),
    active: ((m['active'] as int?) ?? 1) == 1,
    sortOrder: (m['sort_order'] as int?) ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'pin': pin,
    'pin_hash': pinHash,
    'role': role.wire,
    'active': active ? 1 : 0,
    'sort_order': sortOrder,
  };

  Employee copyWith({
    String? id,
    String? name,
    String? pin,
    String? pinHash,
    EmployeeRole? role,
    bool? active,
    int? sortOrder,
  }) => Employee(
    id: id ?? this.id,
    name: name ?? this.name,
    pin: pin ?? this.pin,
    pinHash: pinHash ?? this.pinHash,
    role: role ?? this.role,
    active: active ?? this.active,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}
