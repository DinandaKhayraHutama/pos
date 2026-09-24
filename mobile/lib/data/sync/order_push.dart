import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'wire_values.dart';
import 'stock_movement_push.dart';
import 'sync_meta_store.dart';

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
    final supportsCustomers = await SyncMetaStore.supportsEntityWithin(
      txn,
      'customers',
    );
    final supportsBrands = await SyncMetaStore.supportsEntityWithin(
      txn,
      'brands',
    );
    final supportsPricing = await SyncMetaStore.supportsEntityWithin(
      txn,
      'business_settings',
    );
    final orders = await txn.query(
      'orders',
      where: 'id = ?',
      whereArgs: [orderId],
      limit: 1,
    );
    if (orders.isEmpty) return null;
    final order = orders.first;
    // The Fase 3 figures travel only on a version 2 receipt, which is the only
    // kind the server checks them on: a legacy receipt that brought a
    // snapshot, included tax or a line breakdown is refused outright. The
    // version is read from the stored row, so every revision decides alike.
    final v2 = supportsPricing && order['pricing_version'] == 2;

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
        if (supportsBrands) 'brand_id': uuidOrNull(item['brand_id']),
        if (v2) ...{
          'custom': wireInt(item['custom']) == 1,
          'base_price': wireInt(item['base_price']),
          'price_source': item['price_source'],
          'tax_rate_bp': wireInt(item['tax_rate_bp']),
          if (item['discount_spec'] is String)
            'discount': jsonDecode(item['discount_spec'] as String),
          'line_discount_id': uuidOrNull(item['line_discount_id']),
          'line_discount_name': item['line_discount_name'],
          'line_discount_authorized_by_id': uuidOrNull(
            item['line_discount_authorized_by_id'],
          ),
          'line_discount_authorized_by_name':
              item['line_discount_authorized_by_name'],
          'line_discount': wireInt(item['line_discount']),
          'bill_discount_share': wireInt(item['bill_discount_share']),
          'service_share': wireInt(item['service_share']),
          'tax_amount': wireInt(item['tax_amount']),
          'tax_included': wireInt(item['tax_included']),
          'net_amount': wireInt(item['net_amount']),
        },
        // Fase 4: the bill line this receipt line settles. Only a bill's
        // receipt carries it, and such a receipt exists only where the server
        // runs saved bills — an older server would refuse the key.
        if (item['bill_line_id'] != null) 'bill_line_id': item['bill_line_id'],
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
    final sessionId = order['pos_session_id'];
    final claimed = sessionId is String && sessionId.isNotEmpty
        ? await txn.query(
            '_till_sessions',
            where: 'id = ?',
            whereArgs: [sessionId],
          )
        : const <Map<String, Object?>>[];
    final effects = <Map<String, Object?>>[];
    if (claimed.isNotEmpty) {
      final movements = await txn.query(
        'stock_movements',
        where: 'order_id = ?',
        whereArgs: [orderId],
        orderBy: 'id',
      );
      for (final movement in movements) {
        final effect = await StockMovementPush.payloadWithin(
          txn,
          movement['id'] as String,
        );
        if (effect != null) effects.add({...effect, 'revision': 1});
      }
    }

    return {
      if (claimed.isNotEmpty) 'stock_movements': effects,
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
      if (supportsCustomers) 'customer_id': uuidOrNull(order['customer_id']),
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
      if (v2) ...{
        'pricing_version': 2,
        if (order['pricing'] is String)
          'pricing': jsonDecode(order['pricing'] as String),
        'tax_included': wireInt(order['tax_included']),
        'rounding_amount': wireInt(order['rounding_amount']),
      },
      // The snapshot names — sales type, payment method, server, discount —
      // belong to any receipt a 2.8.0 server can read, legacy ones included.
      if (supportsPricing) ...{
        if (order['tz_offset_minutes'] != null)
          'tz_offset_minutes': wireInt(order['tz_offset_minutes']),
        'sales_type_id': uuidOrNull(order['sales_type_id']),
        'sales_type_name': order['sales_type_name'],
        'payment_method_id': uuidOrNull(order['payment_method_id']),
        'payment_method_name': order['payment_method_name'],
        'payment_reference': order['payment_reference'],
        'served_by_id': uuidOrNull(order['served_by_id']),
        'served_by_name': order['served_by_name'],
        'discount_id': uuidOrNull(order['discount_id']),
        'discount_name': order['discount_name'],
        'discount_authorized_by_id': uuidOrNull(
          order['discount_authorized_by_id'],
        ),
        'discount_authorized_by_name': order['discount_authorized_by_name'],
      },
      if (order['bill_id'] != null) 'bill_id': order['bill_id'],
      'items': itemPayloads,
    };
  }
}
