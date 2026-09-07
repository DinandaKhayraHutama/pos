/// A modifier option as it was actually sold on one order line.
///
/// A snapshot, not a reference — [groupName]/[optionName]/[priceDelta] are
/// copied at sale time and never joined back to `modifier_groups`/
/// `modifier_options`, which is why there is no `groupId`/`optionId` here.
/// An admin renaming "Topping" to "Add-ons" next month, or deleting the
/// group entirely, must not change what a receipt from today says. This
/// mirrors [OrderItem.productName]/[OrderItem.variantName].
class OrderItemModifier {
  const OrderItemModifier({
    required this.id,
    required this.orderItemId,
    required this.groupName,
    required this.optionName,
    this.priceDelta = 0,
    this.sortOrder = 0,
  });

  final String id;
  final String orderItemId;
  final String groupName;
  final String optionName;
  final int priceDelta;
  final int sortOrder;

  factory OrderItemModifier.fromMap(Map<String, dynamic> m) =>
      OrderItemModifier(
        id: m['id'] as String,
        orderItemId: m['order_item_id'] as String,
        groupName: m['group_name'] as String,
        optionName: m['option_name'] as String,
        priceDelta: (m['price_delta'] as num?)?.toInt() ?? 0,
        sortOrder: (m['sort_order'] as int?) ?? 0,
      );

  Map<String, dynamic> toMap() => {
    'id': id,
    'order_item_id': orderItemId,
    'group_name': groupName,
    'option_name': optionName,
    'price_delta': priceDelta,
    'sort_order': sortOrder,
  };
}
