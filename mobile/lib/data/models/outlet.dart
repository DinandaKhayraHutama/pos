/// One branch of the business — a shop with its own address, its own stock and
/// its own floor.
///
/// Not a register. Two tills at the same counter share everything that matters
/// (the same shelf, the same tables, the same menu) and only need telling apart
/// for attribution. Two outlets share almost nothing: when the chicken runs out
/// in Bintaro, Kemang still has some, and a system that cannot say that is not
/// running a chain.
///
/// What an outlet separates, and what it does not, is written down in
/// CLAUDE.md — the list is a product decision, not an implementation detail,
/// and every query that forgets it becomes a wrong number on a report.
///
/// Deactivated rather than deleted: a closed branch still has years of sales
/// pointing at it. Orders keep [name] as a snapshot so a rename never rewrites
/// what an old receipt says.
class Outlet {
  const Outlet({
    required this.id,
    required this.name,
    this.address,
    this.active = true,
    this.sortOrder = 0,
  });

  final String id;

  /// What staff call it — "Bintaro", "Kemang", "Pusat".
  final String name;

  /// Street address. Printed on that branch's receipts, which is the whole
  /// reason a chain cannot keep one address in store settings.
  final String? address;

  final bool active;
  final int sortOrder;

  factory Outlet.fromMap(Map<String, dynamic> m) => Outlet(
    id: m['id'] as String,
    name: m['name'] as String,
    address: m['address'] as String?,
    active: ((m['active'] as int?) ?? 1) == 1,
    sortOrder: (m['sort_order'] as int?) ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'address': address,
    'active': active ? 1 : 0,
    'sort_order': sortOrder,
  };

  Outlet copyWith({
    String? id,
    String? name,
    String? address,
    bool? active,
    int? sortOrder,
  }) => Outlet(
    id: id ?? this.id,
    name: name ?? this.name,
    address: address ?? this.address,
    active: active ?? this.active,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}
