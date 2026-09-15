/// One choice within a [ModifierGroup] — "Extra Spicy", "Boba".
///
/// [priceDelta] is always >= 0, enforced at the form that edits it (unlike
/// [ProductVariant.priceDelta], which genuinely needs negative values for a
/// smaller size). None of the modifiers this app models today — spice level,
/// toppings, sugar level, ice level, other add-ons — have a realistic
/// discount use case, so the simpler non-negative constraint removes a whole
/// class of "final price went negative" edge cases at the source rather than
/// clamping for it later in the cart.
class ModifierOption {
  const ModifierOption({
    required this.id,
    required this.groupId,
    required this.name,
    this.priceDelta = 0,
    this.sortOrder = 0,
    this.active = true,
  });

  final String id;
  final String groupId;
  final String name;
  final int priceDelta;
  final int sortOrder;
  final bool active;

  factory ModifierOption.fromMap(Map<String, dynamic> m) => ModifierOption(
    id: m['id'] as String,
    groupId: m['group_id'] as String,
    name: m['name'] as String,
    priceDelta: (m['price_delta'] as num?)?.toInt() ?? 0,
    sortOrder: (m['sort_order'] as int?) ?? 0,
    active: ((m['active'] as int?) ?? 1) == 1,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'group_id': groupId,
    'name': name,
    'price_delta': priceDelta,
    'sort_order': sortOrder,
    'active': active ? 1 : 0,
  };

  ModifierOption copyWith({
    String? id,
    String? groupId,
    String? name,
    int? priceDelta,
    int? sortOrder,
    bool? active,
  }) => ModifierOption(
    id: id ?? this.id,
    groupId: groupId ?? this.groupId,
    name: name ?? this.name,
    priceDelta: priceDelta ?? this.priceDelta,
    sortOrder: sortOrder ?? this.sortOrder,
    active: active ?? this.active,
  );
}
