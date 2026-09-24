import 'dart:convert';

import '../../core/pricing/pricing.dart';

/// Saved bills (v33, paritas F4).
///
/// A bill is what a table runs up before it pays; the receipt (`Order`) is
/// what it becomes when it does. Saving a bill takes no money and moves no
/// stock. Sending lines to the kitchen (a [KitchenDispatch]) is what consumes
/// stock, once; settling writes the receipt and consumes nothing again.
///
/// One till owns a bill at a time. [ownership] says whether this till may
/// edit it; [ownerGeneration] is how the server tells a till that lost the
/// bill from one that still has it.

enum BillStatus {
  open,

  /// Settled by a receipt ([Bill.closedOrderId]).
  closed,
  cancelled;

  String get wire => name;
  static BillStatus fromWire(String? v) =>
      BillStatus.values.firstWhere((e) => e.name == v, orElse: () => open);
}

enum BillOwnership {
  /// This till may edit it.
  owned,

  /// Released to the server for another till — or this one — to claim.
  /// Read-only here until claimed.
  parked;

  String get wire => name;
  static BillOwnership fromWire(String? v) => v == 'owned' ? owned : parked;
}

enum DispatchStatus {
  queued,
  preparing,
  ready,
  served,
  cancelled;

  String get wire => name;

  /// An unknown value reads as queued — never as served, which would let a
  /// table be cleared with food still on its way.
  static DispatchStatus fromWire(String? v) => DispatchStatus.values.firstWhere(
    (e) => e.name == v,
    orElse: () => queued,
  );

  /// The next status the kitchen moves to, or null at the end.
  DispatchStatus? get next => switch (this) {
    queued => preparing,
    preparing => ready,
    ready => served,
    served || cancelled => null,
  };

  bool get isActive => this == queued || this == preparing || this == ready;
}

/// The pricing configuration a bill was first saved with, frozen so a sync
/// that changes a rate never re-prices a bill a guest was already quoted. The
/// bill discount itself stays editable until payment; this records which one
/// is applied and who approved it.
class BillPricing {
  const BillPricing({
    required this.version,
    this.taxMode = TaxMode.exclusive,
    this.serviceRateBp = 0,
    this.serviceTaxable = true,
    this.roundingUnit = 0,
    this.roundingMode = RoundingMode.nearest,
    this.defaultTaxRateBp = 0,
    this.billDiscount,
    this.discountSource = 'none',
    this.promoId,
    this.promoName,
    this.discountId,
    this.discountName,
    this.discountAuthorizedById,
    this.discountAuthorizedByName,
  });

  final int version;
  final TaxMode taxMode;
  final int serviceRateBp;
  final bool serviceTaxable;
  final int roundingUnit;
  final RoundingMode roundingMode;
  final int defaultTaxRateBp;
  final DiscountSpec? billDiscount;

  /// none, promo, manual or named — [DiscountSource] on the cart.
  final String discountSource;
  final String? promoId;
  final String? promoName;
  final String? discountId;
  final String? discountName;
  final String? discountAuthorizedById;
  final String? discountAuthorizedByName;

  Map<String, Object?> toJson() => {
    'version': version,
    'tax_mode': taxMode.wire,
    'service_rate_bp': serviceRateBp,
    'service_taxable': serviceTaxable,
    'rounding_unit': roundingUnit,
    'rounding_mode': roundingMode.wire,
    'default_tax_rate_bp': defaultTaxRateBp,
    if (billDiscount != null) 'bill_discount': billDiscount!.toJson(),
    'discount_source': discountSource,
    'promo_id': promoId,
    'promo_name': promoName,
    'discount_id': discountId,
    'discount_name': discountName,
    'discount_authorized_by_id': discountAuthorizedById,
    'discount_authorized_by_name': discountAuthorizedByName,
  };

  static BillPricing fromJson(Object? json) {
    final m = json is String
        ? jsonDecode(json) as Map<String, dynamic>
        : (json as Map?)?.cast<String, dynamic>() ?? const {};
    int asInt(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;
    return BillPricing(
      version: asInt(m['version'], pricingVersionLegacy),
      taxMode: TaxMode.fromWire(m['tax_mode'] as String?),
      serviceRateBp: asInt(m['service_rate_bp']),
      serviceTaxable: m['service_taxable'] as bool? ?? true,
      roundingUnit: asInt(m['rounding_unit']),
      roundingMode: RoundingMode.fromWire(m['rounding_mode'] as String?),
      defaultTaxRateBp: asInt(m['default_tax_rate_bp']),
      billDiscount: DiscountSpec.fromJson(m['bill_discount']),
      discountSource: m['discount_source'] as String? ?? 'none',
      promoId: m['promo_id'] as String?,
      promoName: m['promo_name'] as String?,
      discountId: m['discount_id'] as String?,
      discountName: m['discount_name'] as String?,
      discountAuthorizedById: m['discount_authorized_by_id'] as String?,
      discountAuthorizedByName: m['discount_authorized_by_name'] as String?,
    );
  }

  BillPricing withDiscount({
    required DiscountSpec? billDiscount,
    required String discountSource,
    String? promoId,
    String? promoName,
    String? discountId,
    String? discountName,
    String? discountAuthorizedById,
    String? discountAuthorizedByName,
  }) => BillPricing(
    version: version,
    taxMode: taxMode,
    serviceRateBp: serviceRateBp,
    serviceTaxable: serviceTaxable,
    roundingUnit: roundingUnit,
    roundingMode: roundingMode,
    defaultTaxRateBp: defaultTaxRateBp,
    billDiscount: billDiscount,
    discountSource: discountSource,
    promoId: promoId,
    promoName: promoName,
    discountId: discountId,
    discountName: discountName,
    discountAuthorizedById: discountAuthorizedById,
    discountAuthorizedByName: discountAuthorizedByName,
  );
}

class BillLineModifier {
  const BillLineModifier({
    this.groupId,
    required this.groupName,
    this.optionId,
    required this.optionName,
    required this.priceDelta,
  });

  final String? groupId;
  final String groupName;
  final String? optionId;
  final String optionName;
  final int priceDelta;

  Map<String, Object?> toJson() => {
    'group_id': groupId,
    'group_name': groupName,
    'option_id': optionId,
    'option_name': optionName,
    'price_delta': priceDelta,
  };

  static BillLineModifier fromJson(Map<String, dynamic> m) => BillLineModifier(
    groupId: m['group_id'] as String?,
    groupName: m['group_name'] as String? ?? '',
    optionId: m['option_id'] as String?,
    optionName: m['option_name'] as String? ?? '',
    priceDelta: (m['price_delta'] as num?)?.toInt() ?? 0,
  );
}

/// One line of a bill, priced when it was added: [unitPrice] already holds
/// the variant and modifier deltas.
class BillLine {
  const BillLine({
    required this.id,
    required this.billId,
    required this.seq,
    this.productId,
    required this.productName,
    this.variantId,
    this.variantName,
    this.modifiers = const [],
    required this.unitPrice,
    this.basePrice,
    this.priceSource,
    this.taxRateBp,
    this.unitCost,
    required this.quantity,
    this.note,
    this.custom = false,
    this.categoryId,
    this.categoryName,
    this.brandId,
    this.discount,
    this.lineDiscountId,
    this.lineDiscountName,
    this.lineDiscountAuthorizedById,
    this.lineDiscountAuthorizedByName,
    this.dispatchId,
    required this.createdAt,
  });

  final String id;
  final String billId;
  final int seq;
  final String? productId;
  final String productName;
  final String? variantId;
  final String? variantName;
  final List<BillLineModifier> modifiers;
  final int unitPrice;
  final int? basePrice;
  final String? priceSource;
  final int? taxRateBp;
  final int? unitCost;
  final int quantity;
  final String? note;
  final bool custom;
  final String? categoryId;
  final String? categoryName;
  final String? brandId;
  final DiscountSpec? discount;
  final String? lineDiscountId;
  final String? lineDiscountName;
  final String? lineDiscountAuthorizedById;
  final String? lineDiscountAuthorizedByName;

  /// The dispatch that sent this line to the kitchen, or null while it has
  /// not gone. A dispatched line never changes again.
  final String? dispatchId;
  final DateTime createdAt;

  bool get dispatched => dispatchId != null;

  String get displayName =>
      variantName == null ? productName : '$productName ($variantName)';

  Map<String, Object?> toMap() => {
    'id': id,
    'bill_id': billId,
    'seq': seq,
    'product_id': productId,
    'product_name': productName,
    'variant_id': variantId,
    'variant_name': variantName,
    'modifiers': jsonEncode([for (final m in modifiers) m.toJson()]),
    'unit_price': unitPrice,
    'base_price': basePrice,
    'price_source': priceSource,
    'tax_rate_bp': taxRateBp,
    'unit_cost': unitCost,
    'quantity': quantity,
    'note': note,
    'custom': custom ? 1 : 0,
    'category_id': categoryId,
    'category_name': categoryName,
    'brand_id': brandId,
    'discount': discount == null ? null : jsonEncode(discount!.toJson()),
    'line_discount_id': lineDiscountId,
    'line_discount_name': lineDiscountName,
    'line_discount_authorized_by_id': lineDiscountAuthorizedById,
    'line_discount_authorized_by_name': lineDiscountAuthorizedByName,
    'dispatch_id': dispatchId,
    'created_at': createdAt.millisecondsSinceEpoch,
  };

  static BillLine fromMap(Map<String, Object?> m) {
    final rawModifiers = m['modifiers'];
    final modifiers = rawModifiers is String && rawModifiers.isNotEmpty
        ? [
            for (final e in jsonDecode(rawModifiers) as List)
              BillLineModifier.fromJson((e as Map).cast<String, dynamic>()),
          ]
        : const <BillLineModifier>[];
    final discount = m['discount'];
    return BillLine(
      id: m['id'] as String,
      billId: m['bill_id'] as String,
      seq: (m['seq'] as num).toInt(),
      productId: m['product_id'] as String?,
      productName: m['product_name'] as String,
      variantId: m['variant_id'] as String?,
      variantName: m['variant_name'] as String?,
      modifiers: modifiers,
      unitPrice: (m['unit_price'] as num).toInt(),
      basePrice: (m['base_price'] as num?)?.toInt(),
      priceSource: m['price_source'] as String?,
      taxRateBp: (m['tax_rate_bp'] as num?)?.toInt(),
      unitCost: (m['unit_cost'] as num?)?.toInt(),
      quantity: (m['quantity'] as num).toInt(),
      note: m['note'] as String?,
      custom: (m['custom'] as num?)?.toInt() == 1,
      categoryId: m['category_id'] as String?,
      categoryName: m['category_name'] as String?,
      brandId: m['brand_id'] as String?,
      discount: discount is String
          ? DiscountSpec.fromJson(jsonDecode(discount))
          : null,
      lineDiscountId: m['line_discount_id'] as String?,
      lineDiscountName: m['line_discount_name'] as String?,
      lineDiscountAuthorizedById:
          m['line_discount_authorized_by_id'] as String?,
      lineDiscountAuthorizedByName:
          m['line_discount_authorized_by_name'] as String?,
      dispatchId: m['dispatch_id'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (m['created_at'] as num).toInt(),
      ),
    );
  }

  /// The line as the contract carries it (`BillLine`). The same shape goes
  /// up inside the bill and inside the dispatch that sends it, and the server
  /// compares the two byte for byte after decoding — so both are built here.
  Map<String, Object?> toWire() => {
    'id': id,
    'seq': seq,
    'product_id': productId,
    'product_name': productName,
    'variant_id': variantId,
    'variant_name': variantName,
    'unit_price': unitPrice,
    'base_price': ?basePrice,
    'price_source': ?priceSource,
    'tax_rate_bp': ?taxRateBp,
    'unit_cost': unitCost,
    'quantity': quantity,
    'note': note,
    'custom': custom,
    'category_id': categoryId,
    'category_name': categoryName,
    'brand_id': brandId,
    if (discount != null) 'discount': discount!.toJson(),
    'line_discount_id': lineDiscountId,
    'line_discount_name': lineDiscountName,
    'line_discount_authorized_by_id': lineDiscountAuthorizedById,
    'line_discount_authorized_by_name': lineDiscountAuthorizedByName,
    'modifiers': [for (final m in modifiers) m.toJson()],
  };

  static BillLine fromWire(
    String billId,
    Map<String, dynamic> m, {
    String? dispatchId,
  }) => BillLine(
    id: m['id'] as String,
    billId: billId,
    seq: (m['seq'] as num?)?.toInt() ?? 0,
    productId: m['product_id'] as String?,
    productName: m['product_name'] as String? ?? '',
    variantId: m['variant_id'] as String?,
    variantName: m['variant_name'] as String?,
    modifiers: [
      for (final e in (m['modifiers'] as List? ?? const []))
        BillLineModifier.fromJson((e as Map).cast<String, dynamic>()),
    ],
    unitPrice: (m['unit_price'] as num).toInt(),
    basePrice: (m['base_price'] as num?)?.toInt(),
    priceSource: m['price_source'] as String?,
    taxRateBp: (m['tax_rate_bp'] as num?)?.toInt(),
    unitCost: (m['unit_cost'] as num?)?.toInt(),
    quantity: (m['quantity'] as num).toInt(),
    note: m['note'] as String?,
    custom: m['custom'] as bool? ?? false,
    categoryId: m['category_id'] as String?,
    categoryName: m['category_name'] as String?,
    brandId: m['brand_id'] as String?,
    discount: DiscountSpec.fromJson(m['discount']),
    lineDiscountId: m['line_discount_id'] as String?,
    lineDiscountName: m['line_discount_name'] as String?,
    lineDiscountAuthorizedById: m['line_discount_authorized_by_id'] as String?,
    lineDiscountAuthorizedByName:
        m['line_discount_authorized_by_name'] as String?,
    dispatchId: dispatchId,
    createdAt: DateTime.now(),
  );
}

/// A batch of lines sent to the kitchen.
class KitchenDispatch {
  const KitchenDispatch({
    required this.id,
    required this.billId,
    required this.status,
    required this.occurredAt,
    required this.statusChangedAt,
    this.employeeId,
    required this.employeeName,
    this.posSessionId,
    this.outletId,
    this.origin = 'device',
  });

  final String id;
  final String billId;
  final DispatchStatus status;
  final DateTime occurredAt;
  final DateTime statusChangedAt;
  final String? employeeId;
  final String employeeName;
  final String? posSessionId;
  final String? outletId;

  /// `device` when this till sent it; `server` when it arrived with a claimed
  /// bill and its stock is already on the server's ledger.
  final String origin;

  Map<String, Object?> toMap() => {
    'id': id,
    'bill_id': billId,
    'status': status.wire,
    'occurred_at': occurredAt.millisecondsSinceEpoch,
    'status_changed_at': statusChangedAt.millisecondsSinceEpoch,
    'employee_id': employeeId,
    'employee_name': employeeName,
    'pos_session_id': posSessionId,
    'outlet_id': outletId,
    'origin': origin,
  };

  static KitchenDispatch fromMap(Map<String, Object?> m) => KitchenDispatch(
    id: m['id'] as String,
    billId: m['bill_id'] as String,
    status: DispatchStatus.fromWire(m['status'] as String?),
    occurredAt: DateTime.fromMillisecondsSinceEpoch(
      (m['occurred_at'] as num).toInt(),
    ),
    statusChangedAt: DateTime.fromMillisecondsSinceEpoch(
      (m['status_changed_at'] as num).toInt(),
    ),
    employeeId: m['employee_id'] as String?,
    employeeName: m['employee_name'] as String? ?? '',
    posSessionId: m['pos_session_id'] as String?,
    outletId: m['outlet_id'] as String?,
    origin: m['origin'] as String? ?? 'device',
  );
}

/// Why and by whom a bill was cancelled.
class BillCancellation {
  const BillCancellation({
    required this.reason,
    required this.authorizedBy,
    this.authorizedById,
    required this.cancelledAt,
    this.decisions = const {},
  });

  final String reason;
  final String authorizedBy;
  final String? authorizedById;
  final DateTime cancelledAt;

  /// For every line already sent to the kitchen: true when it came back to
  /// the shelf (restock), false when it was made and thrown away (waste).
  final Map<String, bool> decisions;

  Map<String, Object?> toJson() => {
    'reason': reason,
    'authorized_by': authorizedBy,
    'authorized_by_id': authorizedById,
    'cancelled_at_ms': cancelledAt.millisecondsSinceEpoch,
    'decisions': {
      for (final e in decisions.entries) e.key: e.value ? 'restock' : 'waste',
    },
  };

  static BillCancellation? fromJson(Object? json) {
    if (json is! String || json.isEmpty) return null;
    final m = jsonDecode(json) as Map<String, dynamic>;
    return BillCancellation(
      reason: m['reason'] as String? ?? '',
      authorizedBy: m['authorized_by'] as String? ?? '',
      authorizedById: m['authorized_by_id'] as String?,
      cancelledAt: DateTime.fromMillisecondsSinceEpoch(
        (m['cancelled_at_ms'] as num?)?.toInt() ?? 0,
      ),
      decisions: {
        for (final e in ((m['decisions'] as Map?) ?? const {}).entries)
          e.key as String: e.value == 'restock',
      },
    );
  }
}

class Bill {
  const Bill({
    required this.id,
    required this.number,
    required this.status,
    this.ownership = BillOwnership.owned,
    this.ownerGeneration = 1,
    this.revision = 0,
    this.outletId,
    this.posId,
    this.posSessionId,
    required this.type,
    this.salesTypeId,
    this.salesTypeName,
    this.tableId,
    this.tableName,
    this.tableSessionId,
    this.customerId,
    this.customerName,
    this.servedById,
    this.servedByName,
    this.note,
    this.createdById,
    required this.createdByName,
    required this.pricing,
    required this.openedAt,
    required this.updatedAt,
    this.closedOrderId,
    this.closedAt,
    this.cancellation,
    this.lines = const [],
    this.dispatches = const [],
  });

  final String id;
  final String number;
  final BillStatus status;
  final BillOwnership ownership;
  final int ownerGeneration;
  final int revision;
  final String? outletId;
  final String? posId;
  final String? posSessionId;

  /// The order type wire value (`dineIn`, `takeaway`, …).
  final String type;
  final String? salesTypeId;
  final String? salesTypeName;
  final String? tableId;
  final String? tableName;
  final String? tableSessionId;
  final String? customerId;
  final String? customerName;
  final String? servedById;
  final String? servedByName;
  final String? note;
  final String? createdById;
  final String createdByName;
  final BillPricing pricing;
  final DateTime openedAt;
  final DateTime updatedAt;
  final String? closedOrderId;
  final DateTime? closedAt;
  final BillCancellation? cancellation;
  final List<BillLine> lines;
  final List<KitchenDispatch> dispatches;

  bool get isOpen => status == BillStatus.open;
  bool get isEditable => isOpen && ownership == BillOwnership.owned;
  int get subtotal => lines.fold(0, (a, l) => a + l.unitPrice * l.quantity);
  int get itemCount => lines.fold(0, (a, l) => a + l.quantity);
  Iterable<BillLine> get pendingLines => lines.where((l) => !l.dispatched);
  bool get hasActiveDispatch => dispatches.any((d) => d.status.isActive);

  /// What the list and the table board call it.
  String get label => tableName?.isNotEmpty == true
      ? tableName!
      : customerName?.isNotEmpty == true
      ? customerName!
      : number;

  Map<String, Object?> toMap() => {
    'id': id,
    'number': number,
    'status': status.wire,
    'ownership': ownership.wire,
    'owner_generation': ownerGeneration,
    'revision': revision,
    'outlet_id': outletId,
    'pos_id': posId,
    'pos_session_id': posSessionId,
    'type': type,
    'sales_type_id': salesTypeId,
    'sales_type_name': salesTypeName,
    'table_id': tableId,
    'table_name': tableName,
    'table_session_id': tableSessionId,
    'customer_id': customerId,
    'customer_name': customerName,
    'served_by_id': servedById,
    'served_by_name': servedByName,
    'note': note,
    'created_by_id': createdById,
    'created_by_name': createdByName,
    'pricing': jsonEncode(pricing.toJson()),
    'opened_at': openedAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'closed_order_id': closedOrderId,
    'closed_at': closedAt?.millisecondsSinceEpoch,
    'cancel': cancellation == null ? null : jsonEncode(cancellation!.toJson()),
  };

  static Bill fromMap(
    Map<String, Object?> m, {
    List<BillLine> lines = const [],
    List<KitchenDispatch> dispatches = const [],
  }) => Bill(
    id: m['id'] as String,
    number: m['number'] as String,
    status: BillStatus.fromWire(m['status'] as String?),
    ownership: BillOwnership.fromWire(m['ownership'] as String?),
    ownerGeneration: (m['owner_generation'] as num?)?.toInt() ?? 1,
    revision: (m['revision'] as num?)?.toInt() ?? 0,
    outletId: m['outlet_id'] as String?,
    posId: m['pos_id'] as String?,
    posSessionId: m['pos_session_id'] as String?,
    type: m['type'] as String? ?? 'dineIn',
    salesTypeId: m['sales_type_id'] as String?,
    salesTypeName: m['sales_type_name'] as String?,
    tableId: m['table_id'] as String?,
    tableName: m['table_name'] as String?,
    tableSessionId: m['table_session_id'] as String?,
    customerId: m['customer_id'] as String?,
    customerName: m['customer_name'] as String?,
    servedById: m['served_by_id'] as String?,
    servedByName: m['served_by_name'] as String?,
    note: m['note'] as String?,
    createdById: m['created_by_id'] as String?,
    createdByName: m['created_by_name'] as String? ?? '',
    pricing: BillPricing.fromJson(m['pricing']),
    openedAt: DateTime.fromMillisecondsSinceEpoch(
      (m['opened_at'] as num).toInt(),
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (m['updated_at'] as num).toInt(),
    ),
    closedOrderId: m['closed_order_id'] as String?,
    closedAt: m['closed_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((m['closed_at'] as num).toInt()),
    cancellation: BillCancellation.fromJson(m['cancel']),
    lines: lines,
    dispatches: dispatches,
  );
}

/// One seating at one table: opened when guests sit, closed when staff clear
/// the table. Paying a bill never closes it.
class TableSeating {
  const TableSeating({
    required this.id,
    required this.tableId,
    required this.tableName,
    this.outletId,
    this.guestCount,
    required this.openedAt,
    this.openedByName,
    this.closedAt,
  });

  final String id;
  final String tableId;
  final String tableName;
  final String? outletId;
  final int? guestCount;
  final DateTime openedAt;
  final String? openedByName;
  final DateTime? closedAt;

  bool get isOpen => closedAt == null;

  Map<String, Object?> toMap() => {
    'id': id,
    'table_id': tableId,
    'table_name': tableName,
    'outlet_id': outletId,
    'guest_count': guestCount,
    'opened_at': openedAt.millisecondsSinceEpoch,
    'opened_by_name': openedByName,
    'closed_at': closedAt?.millisecondsSinceEpoch,
  };

  static TableSeating fromMap(Map<String, Object?> m) => TableSeating(
    id: m['id'] as String,
    tableId: m['table_id'] as String,
    tableName: m['table_name'] as String? ?? '',
    outletId: m['outlet_id'] as String?,
    guestCount: (m['guest_count'] as num?)?.toInt(),
    openedAt: DateTime.fromMillisecondsSinceEpoch(
      (m['opened_at'] as num).toInt(),
    ),
    openedByName: m['opened_by_name'] as String?,
    closedAt: m['closed_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((m['closed_at'] as num).toInt()),
  );

  /// A seating as `GET /till/bills` or `POST /till/table-sessions` return it.
  static TableSeating fromWire(Map<String, dynamic> m, {String? outletId}) =>
      TableSeating(
        id: m['id'] as String,
        tableId: m['table_id'] as String,
        tableName: m['table_name'] as String? ?? '',
        outletId: outletId,
        guestCount: (m['guest_count'] as num?)?.toInt(),
        openedAt: DateTime.fromMillisecondsSinceEpoch(
          (m['opened_at_ms'] as num).toInt(),
        ),
        openedByName: m['opened_by_name'] as String?,
        closedAt: m['closed_at_ms'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (m['closed_at_ms'] as num).toInt(),
              ),
      );
}
