import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/core/pricing/pricing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/sync/order_push.dart';
import 'package:nti_pos/data/sync/sync_meta_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

/// What a Fase 3 sale sends, and to whom.
///
/// The server refuses a legacy receipt that carries a pricing snapshot,
/// included tax, rounding or a line breakdown, and a 2.7.0 server refuses
/// every key it does not know (`additionalProperties: false`). So the new
/// figures travel only on a version 2 receipt, and the new names only to a
/// server whose manifest says it reads them.
const _f3OrderKeys = {
  'pricing_version',
  'pricing',
  'tax_included',
  'rounding_amount',
  'tz_offset_minutes',
  'sales_type_id',
  'sales_type_name',
  'payment_method_id',
  'payment_method_name',
  'payment_reference',
  'served_by_id',
  'served_by_name',
  'discount_id',
  'discount_name',
  'discount_authorized_by_id',
  'discount_authorized_by_name',
};
const _breakdownKeys = {
  'custom',
  'base_price',
  'price_source',
  'tax_rate_bp',
  'discount',
  'line_discount_id',
  'line_discount_name',
  'line_discount_authorized_by_id',
  'line_discount_authorized_by_name',
  'line_discount',
  'bill_discount_share',
  'service_share',
  'tax_amount',
  'tax_included',
  'net_amount',
};

const _coffee = '6f1c3c4e-8a53-4c79-9d8e-0c6f1f2b7a10';
const _cashier = '2b7d0d8a-51f6-4a55-8d0c-3d9f4e2c1b20';
const _gofood = '9a0f5b1e-2c3d-4e5f-8a9b-0c1d2e3f4a5b';
const _server = '1d2e3f4a-5b6c-4d7e-8f90-a1b2c3d4e5f6';

void main() {
  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<String> openSession() async => (await ShiftRepository.instance.open(
    employeeId: 'e1',
    employeeName: 'Siti',
    openingCash: 0,
    posId: 'reg-1',
    posName: 'Kasir 1',
  )).id;

  /// A legacy (version 1) sale that still names its sales type and server.
  Future<Order> sellLegacy(String session) => OrderRepository.instance.create(
    type: OrderType.takeaway,
    items: const [
      OrderItemDraft(
        productId: _coffee,
        productName: 'Kopi Susu',
        unitPrice: 20000,
        quantity: 1,
      ),
    ],
    subtotal: 20000,
    discount: 0,
    tax: 2000,
    total: 22000,
    amountPaid: 22000,
    pb1Rate: 10,
    paymentMethod: PaymentMethod.cash,
    cashierId: _cashier,
    cashierName: 'Siti',
    posId: 'reg-1',
    posSessionId: session,
    salesTypeName: 'Takeaway',
    servedById: _server,
    servedByName: 'Budi',
    timezoneOffsetMinutes: 420,
  );

  /// A version 2 sale — inclusive PB1, rounding, a 10% item discount and a
  /// custom amount — priced by the engine exactly as the till prices it.
  Future<(Order, PriceResult)> sellV2(String session) async {
    final input = PriceInput(
      version: pricingVersionV2,
      taxMode: TaxMode.inclusive,
      serviceRateBp: 500,
      serviceTaxable: true,
      roundingUnit: 100,
      roundingMode: RoundingMode.nearest,
      lines: [
        PriceLine(
          unitPrice: 16500,
          quantity: 2,
          taxRateBp: 1000,
          discount: DiscountSpec.percent(10),
        ),
        const PriceLine(unitPrice: 7300, quantity: 1, taxRateBp: 1000),
      ],
    );
    final r = computePrice(input);
    final order = await OrderRepository.instance.create(
      type: OrderType.custom,
      items: [
        OrderItemDraft(
          productId: _coffee,
          productName: 'Kopi Susu',
          unitPrice: 16500,
          quantity: 2,
          basePrice: 16500,
          priceSource: 'sales_type',
          taxRateBp: 1000,
          discountSpec: DiscountSpec.percent(10).toJson(),
          lineDiscountName: 'Happy hour',
          lineDiscount: r.lines[0].lineDiscount,
          billDiscountShare: r.lines[0].billDiscountShare,
          serviceShare: r.lines[0].serviceShare,
          taxAmount: r.lines[0].taxAmount,
          taxIncluded: r.lines[0].taxIncluded,
          netAmount: r.lines[0].netAmount,
        ),
        OrderItemDraft(
          productId: 'custom:0b8f',
          productName: 'Ongkos titip',
          unitPrice: 7300,
          quantity: 1,
          custom: true,
          basePrice: 7300,
          priceSource: 'custom',
          taxRateBp: 1000,
          billDiscountShare: r.lines[1].billDiscountShare,
          serviceShare: r.lines[1].serviceShare,
          taxAmount: r.lines[1].taxAmount,
          taxIncluded: r.lines[1].taxIncluded,
          netAmount: r.lines[1].netAmount,
        ),
      ],
      subtotal: r.subtotal,
      discount: r.discount,
      tax: r.tax,
      serviceChargeAmount: r.serviceCharge,
      total: r.total,
      amountPaid: r.total,
      pb1Rate: 10,
      serviceChargeRate: 5,
      paymentMethod: PaymentMethod.ewallet,
      paymentMethodName: 'GoPay',
      cashierId: _cashier,
      cashierName: 'Siti',
      posId: 'reg-1',
      posSessionId: session,
      pricingVersion: pricingVersionV2,
      pricing: const {
        'tax_mode': 'inclusive',
        'service_rate_bp': 500,
        'service_taxable': true,
        'rounding_unit': 100,
        'rounding_mode': 'nearest',
      },
      taxIncluded: r.taxIncluded,
      roundingAmount: r.rounding,
      salesTypeId: _gofood,
      salesTypeName: 'GoFood',
    );
    return (order, r);
  }

  Future<Map<String, dynamic>> payload(String id) async =>
      jsonDecode(jsonEncode(await OrderPush.payloadWithin(db, id)))
          as Map<String, dynamic>;

  test(
    'a 2.7.0 server receives none of the Fase 3 keys, whatever was sold',
    () async {
      final session = await openSession();
      final legacy = await sellLegacy(session);
      final (v2, _) = await sellV2(session);

      for (final id in [legacy.id, v2.id]) {
        final body = await payload(id);
        expect(body.keys.toSet().intersection(_f3OrderKeys), isEmpty);
        for (final item in (body['items'] as List).cast<Map>()) {
          expect(item.keys.toSet().intersection(_breakdownKeys), isEmpty);
        }
      }
    },
  );

  test('a legacy receipt sends its names but never a version 2 term', () async {
    await SyncMetaStore.instance.recordManifestEntities({
      'orders',
      'business_settings',
    });
    final order = await sellLegacy(await openSession());
    final body = await payload(order.id);

    expect(body['sales_type_name'], 'Takeaway');
    expect(body['served_by_id'], _server);
    expect(body['served_by_name'], 'Budi');
    expect(body['tz_offset_minutes'], 420);
    // What validatePricing refuses on a legacy receipt.
    expect(body.containsKey('pricing_version'), isFalse);
    expect(body.containsKey('pricing'), isFalse);
    expect(body.containsKey('tax_included'), isFalse);
    expect(body.containsKey('rounding_amount'), isFalse);
    final item = (body['items'] as List).single as Map;
    expect(item.keys.toSet().intersection(_breakdownKeys), isEmpty);
  });

  test(
    'a version 2 receipt closes the way validatePricing checks it',
    () async {
      await SyncMetaStore.instance.recordManifestEntities({
        'orders',
        'business_settings',
      });
      final (order, r) = await sellV2(await openSession());
      final body = await payload(order.id);

      expect(body['pricing_version'], 2);
      expect((body['pricing'] as Map)['tax_mode'], 'inclusive');
      expect(body['tax_included'], r.taxIncluded);
      expect(body['rounding_amount'], r.rounding);
      expect(body['sales_type_id'], _gofood);
      expect(body['payment_method'], 'ewallet');
      expect(body['payment_method_name'], 'GoPay');

      // Header: total = subtotal − discount + tax − tax_included + service +
      // rounding (validate.go).
      expect(
        body['total'],
        (body['subtotal'] as int) -
            (body['discount'] as int) +
            (body['tax'] as int) -
            (body['tax_included'] as int) +
            (body['service_charge_amount'] as int) +
            (body['rounding_amount'] as int),
      );

      // Lines: each closes on its own, and together they add up to the header.
      var discount = 0, service = 0, tax = 0, included = 0;
      final items = (body['items'] as List).cast<Map<String, dynamic>>();
      for (final item in items) {
        expect(item.keys, containsAll(_breakdownKeys.difference({'discount'})));
        final gross = (item['unit_price'] as int) * (item['quantity'] as int);
        final ld = item['line_discount'] as int;
        final bs = item['bill_discount_share'] as int;
        final ti = item['tax_included'] as int;
        expect(item['net_amount'], gross - ld - bs - ti);
        expect(ti, lessThanOrEqualTo(item['tax_amount'] as int));
        discount += ld + bs;
        service += item['service_share'] as int;
        tax += item['tax_amount'] as int;
        included += ti;
      }
      expect(discount, body['discount']);
      expect(service, body['service_charge_amount']);
      expect(tax, body['tax']);
      expect(included, body['tax_included']);

      // The item discount travels as it was specified, the custom amount as
      // one naming no product.
      expect(items[0]['discount'], {'kind': 'percent', 'value': 1000});
      expect(items[0]['line_discount_name'], 'Happy hour');
      expect(items[1]['custom'], isTrue);
      expect(items[1]['product_id'], isNull);
    },
  );

  test('every revision of a version 2 receipt sends the same body', () async {
    await SyncMetaStore.instance.recordManifestEntities({
      'orders',
      'business_settings',
    });
    final (order, _) = await sellV2(await openSession());
    final first = await payload(order.id);
    final second = await payload(order.id);
    expect(jsonEncode(second), jsonEncode(first));
  });
}
