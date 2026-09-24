import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/pricing/pricing.dart';
import '../data/models/bill.dart';
import '../data/models/enums.dart';
import '../data/models/modifier_group.dart';
import '../data/models/modifier_option.dart';
import '../data/models/product.dart';
import '../data/models/product_variant.dart';
import '../data/models/promo.dart';
import '../data/models/sales_config.dart';
import '../data/models/table.dart';

/// One selected modifier option, paired with the group it came from — the
/// group is carried alongside rather than looked up later because the cart
/// needs its label (for the summary line under a cart tile) and its
/// [ModifierGroup.selectionType]/[ModifierGroup.maxSelect] (for re-opening
/// the picker to edit) without another query.
typedef SelectedModifier = ({ModifierGroup group, ModifierOption option});

/// Prefix of the synthetic product id a custom-amount line carries (Fase 3).
/// It matches no catalogue row, so the line never moves stock, and it is not
/// a UUID, so it goes up to the server as a null product_id.
const customLinePrefix = 'custom:';

/// Who approved a discount: both halves, because the id is what an audit
/// reads and the name is what a receipt prints.
typedef Approver = ({String? id, String name});

/// A line's price as it was frozen when its bill was saved (paritas F4). A
/// sync that changes the catalogue price, the sales-type price or the tax rate
/// never re-prices a line a guest was already quoted.
class FrozenLinePrice {
  const FrozenLinePrice({
    required this.unitPrice,
    required this.basePrice,
    required this.priceSource,
    required this.taxRateBp,
    this.unitCost,
  });

  final int unitPrice;
  final int basePrice;
  final String priceSource;
  final int taxRateBp;
  final int? unitCost;
}

/// The saved bill the cart is editing (paritas F4). Null for a cart that was
/// never saved.
class BillEditing {
  const BillEditing({
    required this.id,
    required this.number,
    required this.revision,
    required this.pricing,
    required this.openedAt,
    this.dispatchCount = 0,
  });

  final String id;
  final String number;
  final int revision;

  /// The configuration frozen at the first save; the quote prices with it
  /// instead of whatever the outlet runs now.
  final BillPricing pricing;
  final DateTime openedAt;
  final int dispatchCount;
}

/// A line in the active cart. Lives in memory until checkout.
class CartLine {
  final Product product;

  /// Chosen variant, or null when the product has none.
  final ProductVariant? variant;

  /// Modifiers picked on this line — one entry per selected OPTION, so a
  /// "multiple" group with two picks contributes two entries sharing the
  /// same `group`.
  final List<SelectedModifier> modifiers;

  final int quantity;
  final String? note;

  /// A discount on this line only (Fase 3, version 2 outlets). Taken before
  /// the bill discount is shared out.
  final DiscountSpec? discount;
  final String? discountId;
  final String? discountName;
  final Approver? discountApprovedBy;

  /// A custom amount typed at the till: [product] is synthetic, sold once at
  /// the typed price, with no stock behind it.
  final bool custom;

  /// The bill line this is, once its bill was saved (paritas F4).
  final String? billLineId;

  /// Its price as frozen at that save.
  final FrozenLinePrice? frozen;

  /// Whether the kitchen has it. A dispatched line never changes again: not
  /// its quantity, its choices, its note or its discount.
  final bool dispatched;

  const CartLine({
    required this.product,
    required this.quantity,
    this.variant,
    this.modifiers = const [],
    this.note,
    this.discount,
    this.discountId,
    this.discountName,
    this.discountApprovedBy,
    this.custom = false,
    this.billLineId,
    this.frozen,
    this.dispatched = false,
  });

  /// Identity for merging. A Large and a Regular of the same coffee are two
  /// lines, not one with quantity 2 — they cost different amounts and print
  /// as different rows on the kitchen ticket. The same reasoning extends to
  /// modifiers: "Extra Spicy" and "Mild" nasi goreng are two lines. Sorted so
  /// picking the same two toppings in either order still merges into one.
  ///
  /// A saved line is its own identity: an item added later is priced at the
  /// catalogue as it is then, so it never folds into a line frozen earlier.
  String get key {
    if (billLineId != null) return 'line:$billLineId';
    final variantPart = variant == null ? '' : '#${variant!.id}';
    final modifierPart = modifiers.isEmpty
        ? ''
        : '#${(modifiers.map((m) => m.option.id).toList()..sort()).join(',')}';
    return '${product.id}$variantPart$modifierPart';
  }

  /// Base price, plus the variant's delta, plus every selected modifier's
  /// delta — or, for a saved line, the price it was frozen at.
  int get unitPrice => frozen?.unitPrice ?? product.price + deltas;

  /// Variant plus modifier deltas — what is added, exactly once, to whatever
  /// base price the sales type resolves to.
  int get deltas =>
      (variant?.priceDelta ?? 0) +
      modifiers.fold(0, (a, m) => a + m.option.priceDelta);

  int get lineTotal => unitPrice * quantity;

  String get displayName =>
      variant == null ? product.name : '${product.name} (${variant!.name})';

  CartLine copyWith({
    int? quantity,
    String? note,
    bool clearNote = false,
    DiscountSpec? discount,
    String? discountId,
    String? discountName,
    Approver? discountApprovedBy,
    bool clearDiscount = false,
  }) => CartLine(
    product: product,
    variant: variant,
    modifiers: modifiers,
    quantity: quantity ?? this.quantity,
    note: clearNote ? null : (note ?? this.note),
    discount: clearDiscount ? null : (discount ?? this.discount),
    discountId: clearDiscount ? null : (discountId ?? this.discountId),
    discountName: clearDiscount ? null : (discountName ?? this.discountName),
    discountApprovedBy: clearDiscount
        ? null
        : (discountApprovedBy ?? this.discountApprovedBy),
    custom: custom,
    billLineId: billLineId,
    frozen: frozen,
    dispatched: dispatched,
  );
}

/// How the cart's discount was decided.
enum DiscountSource {
  none,

  /// A promotion the owner configured. Any cashier may apply it.
  promo,

  /// Typed in by hand. Requires a manager or owner to approve, and the
  /// approver's name is kept in [CartState.discountAuthorizedBy].
  manual,

  /// A named discount from the Backoffice (Fase 3). Needs approval only when
  /// its value is typed at the till or the owner flagged it.
  named,
}

class CartState {
  const CartState({
    this.lines = const [],
    this.type = OrderType.dineIn,
    this.table,
    this.customerName,
    this.customerId,
    this.note,
    this.discountSource = DiscountSource.none,
    this.promo,
    this.manualDiscountPercent = 0,
    this.manualDiscountAmount = 0,
    this.discountAuthorizedBy,
    this.discountAuthorizedById,
    this.namedDiscountId,
    this.namedDiscountName,
    this.namedDiscount,
    this.salesTypeId,
    this.salesTypeName,
    this.servedById,
    this.servedByName,
    this.bill,
    this.tableSessionId,
  });

  final List<CartLine> lines;
  final OrderType type;
  final RestaurantTable? table;
  final String? customerName;
  final String? customerId;
  final String? note;

  final DiscountSource discountSource;

  /// The applied promotion, when [discountSource] is promo.
  final Promo? promo;

  /// Manual discount, one of the two. A percentage takes precedence when both
  /// are somehow set, but the UI only ever sets one.
  final int manualDiscountPercent; // 0-100
  final int manualDiscountAmount;

  /// Who approved the manual or named discount. Null for promos, which need
  /// nobody. Kept apart from the promo's name: a receipt says what the
  /// discount WAS, and the audit says who allowed it.
  final String? discountAuthorizedBy;
  final String? discountAuthorizedById;

  /// The named discount, when [discountSource] is named, and its value as
  /// applied (a typed value included).
  final String? namedDiscountId;
  final String? namedDiscountName;
  final DiscountSpec? namedDiscount;

  /// The sales type picked at the till, or null for the one [type] names.
  final String? salesTypeId;
  final String? salesTypeName;

  /// Who served the table, when the outlet tracks it — never assumed to be
  /// the cashier taking the money.
  final String? servedById;
  final String? servedByName;

  /// The saved bill being edited, or null for a cart never saved (paritas
  /// F4).
  final BillEditing? bill;

  /// The table seating the bill belongs to — opened online when the table
  /// was picked, so two tills cannot seat the same table.
  final String? tableSessionId;

  bool get isEmpty => lines.isEmpty;
  bool get isBill => bill != null;

  /// Lines the kitchen does not have yet.
  int get pendingCount =>
      lines.where((l) => !l.dispatched).fold(0, (a, l) => a + l.quantity);
  bool get hasDispatched => lines.any((l) => l.dispatched);
  int get itemCount => lines.fold(0, (a, l) => a + l.quantity);

  int get subtotal => lines.fold(0, (a, l) => a + l.lineTotal);

  bool get hasLineDiscounts => lines.any((l) => l.discount != null);
  bool get hasCustomLines => lines.any((l) => l.custom);

  /// The bill discount as a specification the pricing engine understands.
  DiscountSpec? get billDiscount => switch (discountSource) {
    DiscountSource.none => null,
    DiscountSource.promo =>
      promo == null
          ? null
          : promo!.kind == PromoKind.percent
          ? DiscountSpec.percent(promo!.value)
          : DiscountSpec.amount(promo!.value),
    DiscountSource.manual =>
      manualDiscountPercent > 0
          ? DiscountSpec.percent(manualDiscountPercent)
          : DiscountSpec.amount(manualDiscountAmount),
    DiscountSource.named => namedDiscount,
  };

  /// The money taken off this bill.
  ///
  /// Always clamped to the subtotal: a Rp 50.000 voucher against a Rp 20.000
  /// bill takes it to zero, never to a negative total the cashier would have
  /// to hand over as change.
  int get discountAmount {
    final raw = switch (discountSource) {
      DiscountSource.none => 0,
      DiscountSource.promo => promo?.discountFor(subtotal) ?? 0,
      DiscountSource.manual =>
        manualDiscountPercent > 0
            ? (subtotal * manualDiscountPercent) ~/ 100
            : manualDiscountAmount,
      DiscountSource.named => switch (namedDiscount) {
        null => 0,
        final d when d.kind == DiscountKind.percent =>
          (subtotal * d.value) ~/ maxRateBp,
        final d => d.value,
      },
    };
    return raw.clamp(0, subtotal);
  }

  /// Human label for the applied discount, or null when there is none.
  String? get discountLabel => switch (discountSource) {
    DiscountSource.none => null,
    DiscountSource.promo => promo?.name,
    DiscountSource.manual =>
      manualDiscountPercent > 0 ? '$manualDiscountPercent%' : null,
    DiscountSource.named => namedDiscountName,
  };

  /// Basis before Service Charge and PB1: subtotal minus discount.
  int get taxableBase => subtotal - discountAmount;

  /// Service Charge: one flat calculation over the whole basket — unlike
  /// PB1 there is no per-product override, since a service charge is a
  /// blanket restaurant policy, not a tax classification — rounded
  /// half-up ONCE, matching PB1's own rounding convention. [rate] is 0 both
  /// when the feature is off and when it's configured to 0%; the caller
  /// resolves `settings.serviceChargeEnabled` into that before calling in.
  ///
  /// The legacy (version 1) cart math, kept verbatim: it is what
  /// `test/cart/cart_math_test.dart` pins and what the shared pricing vectors
  /// port as `legacy_v1.json`. Checkout prices through lib/core/pricing.
  int serviceChargeFor(double rate) {
    final base = taxableBase;
    if (base <= 0 || rate <= 0) return 0;
    return (base * rate / 100).round();
  }

  /// PB1, computed per line so per-product rates are honoured.
  ///
  /// A single rate over the whole basket would be wrong the moment one item
  /// is zero-rated: the discount has to be shared across the lines first, in
  /// proportion to what each contributed, and only then taxed at its own
  /// rate. [pb1Rate] is the fallback for products that carry none.
  ///
  /// PB1's base also includes Service Charge — confirmed calculation order:
  /// Service Charge is computed first on (Subtotal − Discount), and PB1
  /// taxes (Subtotal − Discount + Service Charge), matching how an
  /// Indonesian restaurant receipt taxes the full amount a customer pays
  /// for F&B service, service charge included. So the service charge
  /// amount is shared across lines exactly like the discount already is —
  /// proportional to each line's share of the subtotal — before that
  /// line's own rate is applied.
  ///
  /// Rounding is per line and then summed, which is what a receipt showing a
  /// per-line breakdown has to do to add up.
  int pb1For({required double pb1Rate, required double serviceChargeRate}) {
    final sub = subtotal;
    if (sub <= 0) return 0;
    final discount = discountAmount;
    final serviceCharge = serviceChargeFor(serviceChargeRate);
    var tax = 0;
    for (final l in lines) {
      final discountShare = discount == 0 ? 0 : (discount * l.lineTotal) ~/ sub;
      final serviceChargeShare = serviceCharge == 0
          ? 0
          : (serviceCharge * l.lineTotal) ~/ sub;
      final base = l.lineTotal - discountShare + serviceChargeShare;
      final rate = l.product.effectivePb1Rate(pb1Rate);
      if (rate == 0) continue;
      tax += (base * rate / 100).round();
    }
    return tax;
  }

  /// = taxableBase + serviceCharge + pb1.
  int totalFor({required double pb1Rate, required double serviceChargeRate}) =>
      taxableBase +
      serviceChargeFor(serviceChargeRate) +
      pb1For(pb1Rate: pb1Rate, serviceChargeRate: serviceChargeRate);

  CartState copyWith({
    List<CartLine>? lines,
    OrderType? type,
    RestaurantTable? table,
    String? customerName,
    String? customerId,
    String? note,
    String? salesTypeId,
    String? salesTypeName,
    String? servedById,
    String? servedByName,
    bool clearTable = false,
    bool clearCustomer = false,
    bool clearNote = false,
    bool clearDiscount = false,
    bool clearSalesType = false,
    bool clearServedBy = false,
    BillEditing? bill,
    String? tableSessionId,
    bool clearTableSession = false,
  }) => CartState(
    lines: lines ?? this.lines,
    type: type ?? this.type,
    table: clearTable ? null : (table ?? this.table),
    customerName: clearCustomer ? null : (customerName ?? this.customerName),
    customerId: clearCustomer ? null : (customerId ?? this.customerId),
    note: clearNote ? null : (note ?? this.note),
    discountSource: clearDiscount ? DiscountSource.none : discountSource,
    promo: clearDiscount ? null : promo,
    manualDiscountPercent: clearDiscount ? 0 : manualDiscountPercent,
    manualDiscountAmount: clearDiscount ? 0 : manualDiscountAmount,
    discountAuthorizedBy: clearDiscount ? null : discountAuthorizedBy,
    discountAuthorizedById: clearDiscount ? null : discountAuthorizedById,
    namedDiscountId: clearDiscount ? null : namedDiscountId,
    namedDiscountName: clearDiscount ? null : namedDiscountName,
    namedDiscount: clearDiscount ? null : namedDiscount,
    salesTypeId: clearSalesType ? null : (salesTypeId ?? this.salesTypeId),
    salesTypeName: clearSalesType
        ? null
        : (salesTypeName ?? this.salesTypeName),
    servedById: clearServedBy ? null : (servedById ?? this.servedById),
    servedByName: clearServedBy ? null : (servedByName ?? this.servedByName),
    bill: bill ?? this.bill,
    // A seating belongs to its table: clearing the table clears it too.
    tableSessionId: clearTableSession || clearTable
        ? null
        : (tableSessionId ?? this.tableSessionId),
  );

  /// This cart with a different bill discount and everything else kept.
  /// Switching discount kinds has to CLEAR the other one, which `copyWith`'s
  /// null-means-keep convention cannot express.
  CartState _withDiscount({
    required DiscountSource source,
    Promo? promo,
    int manualPercent = 0,
    int manualAmount = 0,
    Approver? approvedBy,
    String? namedId,
    String? namedName,
    DiscountSpec? named,
  }) => CartState(
    lines: lines,
    type: type,
    table: table,
    customerName: customerName,
    customerId: customerId,
    note: note,
    discountSource: source,
    promo: promo,
    manualDiscountPercent: manualPercent,
    manualDiscountAmount: manualAmount,
    discountAuthorizedBy: approvedBy?.name,
    discountAuthorizedById: approvedBy?.id,
    namedDiscountId: namedId,
    namedDiscountName: namedName,
    namedDiscount: named,
    salesTypeId: salesTypeId,
    salesTypeName: salesTypeName,
    servedById: servedById,
    servedByName: servedByName,
    bill: bill,
    tableSessionId: tableSessionId,
  );
}

class CartNotifier extends StateNotifier<CartState> {
  CartNotifier() : super(const CartState());

  void add(
    Product product, {
    int qty = 1,
    ProductVariant? variant,
    List<SelectedModifier> modifiers = const [],
    String? note,
  }) {
    // Built once so `.key` (which already knows how to fold variant +
    // modifiers into one identity string) is the single source of truth for
    // whether this merges into an existing line or starts a new one.
    final candidate = CartLine(
      product: product,
      variant: variant,
      modifiers: modifiers,
      quantity: qty,
      note: note,
    );
    final existing = state.lines.indexWhere((l) => l.key == candidate.key);
    List<CartLine> lines;
    if (existing >= 0) {
      lines = [...state.lines];
      lines[existing] = lines[existing].copyWith(
        quantity: lines[existing].quantity + qty,
      );
    } else {
      lines = [...state.lines, candidate];
    }
    state = state.copyWith(lines: lines);
  }

  /// Adds a custom amount — a line typed at the till with no product behind
  /// it (Fase 3). Always its own line: two custom amounts are two things the
  /// cashier typed, never one with quantity two.
  void addCustomAmount({required String label, required int amount}) {
    final line = CartLine(
      product: Product(
        id: '$customLinePrefix${const Uuid().v4()}',
        name: label.trim(),
        categoryId: '',
        price: amount,
      ),
      quantity: 1,
      custom: true,
    );
    state = state.copyWith(lines: [...state.lines, line]);
  }

  /// Replaces one line's variant/modifier selections, keeping its quantity.
  ///
  /// Implemented as remove-then-[add] rather than an in-place field change:
  /// the line's `key` is derived from exactly these two things, so changing
  /// either one is a change of identity, not an edit — and routing back
  /// through [add] means a line edited to match another already-open line
  /// (say, two "Kopi Susu Large" ordered separately) merges the same way two
  /// separate adds would, instead of silently duplicating a line the cashier
  /// would then have to notice and clean up by hand.
  ///
  /// [note] defaults to the line's existing note when omitted, so re-picking
  /// a variant or modifier does not silently wipe a note nobody touched; pass
  /// [clearNote] to drop it explicitly.
  void updateLineSelections(
    String oldKey, {
    ProductVariant? variant,
    List<SelectedModifier> modifiers = const [],
    String? note,
    bool clearNote = false,
  }) {
    final existing = state.lines.indexWhere((l) => l.key == oldKey);
    if (existing < 0) return;
    if (state.lines[existing].dispatched) return;
    final line = state.lines[existing];
    state = state.copyWith(lines: [...state.lines]..removeAt(existing));
    add(
      line.product,
      qty: line.quantity,
      variant: variant,
      modifiers: modifiers,
      note: clearNote ? null : (note ?? line.note),
    );
  }

  void decrement(String lineKey) {
    final existing = state.lines.indexWhere((l) => l.key == lineKey);
    if (existing < 0) return;
    if (state.lines[existing].dispatched) return;
    final lines = [...state.lines];
    final line = lines[existing];
    if (line.quantity <= 1) {
      lines.removeAt(existing);
    } else {
      lines[existing] = line.copyWith(quantity: line.quantity - 1);
    }
    state = state.copyWith(lines: lines);
  }

  void setQuantity(String lineKey, int qty) {
    final existing = state.lines.indexWhere((l) => l.key == lineKey);
    if (existing < 0) return;
    if (state.lines[existing].dispatched) return;
    final lines = [...state.lines];
    if (qty <= 0) {
      lines.removeAt(existing);
    } else {
      lines[existing] = lines[existing].copyWith(quantity: qty);
    }
    state = state.copyWith(lines: lines);
  }

  void setNote(String lineKey, String? note) {
    final existing = state.lines.indexWhere((l) => l.key == lineKey);
    if (existing < 0) return;
    if (state.lines[existing].dispatched) return;
    final trimmed = note?.trim();
    final lines = [...state.lines];
    lines[existing] = lines[existing].copyWith(
      note: trimmed,
      clearNote: trimmed == null || trimmed.isEmpty,
    );
    state = state.copyWith(lines: lines);
  }

  /// Puts a discount on one line (Fase 3, version 2 outlets only — the caller
  /// offers it only there).
  void setLineDiscount(
    String lineKey, {
    required DiscountSpec discount,
    String? discountId,
    String? discountName,
    Approver? approvedBy,
  }) {
    final existing = state.lines.indexWhere((l) => l.key == lineKey);
    if (existing < 0) return;
    if (state.lines[existing].dispatched) return;
    final lines = [...state.lines];
    lines[existing] = lines[existing]
        .copyWith(clearDiscount: true)
        .copyWith(
          discount: discount,
          discountId: discountId,
          discountName: discountName,
          discountApprovedBy: approvedBy,
        );
    state = state.copyWith(lines: lines);
  }

  void clearLineDiscount(String lineKey) {
    final existing = state.lines.indexWhere((l) => l.key == lineKey);
    if (existing < 0) return;
    if (state.lines[existing].dispatched) return;
    final lines = [...state.lines];
    lines[existing] = lines[existing].copyWith(clearDiscount: true);
    state = state.copyWith(lines: lines);
  }

  /// Drops what only a version 2 outlet honours. Called when the pricing
  /// context turns out to be legacy — a cart built while the outlet was v2
  /// must not smuggle an item discount or a custom amount into a legacy
  /// receipt.
  void dropVersion2Only() {
    // A saved bill keeps the engine it was frozen with.
    if (state.isBill) return;
    if (!state.hasLineDiscounts && !state.hasCustomLines) return;
    state = state.copyWith(
      lines: [
        for (final l in state.lines)
          if (!l.custom) l.copyWith(clearDiscount: true),
      ],
    );
  }

  void removeLine(String lineKey) {
    if (state.lines.any((l) => l.key == lineKey && l.dispatched)) return;
    state = state.copyWith(
      lines: state.lines.where((l) => l.key != lineKey).toList(),
    );
  }

  void setType(OrderType type) {
    // A saved bill's visit type priced its lines; it is not changed after.
    if (state.isBill) return;
    state = state.copyWith(
      type: type,
      clearTable: type != OrderType.dineIn,
      clearSalesType: true,
    );
  }

  /// Picks a sales type from the master. A built-in one also sets the
  /// matching [OrderType]; a merchant's own travels as `custom`, and keeps
  /// the table only when it is configured to use one.
  void setSalesType(SalesType type) {
    if (state.isBill) return;
    final orderType = type.systemKey == null
        ? OrderType.custom
        : OrderTypeX.fromWire(type.systemKey!);
    state = state.copyWith(
      type: orderType,
      clearTable: !type.usesTable,
      salesTypeId: type.id,
      salesTypeName: type.name,
    );
  }

  void setTable(RestaurantTable? table) => state = state.copyWith(table: table);

  void setServedBy({String? id, String? name}) => state = id == null
      ? state.copyWith(clearServedBy: true)
      : state.copyWith(servedById: id, servedByName: name);

  void setCustomerName(String? name) {
    final trimmed = name?.trim();
    state = state.copyWith(
      customerName: trimmed,
      clearCustomer: trimmed == null || trimmed.isEmpty,
    );
  }

  void setCustomer({String? id, String? name}) {
    final clean = name?.trim();
    state = state.copyWith(
      customerId: id,
      customerName: clean,
      clearCustomer: id == null && (clean == null || clean.isEmpty),
    );
  }

  void setOrderNote(String? note) {
    final trimmed = note?.trim();
    state = state.copyWith(
      note: trimmed,
      clearNote: trimmed == null || trimmed.isEmpty,
    );
  }

  /// Applies a configured promotion. No approval needed — the owner already
  /// approved it when they created it.
  void applyPromo(Promo promo) =>
      state = state._withDiscount(source: DiscountSource.promo, promo: promo);

  /// Applies a hand-typed discount, recording who approved it.
  ///
  /// [authorizedBy] is required rather than optional: the whole point of a
  /// manual discount being manager-gated is that it carries a name, and an
  /// optional parameter is an invitation to forget it at one call site.
  void applyManualDiscount({
    required String authorizedBy,
    String? authorizedById,
    int percent = 0,
    int amount = 0,
  }) => state = state._withDiscount(
    source: DiscountSource.manual,
    manualPercent: percent.clamp(0, 100),
    manualAmount: amount < 0 ? 0 : amount,
    approvedBy: (id: authorizedById, name: authorizedBy),
  );

  /// Applies a named discount from the Backoffice at [value] (its own, or
  /// the one the cashier typed when it has none).
  void applyNamedDiscount(
    DiscountConfig discount, {
    required DiscountSpec value,
    Approver? approvedBy,
  }) => state = state._withDiscount(
    source: DiscountSource.named,
    namedId: discount.id,
    namedName: discount.name,
    named: value,
    approvedBy: approvedBy,
  );

  void clearDiscount() => state = state.copyWith(clearDiscount: true);

  void clear() => state = const CartState();

  /// Seats the bill at [table], under the seating that was just opened for it
  /// (paritas F4). Only this sets a table on a saved-bill cart: the seating is
  /// what stops a second till from seating the same guests.
  void seatAt(RestaurantTable table, String seatingId) =>
      state = state.copyWith(table: table, tableSessionId: seatingId);

  /// Opens a saved bill for editing (paritas F4): every line at the price it
  /// was frozen at, the kitchen's lines locked, and the bill's discount,
  /// customer, server, note and table as they were saved.
  ///
  /// The lines carry stand-in products built from their snapshots, never
  /// today's catalogue rows: a product renamed, re-priced or deleted since the
  /// bill was saved must not change what the guest was quoted.
  void loadBill(Bill bill) {
    final p = bill.pricing;
    final source = DiscountSource.values.firstWhere(
      (s) => s.name == p.discountSource,
      orElse: () => DiscountSource.none,
    );
    final spec = p.billDiscount;
    Promo? promo;
    var manualPercent = 0;
    var manualAmount = 0;
    if (spec != null) {
      final percent = spec.kind == DiscountKind.percent;
      switch (source) {
        case DiscountSource.promo:
          promo = Promo(
            id: p.promoId ?? '',
            name: p.promoName ?? '',
            kind: percent ? PromoKind.percent : PromoKind.amount,
            value: percent ? spec.value ~/ 100 : spec.value,
          );
        case DiscountSource.manual:
          if (percent) {
            manualPercent = spec.value ~/ 100;
          } else {
            manualAmount = spec.value;
          }
        case DiscountSource.named || DiscountSource.none:
          break;
      }
    }
    state = CartState(
      lines: [for (final l in bill.lines) _cartLineOf(l)],
      type: OrderTypeX.fromWire(bill.type),
      table: bill.tableId == null
          ? null
          : RestaurantTable(
              id: bill.tableId!,
              name: bill.tableName ?? '',
              capacity: 0,
              status: TableStatus.occupied,
              outletId: bill.outletId,
            ),
      tableSessionId: bill.tableSessionId,
      customerId: bill.customerId,
      customerName: bill.customerName,
      note: bill.note,
      discountSource: source,
      promo: promo,
      manualDiscountPercent: manualPercent,
      manualDiscountAmount: manualAmount,
      discountAuthorizedBy: p.discountAuthorizedByName,
      discountAuthorizedById: p.discountAuthorizedById,
      namedDiscountId: source == DiscountSource.named ? p.discountId : null,
      namedDiscountName: source == DiscountSource.named ? p.discountName : null,
      namedDiscount: source == DiscountSource.named ? spec : null,
      salesTypeId: bill.salesTypeId,
      salesTypeName: bill.salesTypeName,
      servedById: bill.servedById,
      servedByName: bill.servedByName,
      bill: BillEditing(
        id: bill.id,
        number: bill.number,
        revision: bill.revision,
        pricing: bill.pricing,
        openedAt: bill.openedAt,
        dispatchCount: bill.dispatches.length,
      ),
    );
  }

  static CartLine _cartLineOf(BillLine l) {
    final taxRate = l.taxRateBp;
    final modifierDelta = l.modifiers.fold<int>(0, (a, m) => a + m.priceDelta);
    return CartLine(
      product: Product(
        id: l.productId ?? '$customLinePrefix${l.id}',
        name: l.productName,
        categoryId: l.categoryId ?? '',
        brandId: l.brandId,
        price: l.basePrice ?? l.unitPrice - modifierDelta,
        cost: l.unitCost,
        pb1Rate: taxRate == null ? null : taxRate / 100,
      ),
      variant: l.variantName == null
          ? null
          : ProductVariant(
              id: l.variantId ?? 'variant:${l.id}',
              productId: l.productId ?? '',
              name: l.variantName!,
            ),
      modifiers: [
        for (final m in l.modifiers)
          (
            group: ModifierGroup(
              id: m.groupId ?? m.groupName,
              name: m.groupName,
            ),
            option: ModifierOption(
              id: m.optionId ?? '${m.groupName}:${m.optionName}',
              groupId: m.groupId ?? m.groupName,
              name: m.optionName,
              priceDelta: m.priceDelta,
            ),
          ),
      ],
      quantity: l.quantity,
      note: l.note,
      discount: l.discount,
      discountId: l.lineDiscountId,
      discountName: l.lineDiscountName,
      discountApprovedBy: l.lineDiscountAuthorizedByName == null
          ? null
          : (
              id: l.lineDiscountAuthorizedById,
              name: l.lineDiscountAuthorizedByName!,
            ),
      custom: l.custom,
      billLineId: l.id,
      frozen: FrozenLinePrice(
        unitPrice: l.unitPrice,
        basePrice: l.basePrice ?? l.unitPrice,
        priceSource: l.priceSource ?? (l.custom ? 'custom' : 'base'),
        taxRateBp: taxRate ?? 0,
        unitCost: l.unitCost,
      ),
      dispatched: l.dispatched,
    );
  }
}

final cartProvider = StateNotifierProvider<CartNotifier, CartState>(
  (ref) => CartNotifier(),
);
