import 'package:sqflite/sqflite.dart';

import 'wire_values.dart';

/// A sale as `POST /api/v2/sync/push` receives it.
///
/// The most consequential payload in the app: every row here is money a
/// customer has already handed over.
///
/// **One order is one row, with its lines and modifiers nested.** Not three
/// entity pushes — the server writes the whole sale in one transaction, and
/// splitting it would let a header land without its lines. A total with no
/// lines is a figure nobody can explain, and it passes every check that only
/// looks at the order table.
///
/// **Only the keys the contract allows.** The `Order` schema is
/// `additionalProperties: false`: one extra column and every sale is rejected.
/// Identity (tenant, outlet, register, device) is never sent — the server takes
/// it from the token.
///
/// **Deterministic.** The server stores the first accepted revision and later
/// compares every field except status and its audit trail. Lines are read in
/// insertion order and every conversion goes through `wire_values.dart`, so a
/// void re-sends byte-identical amounts and lines.
class OrderPush {
  const OrderPush._();

  static const entity = 'orders';

  static Future<Map<String, Object?>?> payloadWithin(
    DatabaseExecutor txn,
    String orderId,
  ) async {
    final orders = await txn.query(
      'orders',
      where: 'id = ?',
      whereArgs: [orderId],
      limit: 1,
    );
    if (orders.isEmpty) return null;
    final order = orders.first;

    final placedAtMs = wireInt(order['created_at']);
    var businessDate = order['business_date'] as String?;
    if (businessDate == null || businessDate.isEmpty) {
      // A sale written before v25 has no stored business day. It is chosen
      // now, from the time the sale was made, and written back in the same
      // transaction — so every later revision carries the same date, and a
      // timezone change on the tablet cannot move the sale to another day.
      businessDate = businessDateFor(
        DateTime.fromMillisecondsSinceEpoch(placedAtMs),
      );
      await txn.update(
        'orders',
        {'business_date': businessDate},
        where: 'id = ?',
        whereArgs: [orderId],
      );
    }

    final items = await txn.query(
      'order_items',
      where: 'order_id = ?',
      whereArgs: [orderId],
      orderBy: 'rowid ASC',
    );

    final itemPayloads = <Map<String, Object?>>[];
    for (final item in items) {
      final modifiers = await txn.query(
        'order_item_modifiers',
        where: 'order_item_id = ?',
        whereArgs: [item['id']],
        orderBy: 'sort_order ASC, rowid ASC',
      );

      itemPayloads.add({
        'id': item['id'],
        'product_id': uuidOrNull(item['product_id']),
        'product_name': item['product_name'],
        'variant_name': item['variant_name'],
        // Already the final per-unit price, variant and modifiers included.
        // The modifier rows below are an audit breakdown; the server sums
        // unit_price * quantity and never adds their deltas again.
        'unit_price': wireInt(item['unit_price']),
        'unit_cost': wireIntOrNull(item['unit_cost']),
        'quantity': wireInt(item['quantity']),
        'note': item['note'],
        'category_id': uuidOrNull(item['category_id']),
        'category_name': item['category_name'],
        'modifiers': [
          for (final m in modifiers)
            {
              'id': m['id'],
              'group_name': m['group_name'],
              'option_name': m['option_name'],
              'price_delta': wireInt(m['price_delta']),
              'sort_order': wireInt(m['sort_order']),
            },
        ],
      });
    }

    final delta = wireIntOrNull(order['server_time_delta_ms']);

    return {
      'id': order['id'],
      'business_date': businessDate,
      'number': order['number'],
      // The device's clock, as the till recorded it. The server keeps its own
      // receive time; a reconciliation needs to tell the two apart.
      'placed_at_ms': placedAtMs,
      // Not nullable in the schema: absent rather than null when unmeasured.
      'server_time_delta_ms': ?delta,
      'type': order['type'],
      'status': order['status'],
      'pos_session_id': order['pos_session_id'],
      'table_id': uuidOrNull(order['table_id']),
      'table_name': order['table_name'],
      'customer_name': order['customer_name'],
      'note': order['note'],
      'subtotal': wireInt(order['subtotal']),
      'discount': wireInt(order['discount']),
      'tax': wireInt(order['tax']),
      'service_charge_amount': wireInt(order['service_charge_amount']),
      'total': wireInt(order['total']),
      'amount_paid': wireInt(order['amount_paid']),
      'pb1_rate': wireRate(order['pb1_rate']),
      'service_charge_rate': wireRate(order['service_charge_rate']),
      'payment_method': order['payment_method'],
      'promo_name': order['promo_name'],
      'cashier_id': uuidOrNull(order['cashier_id']),
      'cashier_name': order['cashier_name'],
      'outlet_name': order['outlet_name'],
      'pos_name': order['pos_name'],
      'authorized_by': order['authorized_by'],
      'void_reason': order['void_reason'],
      'refunded_amount': wireIntOrNull(order['refunded_amount']),
      'items': itemPayloads,
    };
  }
}
