import 'enums.dart';

/// A reusable set of choices attached to one or more products — spice level,
/// toppings, sugar level, ice level. Distinct from [ProductVariant]: a
/// variant picks the product itself (Regular vs Large, one choice, always
/// exactly one), a modifier group adds options on top of whichever variant
/// was picked, and a product can carry several groups at once.
///
/// [required] with zero active [ModifierOption]s (an admin mistake — the
/// group's only option got deactivated, or none were ever added) must never
/// make a product unsellable. Callers treat that combination as vacuously
/// satisfied rather than blocking checkout — see `ModifierPickerSheet`.
class ModifierGroup {
  const ModifierGroup({
    required this.id,
    required this.name,
    this.selectionType = ModifierSelectionType.single,
    this.required = false,
    this.maxSelect,
    this.sortOrder = 0,
    this.active = true,
  });

  final String id;
  final String name;
  final ModifierSelectionType selectionType;

  /// Whether at least one option must be picked before checkout.
  final bool required;

  /// Upper bound on how many options may be picked at once. Only meaningful
  /// when [selectionType] is [ModifierSelectionType.multiple] — a single
  /// group is implicitly capped at one. Null means unlimited.
  final int? maxSelect;

  final int sortOrder;
  final bool active;

  factory ModifierGroup.fromMap(Map<String, dynamic> m) => ModifierGroup(
    id: m['id'] as String,
    name: m['name'] as String,
    selectionType: ModifierSelectionTypeX.fromWire(
      (m['selection_type'] as String?) ?? 'single',
    ),
    required: ((m['required'] as int?) ?? 0) == 1,
    maxSelect: (m['max_select'] as num?)?.toInt(),
    sortOrder: (m['sort_order'] as int?) ?? 0,
    active: ((m['active'] as int?) ?? 1) == 1,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'selection_type': selectionType.wire,
    'required': required ? 1 : 0,
    'max_select': maxSelect,
    'sort_order': sortOrder,
    'active': active ? 1 : 0,
  };

  ModifierGroup copyWith({
    String? id,
    String? name,
    ModifierSelectionType? selectionType,
    bool? required,
    int? maxSelect,
    bool clearMaxSelect = false,
    int? sortOrder,
    bool? active,
  }) => ModifierGroup(
    id: id ?? this.id,
    name: name ?? this.name,
    selectionType: selectionType ?? this.selectionType,
    required: required ?? this.required,
    maxSelect: clearMaxSelect ? null : (maxSelect ?? this.maxSelect),
    sortOrder: sortOrder ?? this.sortOrder,
    active: active ?? this.active,
  );
}
