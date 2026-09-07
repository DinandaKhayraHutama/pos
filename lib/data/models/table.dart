import 'enums.dart';

class RestaurantTable {
  final String id;
  final String name;
  final int capacity;
  final TableStatus status;

  /// Free text — "Lantai 1", "Rooftop", "VIP". Not a fixed enum: table count
  /// and area names are per-outlet configuration, not a template baked into
  /// the app. `floor_1`..`floor_4` survive as display labels only for rows
  /// seeded before this was editable; a table created through the management
  /// screen stores whatever the admin typed and shows it back verbatim.
  final String floor;
  final int sortOrder;

  /// Which branch this table stands in. Null only on rows written before
  /// outlets existed; the board is filtered by it, so a null table would show
  /// up on every branch's floor plan at once.
  final String? outletId;

  /// Whether this table can be picked for a NEW dine-in order.
  ///
  /// Deactivated rather than deleted: `orders.table_id`/`table_name` are a
  /// snapshot copied at checkout, so removing the row here would not change
  /// a single past receipt — but it would leave nothing for an admin to
  /// reactivate if a table comes back into use. A table that is inactive but
  /// still mid-service (occupied/reserved) keeps showing on the floor board
  /// until it is cleared; only the "start a new order" pickers filter it out.
  final bool active;

  const RestaurantTable({
    required this.id,
    required this.name,
    required this.capacity,
    this.status = TableStatus.available,
    this.floor = 'floor_1',
    this.sortOrder = 0,
    this.outletId,
    this.active = true,
  });

  factory RestaurantTable.fromMap(Map<String, dynamic> m) => RestaurantTable(
    id: m['id'] as String,
    name: m['name'] as String,
    capacity: (m['capacity'] as num?)?.toInt() ?? 2,
    status: TableStatusX.fromWire((m['status'] as String?) ?? 'available'),
    floor: (m['floor'] as String?) ?? 'floor_1',
    sortOrder: (m['sort_order'] as int?) ?? 0,
    outletId: m['outlet_id'] as String?,
    active: ((m['active'] as int?) ?? 1) == 1,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'capacity': capacity,
    'status': status.wire,
    'floor': floor,
    'sort_order': sortOrder,
    'outlet_id': outletId,
    'active': active ? 1 : 0,
  };

  RestaurantTable copyWith({
    String? id,
    String? name,
    String? outletId,
    int? capacity,
    TableStatus? status,
    String? floor,
    int? sortOrder,
    bool? active,
  }) => RestaurantTable(
    id: id ?? this.id,
    name: name ?? this.name,
    capacity: capacity ?? this.capacity,
    status: status ?? this.status,
    floor: floor ?? this.floor,
    sortOrder: sortOrder ?? this.sortOrder,
    outletId: outletId ?? this.outletId,
    active: active ?? this.active,
  );
}
