import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/pricing/pricing.dart';
import '../data/device/till_coordinator.dart';
import '../data/models/employee.dart';
import '../data/models/sales_config.dart';
import '../data/repositories/employee_repository.dart';
import '../data/repositories/sales_config_repository.dart';
import '../data/sync/wire_values.dart';
import 'cart_provider.dart';
import 'outlet_provider.dart';
import 'settings_provider.dart';

/// The Fase 3 pricing context of the outlet this till stands in, read from
/// the pulled feeds. Invalidated after every sync that wrote rows.
final pricingContextProvider = FutureProvider.autoDispose<PricingContext>((
  ref,
) async {
  final outletId = ref.watch(activeOutletProvider).valueOrNull?.id ?? '';
  if (outletId.isEmpty) return PricingContext.empty;
  return SalesConfigRepository.instance.context(outletId);
});

/// One priced line, as the order will store it.
class QuotedLine {
  const QuotedLine({
    required this.unitPrice,
    required this.basePrice,
    required this.priceSource,
    required this.taxRateBp,
    required this.result,
    this.discount,
  });
  final int unitPrice;
  final int basePrice;

  /// `base`, `sales_type`, `outlet_sales_type` or `custom`.
  final String priceSource;
  final int taxRateBp;
  final DiscountSpec? discount;
  final LineResult result;
}

/// The priced cart. Everything the till shows and everything it records is
/// read from this one object, so the summary a cashier reads, the total the
/// customer pays and the figures that go to the server cannot disagree.
class CartQuote {
  const CartQuote({
    required this.version,
    required this.result,
    required this.lines,
    required this.configured,
    this.billDiscount,
    this.taxMode = TaxMode.exclusive,
    this.serviceRateBp = 0,
    this.serviceTaxable = true,
    this.roundingUnit = 0,
    this.roundingMode = RoundingMode.nearest,
    this.defaultTaxRateBp = 0,
    this.salesType,
  });

  final int version;
  final PriceResult result;
  final List<QuotedLine> lines;

  /// True once the owner has saved business settings in the Backoffice.
  final bool configured;
  final DiscountSpec? billDiscount;
  final TaxMode taxMode;
  final int serviceRateBp;
  final bool serviceTaxable;
  final int roundingUnit;
  final RoundingMode roundingMode;
  final int defaultTaxRateBp;
  final SalesType? salesType;

  bool get isV2 => version == pricingVersionV2;

  /// The configuration the bill was priced with, frozen onto a version 2
  /// order so the server can recompute it. Null for a legacy order, which has
  /// no snapshot to carry and must not pretend to.
  Map<String, Object?>? get pricingSnapshot => isV2
      ? {
          'tax_mode': taxMode.wire,
          'service_rate_bp': serviceRateBp,
          'service_taxable': serviceTaxable,
          'rounding_unit': roundingUnit,
          'rounding_mode': roundingMode.wire,
          if (billDiscount != null) 'bill_discount': billDiscount!.toJson(),
        }
      : null;

  /// Tax the customer sees ADDED on the receipt — the included part is
  /// already inside the item prices.
  int get addedTax => result.tax - result.taxIncluded;
}

/// The rates a till uses before its merchant has configured anything: its
/// own preferences, exactly as before Fase 3.
typedef LegacyRates = ({int taxRateBp, int serviceRateBp});

/// Prices [cart] with the rules in force at the outlet.
///
/// Pure, so it is unit-tested directly. A legacy outlet (or an unconfigured
/// merchant) prices with the version 1 engine — the till's original cart
/// math — and ignores anything only version 2 honours; a version 2 outlet
/// resolves sales-type prices, item discounts, included tax and rounding.
CartQuote computeCartQuote(
  CartState cart,
  PricingContext context, {
  required LegacyRates fallback,
}) {
  final config = context.config;
  // A saved bill prices with what was frozen at its first save (paritas F4),
  // never with whatever the outlet runs by the time it is reopened.
  final frozen = cart.bill?.pricing;
  final v2 = frozen != null ? frozen.version == pricingVersionV2 : context.isV2;
  final salesType = _salesTypeOf(cart, context);

  final taxDefault =
      frozen?.defaultTaxRateBp ?? config?.taxRateBp ?? fallback.taxRateBp;
  final serviceRate =
      frozen?.serviceRateBp ?? config?.serviceRateBp ?? fallback.serviceRateBp;

  final quoted =
      <
        ({int unit, int base, String source, int tax, DiscountSpec? discount})
      >[];
  for (final line in cart.lines) {
    final fixed = line.frozen;
    if (fixed != null) {
      quoted.add((
        unit: fixed.unitPrice,
        base: fixed.basePrice,
        source: fixed.priceSource,
        tax: fixed.taxRateBp,
        discount: v2 ? line.discount : null,
      ));
      continue;
    }
    var base = line.product.price;
    var source = line.custom ? 'custom' : 'base';
    if (v2 && !line.custom && salesType != null) {
      final outlet = context.outletPrices['${line.product.id}|${salesType.id}'];
      final business =
          context.businessPrices['${line.product.id}|${salesType.id}'];
      if (outlet != null) {
        base = outlet;
        source = 'outlet_sales_type';
      } else if (business != null) {
        base = business;
        source = 'sales_type';
      }
    }
    final productRate = line.product.pb1Rate;
    final tax = line.custom || productRate == null
        ? taxDefault
        : (productRate * 100).round();
    quoted.add((
      unit: base + (line.custom ? 0 : line.deltas),
      base: base,
      source: source,
      tax: tax,
      discount: v2 ? line.discount : null,
    ));
  }

  final billDiscount = cart.billDiscount;
  final input = PriceInput(
    version: v2 ? pricingVersionV2 : pricingVersionLegacy,
    taxMode:
        frozen?.taxMode ??
        (v2 ? (config?.taxMode ?? TaxMode.exclusive) : TaxMode.exclusive),
    serviceRateBp: serviceRate,
    serviceTaxable:
        frozen?.serviceTaxable ??
        (v2 ? (config?.serviceTaxable ?? true) : true),
    roundingUnit:
        frozen?.roundingUnit ?? (v2 ? (config?.roundingUnit ?? 0) : 0),
    roundingMode:
        frozen?.roundingMode ?? config?.roundingMode ?? RoundingMode.nearest,
    billDiscount: billDiscount,
    lines: [
      for (var i = 0; i < quoted.length; i++)
        PriceLine(
          unitPrice: quoted[i].unit,
          quantity: cart.lines[i].quantity,
          taxRateBp: quoted[i].tax,
          discount: quoted[i].discount,
        ),
    ],
  );
  final result = computePrice(input);

  return CartQuote(
    version: input.version,
    result: result,
    lines: [
      for (var i = 0; i < quoted.length; i++)
        QuotedLine(
          unitPrice: quoted[i].unit,
          basePrice: quoted[i].base,
          priceSource: quoted[i].source,
          taxRateBp: quoted[i].tax,
          discount: quoted[i].discount,
          result: result.lines[i],
        ),
    ],
    configured: config != null,
    billDiscount: billDiscount,
    taxMode: input.taxMode,
    serviceRateBp: input.serviceRateBp,
    serviceTaxable: input.serviceTaxable,
    roundingUnit: input.roundingUnit,
    roundingMode: input.roundingMode,
    defaultTaxRateBp: taxDefault,
    salesType: salesType,
  );
}

SalesType? _salesTypeOf(CartState cart, PricingContext context) {
  if (cart.salesTypeId != null) {
    for (final t in context.salesTypes) {
      if (t.id == cart.salesTypeId) return t;
    }
    return null;
  }
  for (final t in context.salesTypes) {
    if (t.systemKey == cart.type.name) return t;
  }
  return null;
}

/// The cart, priced. Synchronous: until the pricing context has loaded it
/// prices with the till's own preferences, which is also what an unconfigured
/// merchant gets for good.
final cartQuoteProvider = Provider.autoDispose<CartQuote>((ref) {
  final cart = ref.watch(cartProvider);
  final settings = ref.watch(settingsProvider).valueOrNull;
  final context =
      ref.watch(pricingContextProvider).valueOrNull ?? PricingContext.empty;
  return computeCartQuote(
    cart,
    context,
    fallback: (
      taxRateBp: ((settings?.pb1Rate ?? 0) * 100).round(),
      serviceRateBp: (settings?.serviceChargeEnabled ?? false)
          ? (settings!.serviceChargeRate * 100).round()
          : 0,
    ),
  );
});

/// The merchant's trading clock as the till last read it from its binding,
/// in minutes east of UTC, or null when the server has not said (an older
/// server) or named a zone this build does not know.
int? merchantOffsetMinutes() => timezoneOffsetMinutes(
  TillCoordinator.current?.binding.tenant['timezone'] as String?,
);

/// Who can be named as the server on a bill (Fase 3, track server): active
/// staff whose role opens the POS. A role that cannot sell is not someone a
/// guest was served by.
final serverCandidatesProvider = FutureProvider.autoDispose<List<Employee>>((
  ref,
) async {
  final repo = EmployeeRepository.instance;
  final out = <Employee>[];
  for (final employee in await repo.all(onlyActive: true)) {
    if ((await repo.accessFor(employee)).posAccess) out.add(employee);
  }
  return out;
});
