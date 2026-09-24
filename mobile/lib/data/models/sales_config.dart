import '../../core/pricing/pricing.dart';

/// A sales type as the till offers it (Fase 3). The three built-in ones carry
/// the [systemKey] an order's wire `type` has always used; a merchant's own
/// type ("GoFood") has none and travels as `custom` plus its id and name.
class SalesType {
  const SalesType({
    required this.id,
    required this.name,
    required this.usesTable,
    required this.active,
    this.systemKey,
  });
  final String id;
  final String name;
  final String? systemKey;
  final bool usesTable;
  final bool active;

  bool get isCustom => systemKey == null;

  factory SalesType.fromMap(Map<String, Object?> row) => SalesType(
    id: row['id']! as String,
    name: row['name']! as String,
    systemKey: row['system_key'] as String?,
    usesTable: (row['uses_table'] as int? ?? 0) == 1,
    active: (row['active'] as int? ?? 1) == 1,
  );
}

/// A payment method as the till offers it. [kind] is what the order's wire
/// `payment_method` carries, and what every drawer figure compares to cash.
class PaymentMethodConfig {
  const PaymentMethodConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.requiresReference,
    this.systemKey,
  });
  final String id;
  final String name;
  final String kind;
  final String? systemKey;
  final bool requiresReference;

  bool get isCash => kind == 'cash';

  factory PaymentMethodConfig.fromMap(Map<String, Object?> row) =>
      PaymentMethodConfig(
        id: row['id']! as String,
        name: row['name']! as String,
        kind: row['kind']! as String,
        systemKey: row['system_key'] as String?,
        requiresReference: (row['requires_reference'] as int? ?? 0) == 1,
      );
}

/// A named discount from the Backoffice. [value] null means the cashier types
/// the amount, which always needs applyManualDiscount; a percent value is in
/// basis points.
class DiscountConfig {
  const DiscountConfig({
    required this.id,
    required this.name,
    required this.scope,
    required this.kind,
    required this.requiresAuthorization,
    this.value,
  });
  final String id;
  final String name;

  /// `bill` or `item`.
  final String scope;
  final DiscountKind kind;
  final int? value;
  final bool requiresAuthorization;

  bool get isItem => scope == 'item';
  bool get needsApproval => requiresAuthorization || value == null;

  DiscountSpec? get spec => value == null ? null : DiscountSpec(kind, value!);

  static DiscountConfig? fromMap(Map<String, Object?> row) {
    final kind = DiscountKind.tryWire(row['kind'] as String?);
    if (kind == null) return null;
    return DiscountConfig(
      id: row['id']! as String,
      name: row['name']! as String,
      scope: (row['scope'] as String?) ?? 'bill',
      kind: kind,
      value: (row['value'] as num?)?.toInt(),
      requiresAuthorization: (row['requires_authorization'] as int? ?? 0) == 1,
    );
  }
}

/// The business configuration in force at one outlet: the outlet's overrides
/// on top of the merchant's defaults. Only exists once the owner has saved
/// the business settings in the Backoffice — until then a till keeps the
/// values in its own preferences (see SalesConfigRepository.context).
class EffectiveBusinessConfig {
  const EffectiveBusinessConfig({
    required this.pricingVersion,
    required this.taxRateBp,
    required this.taxMode,
    required this.serviceRateBp,
    required this.serviceTaxable,
    required this.roundingUnit,
    required this.roundingMode,
    this.receiptLogoUrl,
    this.receiptHeader,
    this.receiptFooter,
    this.showAddress = true,
    this.showPhone = true,
    this.trackServer = false,
    this.defaultSalesTypeId,
  });
  final int pricingVersion;
  final int taxRateBp;
  final TaxMode taxMode;

  /// Zero when the service charge is switched off, whatever rate is stored.
  final int serviceRateBp;
  final bool serviceTaxable;
  final int roundingUnit;
  final RoundingMode roundingMode;
  final String? receiptLogoUrl;
  final String? receiptHeader;
  final String? receiptFooter;
  final bool showAddress;
  final bool showPhone;
  final bool trackServer;
  final String? defaultSalesTypeId;

  bool get isV2 => pricingVersion == pricingVersionV2;
}
