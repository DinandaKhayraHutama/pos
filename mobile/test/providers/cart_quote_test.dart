import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/pricing/pricing.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/models/product_variant.dart';
import 'package:nti_pos/data/models/sales_config.dart';
import 'package:nti_pos/data/repositories/sales_config_repository.dart';
import 'package:nti_pos/providers/cart_provider.dart';
import 'package:nti_pos/providers/pricing_provider.dart';

const _coffee = Product(
  id: 'p_kopi',
  name: 'Kopi Susu',
  categoryId: 'c_drinks',
  price: 20000,
);
const _rice = Product(
  id: 'p_nasi',
  name: 'Nasi Goreng',
  categoryId: 'c_food',
  price: 30000,
  pb1Rate: 0,
);
const _large = ProductVariant(
  id: 'v_large',
  productId: 'p_kopi',
  name: 'Large',
  priceDelta: 5000,
);
const _gofood = SalesType(
  id: 'st_gofood',
  name: 'GoFood',
  usesTable: false,
  active: true,
);

const _fallback = (taxRateBp: 1000, serviceRateBp: 500);

EffectiveBusinessConfig _config(int version) => EffectiveBusinessConfig(
  pricingVersion: version,
  taxRateBp: 1000,
  taxMode: TaxMode.inclusive,
  serviceRateBp: 500,
  serviceTaxable: true,
  roundingUnit: 100,
  roundingMode: RoundingMode.up,
);

PricingContext _context(int version) => PricingContext(
  config: _config(version),
  salesTypes: const [_gofood],
  businessPrices: const {'p_kopi|st_gofood': 22000},
  outletPrices: const {'p_kopi|st_gofood': 23000},
);

/// A GoFood cart: a Large coffee with a 10% item discount, a rice, and 10%
/// off the bill.
CartState _cart() {
  final cart = CartNotifier()
    ..add(_coffee, variant: _large)
    ..add(_rice)
    ..setSalesType(_gofood)
    ..applyManualDiscount(
      authorizedBy: 'Rina',
      authorizedById: 'e_rina',
      percent: 10,
    );
  cart.setLineDiscount(
    cart.state.lines.first.key,
    discount: DiscountSpec.percent(10),
    approvedBy: (id: 'e_rina', name: 'Rina'),
  );
  return cart.state;
}

void main() {
  test('an unconfigured till prices with the legacy cart math, exactly', () {
    final cart = CartNotifier()
      ..add(_coffee, variant: _large, qty: 2)
      ..add(_rice)
      ..applyManualDiscount(authorizedBy: 'Rina', percent: 10);
    final quote = computeCartQuote(
      cart.state,
      PricingContext.empty,
      fallback: _fallback,
    );

    expect(quote.version, pricingVersionLegacy);
    expect(quote.configured, isFalse);
    // The engine's version 1 is a port of these getters; the till must not
    // charge a cent differently from before Fase 3.
    expect(quote.result.subtotal, cart.state.subtotal);
    expect(quote.result.discount, cart.state.discountAmount);
    expect(quote.result.serviceCharge, cart.state.serviceChargeFor(5));
    expect(
      quote.result.tax,
      cart.state.pb1For(pb1Rate: 10, serviceChargeRate: 5),
    );
    expect(
      quote.result.total,
      cart.state.totalFor(pb1Rate: 10, serviceChargeRate: 5),
    );
    expect(quote.pricingSnapshot, isNull);
  });

  test('a legacy outlet ignores what only version 2 honours', () {
    final quote = computeCartQuote(_cart(), _context(1), fallback: _fallback);

    expect(quote.version, pricingVersionLegacy);
    expect(quote.isV2, isFalse);
    // No sales-type price, no item discount, no inclusive tax, no rounding.
    expect(quote.lines.first.unitPrice, 25000);
    expect(quote.lines.first.priceSource, 'base');
    expect(quote.lines.first.discount, isNull);
    expect(quote.lines.first.result.lineDiscount, 0);
    expect(quote.taxMode, TaxMode.exclusive);
    expect(quote.roundingUnit, 0);
    expect(quote.result.taxIncluded, 0);
    expect(quote.result.rounding, 0);
    expect(quote.pricingSnapshot, isNull);
    // Its configured rates still apply.
    expect(quote.defaultTaxRateBp, 1000);
    expect(quote.serviceRateBp, 500);
    // And the sales type still names the sale.
    expect(quote.salesType?.id, 'st_gofood');
  });

  test('a version 2 outlet resolves the outlet price, then adds the deltas '
      'once', () {
    final quote = computeCartQuote(_cart(), _context(2), fallback: _fallback);

    expect(quote.isV2, isTrue);
    final coffee = quote.lines.first;
    expect(coffee.priceSource, 'outlet_sales_type');
    expect(coffee.basePrice, 23000);
    expect(coffee.unitPrice, 23000 + 5000);
    expect(coffee.discount, DiscountSpec.percent(10));
    expect(coffee.result.lineDiscount, 2800);
    // A product's own 0% overrides the outlet default; no price override.
    final rice = quote.lines.last;
    expect(rice.taxRateBp, 0);
    expect(rice.priceSource, 'base');
    expect(rice.unitPrice, 30000);

    // Inclusive tax is extracted, never added; rounding goes up to 100.
    expect(quote.result.taxIncluded, greaterThan(0));
    expect(quote.result.total % 100, 0);
    expect(
      quote.result.total,
      quote.result.subtotal -
          quote.result.discount +
          quote.result.tax -
          quote.result.taxIncluded +
          quote.result.serviceCharge +
          quote.result.rounding,
    );

    final snapshot = quote.pricingSnapshot!;
    expect(snapshot['tax_mode'], 'inclusive');
    expect(snapshot['rounding_mode'], 'up');
    expect(snapshot['bill_discount'], {'kind': 'percent', 'value': 1000});
  });

  test('without an outlet override the business sales-type price applies', () {
    final context = PricingContext(
      config: _config(2),
      salesTypes: const [_gofood],
      businessPrices: const {'p_kopi|st_gofood': 22000},
    );
    final quote = computeCartQuote(_cart(), context, fallback: _fallback);
    expect(quote.lines.first.priceSource, 'sales_type');
    expect(quote.lines.first.unitPrice, 22000 + 5000);
  });

  test('a custom amount is priced as typed, at the outlet default tax', () {
    final cart = CartNotifier()
      ..addCustomAmount(label: 'Ongkos titip', amount: 7300);
    final quote = computeCartQuote(
      cart.state,
      _context(2),
      fallback: _fallback,
    );
    final line = quote.lines.single;
    expect(line.priceSource, 'custom');
    expect(line.unitPrice, 7300);
    expect(line.taxRateBp, 1000);
    expect(cart.state.lines.single.product.id, startsWith(customLinePrefix));
  });

  test('dropping version 2 lines leaves a cart a legacy outlet can sell', () {
    final cart = CartNotifier()
      ..add(_coffee)
      ..addCustomAmount(label: 'Ongkos titip', amount: 7300);
    cart.setLineDiscount(
      cart.state.lines.first.key,
      discount: DiscountSpec.percent(10),
    );
    cart.dropVersion2Only();
    expect(cart.state.lines, hasLength(1));
    expect(cart.state.hasLineDiscounts, isFalse);
    expect(cart.state.hasCustomLines, isFalse);
  });
}
