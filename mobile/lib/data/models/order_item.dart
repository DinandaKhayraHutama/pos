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
  final String? brandId;
  final bool custom;
  final int? basePrice;
  final String? priceSource;
  final int? taxRateBp;
  final int lineDiscount;

  /// The item discount as it was specified (JSON `{kind, value}`), kept so a
  /// version 2 order can be recomputed by the server from what the till saw.
  final String? discountSpec;
  final String? lineDiscountId;
  final String? lineDiscountName;
  final String? lineDiscountAuthorizedById;
  final String? lineDiscountAuthorizedByName;
  final int billDiscountShare;
  final int serviceShare;
  final int taxAmount;
  final int taxIncluded;
  final int? netAmount;

  /// The bill line this receipt line settled (v33, paritas F4).
  final String? billLineId;

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
    this.brandId,
    this.custom = false,
    this.basePrice,
    this.priceSource,
    this.taxRateBp,
    this.lineDiscount = 0,
    this.discountSpec,
    this.lineDiscountId,
    this.lineDiscountName,
    this.lineDiscountAuthorizedById,
    this.lineDiscountAuthorizedByName,
    this.billDiscountShare = 0,
    this.serviceShare = 0,
    this.taxAmount = 0,
    this.taxIncluded = 0,
    this.netAmount,
    this.billLineId,
  });

  int get lineTotal => unitPrice * quantity;

  /// Full display name including the variant: "Kopi Susu (Large)".
  String get displayName => variantName == null || variantName!.isEmpty
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
    brandId: m['brand_id'] as String?,
    custom: (m['custom'] as int? ?? 0) == 1,
    basePrice: (m['base_price'] as num?)?.toInt(),
    priceSource: m['price_source'] as String?,
    taxRateBp: (m['tax_rate_bp'] as num?)?.toInt(),
    lineDiscount: (m['line_discount'] as num?)?.toInt() ?? 0,
    discountSpec: m['discount_spec'] as String?,
    lineDiscountId: m['line_discount_id'] as String?,
    lineDiscountName: m['line_discount_name'] as String?,
    lineDiscountAuthorizedById: m['line_discount_authorized_by_id'] as String?,
    lineDiscountAuthorizedByName:
        m['line_discount_authorized_by_name'] as String?,
    billDiscountShare: (m['bill_discount_share'] as num?)?.toInt() ?? 0,
    serviceShare: (m['service_share'] as num?)?.toInt() ?? 0,
    taxAmount: (m['tax_amount'] as num?)?.toInt() ?? 0,
    taxIncluded: (m['tax_included'] as num?)?.toInt() ?? 0,
    netAmount: (m['net_amount'] as num?)?.toInt(),
    billLineId: m['bill_line_id'] as String?,
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
    'brand_id': brandId,
    'custom': custom ? 1 : 0,
    'base_price': basePrice,
    'price_source': priceSource,
    'tax_rate_bp': taxRateBp,
    'line_discount': lineDiscount,
    'discount_spec': discountSpec,
    'line_discount_id': lineDiscountId,
    'line_discount_name': lineDiscountName,
    'line_discount_authorized_by_id': lineDiscountAuthorizedById,
    'line_discount_authorized_by_name': lineDiscountAuthorizedByName,
    'bill_discount_share': billDiscountShare,
    'service_share': serviceShare,
    'tax_amount': taxAmount,
    'tax_included': taxIncluded,
    'net_amount': netAmount,
    'bill_line_id': billLineId,
  };
}
