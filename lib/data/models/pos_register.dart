/// One till at a branch — the thing a cashier signs on to before selling.
///
/// The distinction an outlet does NOT make. Two registers at the same counter
/// share the shelf, the floor plan and the menu; what they do not share is who
/// is standing at them, which drawer the cash is in, and how they are meant to
/// be operated. That last part is why this is a row rather than a number: a
/// restaurant can run a dine-in till and a takeaway counter side by side, and
/// asking the takeaway counter which table the guest is at is a step that has
/// no answer.
///
/// [tableService] is the first such operational setting, and deliberately
/// lives here rather than on the store: it decides whether this till runs the
/// floor-plan flow at all. Everything downstream — the Tables tab, the table
/// row in the cart, the "dine-in needs a table" guard — already reads a single
/// resolved flag, so it is only the SOURCE that moved.
///
/// Deactivated rather than deleted, like [Outlet] and [Employee]: a retired
/// till still has sessions and sales pointing at it, and orders keep [name] as
/// a snapshot so a reprint never renames a till that no longer exists.
class PosRegister {
  const PosRegister({
    required this.id,
    required this.outletId,
    required this.name,
    this.tableService = true,
    this.active = true,
    this.sortOrder = 0,
  });

  final String id;

  /// Which branch this till stands in. A register belongs to exactly one
  /// outlet — moving it would file its past sessions in a shop they never
  /// happened at.
  final String outletId;

  /// What staff call it — "Kasir 1", "Bar", "Drive-thru".
  ///
  /// Unique per outlet, not globally: every branch is allowed its own
  /// "Kasir 1", and forcing "Bintaro Kasir 1" onto the button a cashier taps
  /// forty times a shift would be the tail wagging the dog.
  final String name;

  /// Whether this till seats guests at numbered tables.
  ///
  /// Defaults to on so a till created without a thought behaves the way the
  /// app always has.
  final bool tableService;

  final bool active;
  final int sortOrder;

  factory PosRegister.fromMap(Map<String, dynamic> m) => PosRegister(
    id: m['id'] as String,
    outletId: m['outlet_id'] as String,
    name: m['name'] as String,
    tableService: ((m['table_service'] as int?) ?? 1) == 1,
    active: ((m['active'] as int?) ?? 1) == 1,
    sortOrder: (m['sort_order'] as int?) ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'outlet_id': outletId,
    'name': name,
    'table_service': tableService ? 1 : 0,
    'active': active ? 1 : 0,
    'sort_order': sortOrder,
  };

  PosRegister copyWith({
    String? id,
    String? outletId,
    String? name,
    bool? tableService,
    bool? active,
    int? sortOrder,
  }) => PosRegister(
    id: id ?? this.id,
    outletId: outletId ?? this.outletId,
    name: name ?? this.name,
    tableService: tableService ?? this.tableService,
    active: active ?? this.active,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}
