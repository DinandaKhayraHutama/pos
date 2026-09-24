import '../../core/pricing/pricing.dart';
import '../database/app_database.dart';
import '../models/sales_config.dart';

/// Everything the till needs to price a bill at one outlet, read in one go
/// from the pulled Fase 3 feeds.
///
/// What an outlet may use depends on its pricing model. The version 2 engine
/// is switched on per outlet in the Backoffice, and only once every till of
/// the branch can run it; until then the outlet is legacy, and none of what
/// only version 2 honours is offered here — merchant sales types, sales-type
/// prices, item discounts, and the ewallet/transfer/other payment kinds. An
/// older till never sees them, so neither does a newer one at a legacy outlet;
/// two tills in one shop always charge alike.
class PricingContext {
  const PricingContext({
    this.config,
    this.salesTypes = const [],
    this.paymentMethods = const [],
    this.discounts = const [],
    this.businessPrices = const {},
    this.outletPrices = const {},
    this.billModelV1 = false,
  });

  /// Null until the owner has saved the business settings.
  final EffectiveBusinessConfig? config;
  final List<SalesType> salesTypes;
  final List<PaymentMethodConfig> paymentMethods;
  final List<DiscountConfig> discounts;

  /// `productId|salesTypeId` → price.
  final Map<String, int> businessPrices;
  final Map<String, int> outletPrices;

  /// Whether the outlet runs saved bills (paritas F4). Only read on an
  /// activated till; the demo always runs them.
  final bool billModelV1;

  static const empty = PricingContext();

  bool get isV2 => config?.isV2 ?? false;
  bool get trackServer => config?.trackServer ?? false;

  /// The resolved base price of a product for a sales type: the outlet's
  /// override, then the business's, then null for "use the product price".
  int? priceFor(String productId, String salesTypeId) {
    final key = '$productId|$salesTypeId';
    return outletPrices[key] ?? businessPrices[key];
  }
}

class SalesConfigRepository {
  SalesConfigRepository._();
  static final instance = SalesConfigRepository._();

  static const _legacyKinds = {'cash', 'card', 'qris'};

  Future<PricingContext> context(String outletId) async {
    final config = await effective(outletId);
    final v2 = config?.isV2 ?? false;
    final db = await AppDatabase.instance.db;

    final outletRows = await db.query(
      'outlet_settings',
      columns: ['sales_type_ids', 'payment_group_id', 'bill_model'],
      where: 'outlet_id = ?',
      whereArgs: [outletId],
      limit: 1,
    );
    final outlet = outletRows.isEmpty
        ? const <String, Object?>{}
        : outletRows.first;

    final allowedTypes = _ids(outlet['sales_type_ids'] as String?);
    final salesTypes =
        [
          for (final row in await db.query(
            'sales_types',
            where: 'active = 1',
            orderBy: 'sort_order, name',
          ))
            SalesType.fromMap(row),
        ].where((t) {
          if (!v2 && t.isCustom) return false;
          return allowedTypes == null || allowedTypes.contains(t.id);
        }).toList();

    Set<String>? allowedMethods;
    final groupId = outlet['payment_group_id'] as String?;
    if (groupId != null && groupId.isNotEmpty) {
      final groups = await db.query(
        'payment_groups',
        columns: ['method_ids'],
        where: 'id = ? AND active = 1',
        whereArgs: [groupId],
        limit: 1,
      );
      if (groups.isNotEmpty) {
        allowedMethods = _ids(groups.first['method_ids'] as String?);
      }
    }
    final paymentMethods =
        [
          for (final row in await db.query(
            'payment_methods',
            where: 'active = 1',
            orderBy: 'sort_order, name',
          ))
            PaymentMethodConfig.fromMap(row),
        ].where((m) {
          if (!v2 && !_legacyKinds.contains(m.kind)) return false;
          return allowedMethods == null || allowedMethods.contains(m.id);
        }).toList();

    final discounts = [
      for (final row in await db.query(
        'discounts',
        where: 'active = 1',
        orderBy: 'sort_order, name',
      ))
        ?DiscountConfig.fromMap(row),
    ].where((d) => v2 || !d.isItem).toList();

    final businessPrices = <String, int>{};
    final outletPrices = <String, int>{};
    if (v2) {
      for (final row in await db.query('product_sales_type_prices')) {
        businessPrices['${row['product_id']}|${row['sales_type_id']}'] =
            (row['price'] as num).toInt();
      }
      for (final row in await db.query(
        'outlet_product_sales_type_prices',
        where: 'outlet_id = ?',
        whereArgs: [outletId],
      )) {
        outletPrices['${row['product_id']}|${row['sales_type_id']}'] =
            (row['price'] as num).toInt();
      }
    }

    return PricingContext(
      billModelV1: outlet['bill_model'] == 'v1',
      config: config,
      salesTypes: salesTypes,
      paymentMethods: paymentMethods,
      discounts: discounts,
      businessPrices: businessPrices,
      outletPrices: outletPrices,
    );
  }

  /// The configuration in force at [outletId], or null while the merchant has
  /// never saved its business settings. An outlet override that is null
  /// inherits; zero is a real override.
  Future<EffectiveBusinessConfig?> effective(String outletId) async {
    final db = await AppDatabase.instance.db;
    final businesses = await db.query('business_settings', limit: 1);
    if (businesses.isEmpty) return null;
    final business = businesses.first;
    final outlets = await db.query(
      'outlet_settings',
      where: 'outlet_id = ?',
      whereArgs: [outletId],
      limit: 1,
    );
    final outlet = outlets.isEmpty ? const <String, Object?>{} : outlets.first;
    Object? pick(String name) => outlet[name] ?? business[name];
    int intOf(String name, int fallback) =>
        (pick(name) as num?)?.toInt() ?? fallback;
    bool boolOf(String name, bool fallback) {
      final v = pick(name);
      return v == null ? fallback : (v as num).toInt() == 1;
    }

    final serviceEnabled = boolOf('service_enabled', false);
    return EffectiveBusinessConfig(
      pricingVersion: outlet['pricing_model'] == 'v2'
          ? pricingVersionV2
          : pricingVersionLegacy,
      taxRateBp: intOf('tax_rate_bp', 0),
      taxMode: TaxMode.fromWire(pick('tax_mode') as String?),
      serviceRateBp: serviceEnabled ? intOf('service_rate_bp', 0) : 0,
      serviceTaxable: boolOf('service_taxable', true),
      roundingUnit: intOf('rounding_unit', 0),
      roundingMode: RoundingMode.fromWire(pick('rounding_mode') as String?),
      receiptLogoUrl: business['receipt_logo_url'] as String?,
      receiptHeader: outlet['receipt_header'] as String?,
      receiptFooter:
          (outlet['receipt_footer'] ?? business['receipt_footer']) as String?,
      showAddress: ((outlet['show_address'] as num?)?.toInt() ?? 1) == 1,
      showPhone: ((outlet['show_phone'] as num?)?.toInt() ?? 1) == 1,
      trackServer: ((outlet['track_server'] as num?)?.toInt() ?? 0) == 1,
      defaultSalesTypeId: outlet['default_sales_type_id'] as String?,
    );
  }

  static Set<String>? _ids(String? csv) =>
      csv?.split(',').where((id) => id.isNotEmpty).toSet();
}
