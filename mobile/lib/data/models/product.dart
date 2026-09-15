class Product {
  final String id;
  final String name;
  final String categoryId;
  final int price; // stored in smallest currency unit (rupiah cents-equivalent -> here plain rupiah)

  /// Cost of goods for this product, in the same unit as [price]. Null means
  /// it was never entered. Kept separate from [price] so margin reporting can
  /// be added without another migration.
  final int? cost;

  /// Stock keeping unit / barcode. Optional and free-form: a small kitchen may not
  /// use one at all, while a shop scanning barcodes will.
  final String? sku;

  /// On-hand quantity, or null when this product is not stock-tracked.
  ///
  /// Null and 0 mean different things and must not be conflated: null is "we
  /// do not count this" (kitchen items cooked to order), 0 is "we count this
  /// and there are none left" — which blocks selling it.
  final int? stock;

  /// PB1 (restaurant tax) percentage for this product, or null to use the
  /// store-wide rate.
  ///
  /// Null is not 0. Most of the menu should inherit whatever the store is
  /// registered for, and only the exceptions — a zero-rated staple, say —
  /// carry their own figure. Storing 0 everywhere would mean a change to the
  /// store rate silently skipped the whole catalogue. Service Charge has no
  /// per-product equivalent — it is always the single store-wide rate,
  /// since it is a blanket restaurant policy, not a tax classification.
  final double? pb1Rate;

  final String? description;
  final String emoji;
  final String? imageUrl; // optional product photo URL
  final String iconKey; // fallback Material icon name when emoji/image missing
  final bool available;
  final bool isPopular;
  final int sortOrder;

  const Product({
    required this.id,
    required this.name,
    required this.categoryId,
    required this.price,
    this.cost,
    this.sku,
    this.stock,
    this.pb1Rate,
    this.description,
    this.emoji = '🍽️',
    this.imageUrl,
    this.iconKey = 'restaurant',
    this.available = true,
    this.isPopular = false,
    this.sortOrder = 0,
  });

  /// Whether this product's quantity is counted at all.
  bool get tracksStock => stock != null;

  /// Out of stock — only meaningful for tracked products.
  bool get isOutOfStock => stock != null && stock! <= 0;

  /// Low enough to warrant a warning on the sell screen. The threshold is a
  /// display concern, not a data one, so it lives here rather than in settings
  /// until someone asks to configure it.
  static const int lowStockThreshold = 5;

  bool get isLowStock =>
      stock != null && stock! > 0 && stock! <= lowStockThreshold;

  /// Sellable right now: manually available, and either untracked or in stock.
  bool get isSellable => available && !isOutOfStock;

  /// The PB1 rate that actually applies, given the store-wide [storePb1Rate].
  double effectivePb1Rate(double storePb1Rate) => pb1Rate ?? storePb1Rate;

  factory Product.fromMap(Map<String, dynamic> m) => Product(
    id: m['id'] as String,
    name: m['name'] as String,
    categoryId: m['category_id'] as String,
    price: (m['price'] as num).toInt(),
    cost: (m['cost'] as num?)?.toInt(),
    sku: m['sku'] as String?,
    stock: (m['stock'] as num?)?.toInt(),
    pb1Rate: (m['tax_rate'] as num?)?.toDouble(),
    description: m['description'] as String?,
    emoji: (m['emoji'] as String?) ?? '🍽️',
    imageUrl: m['image_url'] as String?,
    iconKey: (m['icon_key'] as String?) ?? 'restaurant',
    available: ((m['available'] as int?) ?? 1) == 1,
    isPopular: ((m['is_popular'] as int?) ?? 0) == 1,
    sortOrder: (m['sort_order'] as int?) ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'category_id': categoryId,
    'price': price,
    // Written unconditionally, including null: an upsert that omitted the key
    // would leave a previous value in place, so clearing a cost or emptying
    // stock tracking would silently not stick.
    'cost': cost,
    'sku': sku,
    'stock': stock,
    'tax_rate': pb1Rate,
    'description': description,
    'emoji': emoji,
    if (imageUrl != null) 'image_url': imageUrl,
    'icon_key': iconKey,
    'available': available ? 1 : 0,
    'is_popular': isPopular ? 1 : 0,
    'sort_order': sortOrder,
  };

  /// Note the sentinel-free nullables: passing `cost: null` cannot clear a
  /// cost, matching every other copyWith in this codebase. Clearing goes
  /// through the constructor instead — the product form builds a whole Product.
  Product copyWith({
    String? id,
    String? name,
    String? categoryId,
    int? price,
    int? cost,
    String? sku,
    int? stock,
    double? pb1Rate,
    String? description,
    String? emoji,
    String? imageUrl,
    String? iconKey,
    bool? available,
    bool? isPopular,
    int? sortOrder,
  }) => Product(
    id: id ?? this.id,
    name: name ?? this.name,
    categoryId: categoryId ?? this.categoryId,
    price: price ?? this.price,
    cost: cost ?? this.cost,
    sku: sku ?? this.sku,
    stock: stock ?? this.stock,
    pb1Rate: pb1Rate ?? this.pb1Rate,
    description: description ?? this.description,
    emoji: emoji ?? this.emoji,
    imageUrl: imageUrl ?? this.imageUrl,
    iconKey: iconKey ?? this.iconKey,
    available: available ?? this.available,
    isPopular: isPopular ?? this.isPopular,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}
