import 'order_item_modifier.dart';

class OrderItem {
  final String id;
  final String orderId;
  final String productId;
  final String productName;

  /// Which variant was chosen, or null when the product has none.
  ///
  /// Stored on the line rather than looked up later: variants get renamed and
  /// deleted, and a receipt reprinted next month has to still say "Large".
  final String? variantName;

  /// Price actually charged per unit, variant delta already applied. The
  /// delta is not stored separately — the line has to reprint at what the
  /// customer paid, not at what the catalogue says today.
  final int unitPrice;

  /// Cost of goods per unit at the time of sale, or null when the product had
  /// no cost recorded. Frozen here so a profit report cannot be rewritten by
  /// someone editing the product's cost afterwards.
  final int? unitCost;

  final int quantity;
  final String? note;

  /// Modifiers picked on this line (spice level, toppings, ...), snapshot at
  /// sale time. Empty for the vast majority of lines that use none.
  final List<OrderItemModifier> modifiers;

  /// The product's category at the moment of sale, snapshot like
  /// [productName] — a category rename or a product moved to a different
  /// category later must not rewrite a sales-by-category report that has
  /// already run. Null only for rows written before this snapshot existed
  /// and whose product has since been deleted (nothing left to backfill
  /// from); every other row gets it filled in by
  /// `OrderRepository.create`/the v17 migration backfill.
  final String? categoryId;
  final String? categoryName;

  const OrderItem({
    required this.id,
    required this.orderId,
    required this.productId,
    required this.productName,
    required this.unitPrice,
    required this.quantity,
    this.variantName,
    this.unitCost,
    this.note,
    this.modifiers = const [],
    this.categoryId,
    this.categoryName,
  });

  int get lineTotal => unitPrice * quantity;

  /// Full display name including the variant: "Kopi Susu (Large)".
  String get displayName =>
      variantName == null || variantName!.isEmpty
      ? productName
      : '$productName ($variantName)';

  /// [modifiers] are attached separately (from a second query against
  /// `order_item_modifiers`, grouped by `order_item_id`), never joined here —
  /// this factory only ever sees one `order_items` row.
  factory OrderItem.fromMap(
    Map<String, dynamic> m, {
    List<OrderItemModifier> modifiers = const [],
  }) => OrderItem(
    id: m['id'] as String,
    orderId: m['order_id'] as String,
    productId: m['product_id'] as String,
    productName: m['product_name'] as String,
    variantName: m['variant_name'] as String?,
    unitPrice: (m['unit_price'] as num).toInt(),
    unitCost: (m['unit_cost'] as num?)?.toInt(),
    quantity: (m['quantity'] as num).toInt(),
    note: m['note'] as String?,
    modifiers: modifiers,
    categoryId: m['category_id'] as String?,
    categoryName: m['category_name'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'order_id': orderId,
    'product_id': productId,
    'product_name': productName,
    'variant_name': variantName,
    'unit_price': unitPrice,
    'unit_cost': unitCost,
    'quantity': quantity,
    'note': note,
    'category_id': categoryId,
    'category_name': categoryName,
  };
}
