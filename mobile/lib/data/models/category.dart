class Category {
  final String id;
  final String name;
  final String emoji;

  /// Key into the `icon_map` whitelist. This is what the UI renders - [emoji]
  /// is kept only as legacy data, since emoji do not render on every platform.
  final String? iconKey;
  final int sortOrder;
  final bool isPopular;

  const Category({
    required this.id,
    required this.name,
    required this.emoji,
    this.iconKey,
    this.sortOrder = 0,
    this.isPopular = false,
  });

  factory Category.fromMap(Map<String, dynamic> m) => Category(
    id: m['id'] as String,
    name: m['name'] as String,
    emoji: (m['emoji'] as String?) ?? '🍽️',
    iconKey: m['icon_key'] as String?,
    sortOrder: (m['sort_order'] as int?) ?? 0,
    isPopular: ((m['is_popular'] as int?) ?? 0) == 1,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'emoji': emoji,
    'icon_key': iconKey,
    'sort_order': sortOrder,
    'is_popular': isPopular ? 1 : 0,
  };

  Category copyWith({
    String? id,
    String? name,
    String? emoji,
    String? iconKey,
    int? sortOrder,
    bool? isPopular,
  }) => Category(
    id: id ?? this.id,
    name: name ?? this.name,
    emoji: emoji ?? this.emoji,
    iconKey: iconKey ?? this.iconKey,
    sortOrder: sortOrder ?? this.sortOrder,
    isPopular: isPopular ?? this.isPopular,
  );
}
