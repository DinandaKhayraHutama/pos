/// One choice within a product, priced as a delta from the base price.
///
/// A delta rather than an absolute price so a price rise only has to be typed
/// once, on the product: "Large +Rp 5.000" stays correct after the base goes
/// from 15k to 17k, whereas an absolute 20.000 silently becomes wrong.
///
/// Products with no variants sell exactly as before — the cart falls back to
/// the base price and never shows a picker. That keeps a restaurant that sells one
/// size of everything from paying for a feature it did not ask for.
class ProductVariant {
  const ProductVariant({
    required this.id,
    required this.productId,
    required this.name,
    this.priceDelta = 0,
    this.sortOrder = 0,
  });

  final String id;
  final String productId;
  final String name;

  /// Added to the product's base price. May be negative (a small size).
  final int priceDelta;

  final int sortOrder;

  factory ProductVariant.fromMap(Map<String, dynamic> m) => ProductVariant(
    id: m['id'] as String,
    productId: m['product_id'] as String,
    name: m['name'] as String,
    priceDelta: (m['price_delta'] as num?)?.toInt() ?? 0,
    sortOrder: (m['sort_order'] as int?) ?? 0,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'product_id': productId,
    'name': name,
    'price_delta': priceDelta,
    'sort_order': sortOrder,
  };

  ProductVariant copyWith({
    String? id,
    String? productId,
    String? name,
    int? priceDelta,
    int? sortOrder,
  }) => ProductVariant(
    id: id ?? this.id,
    productId: productId ?? this.productId,
    name: name ?? this.name,
    priceDelta: priceDelta ?? this.priceDelta,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}
