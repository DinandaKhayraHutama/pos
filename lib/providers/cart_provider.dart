import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/enums.dart';
import '../data/models/modifier_group.dart';
import '../data/models/modifier_option.dart';
import '../data/models/product.dart';
import '../data/models/product_variant.dart';
import '../data/models/promo.dart';
import '../data/models/table.dart';

/// One selected modifier option, paired with the group it came from — the
/// group is carried alongside rather than looked up later because the cart
/// needs its label (for the summary line under a cart tile) and its
/// [ModifierGroup.selectionType]/[ModifierGroup.maxSelect] (for re-opening
/// the picker to edit) without another query.
typedef SelectedModifier = ({ModifierGroup group, ModifierOption option});

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

  const CartLine({
    required this.product,
    required this.quantity,
    this.variant,
    this.modifiers = const [],
    this.note,
  });

  /// Identity for merging. A Large and a Regular of the same coffee are two
  /// lines, not one with quantity 2 — they cost different amounts and print
  /// as different rows on the kitchen ticket. The same reasoning extends to
  /// modifiers: "Extra Spicy" and "Mild" nasi goreng are two lines. Sorted so
  /// picking the same two toppings in either order still merges into one.
  String get key {
    final variantPart = variant == null ? '' : '#${variant!.id}';
    final modifierPart = modifiers.isEmpty
        ? ''
        : '#${(modifiers.map((m) => m.option.id).toList()..sort()).join(',')}';
    return '${product.id}$variantPart$modifierPart';
  }

  /// Base price, plus the variant's delta, plus every selected modifier's
  /// delta.
  int get unitPrice =>
      product.price +
      (variant?.priceDelta ?? 0) +
      modifiers.fold(0, (a, m) => a + m.option.priceDelta);

  int get lineTotal => unitPrice * quantity;

  String get displayName =>
      variant == null ? product.name : '${product.name} (${variant!.name})';

  CartLine copyWith({int? quantity, String? note}) => CartLine(
    product: product,
    variant: variant,
    modifiers: modifiers,
    quantity: quantity ?? this.quantity,
    note: note ?? this.note,
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
}

class CartState {
  const CartState({
    this.lines = const [],
    this.type = OrderType.dineIn,
    this.table,
    this.customerName,
    this.note,
    this.discountSource = DiscountSource.none,
    this.promo,
    this.manualDiscountPercent = 0,
    this.manualDiscountAmount = 0,
    this.discountAuthorizedBy,
  });

  final List<CartLine> lines;
  final OrderType type;
  final RestaurantTable? table;
  final String? customerName;
  final String? note;

  final DiscountSource discountSource;

  /// The applied promotion, when [discountSource] is promo.
  final Promo? promo;

  /// Manual discount, one of the two. A percentage takes precedence when both
  /// are somehow set, but the UI only ever sets one.
  final int manualDiscountPercent; // 0-100
  final int manualDiscountAmount;

  /// Who approved the manual discount. Null for promos, which need nobody.
  final String? discountAuthorizedBy;

  bool get isEmpty => lines.isEmpty;
  int get itemCount => lines.fold(0, (a, l) => a + l.quantity);

  int get subtotal => lines.fold(0, (a, l) => a + l.lineTotal);

  /// The money taken off this bill.
  ///
  /// Always clamped to the subtotal: a Rp 50.000 voucher against a Rp 20.000
  /// bill takes it to zero, never to a negative total the cashier would have
  /// to hand over as change.
  int get discountAmount {
    final raw = switch (discountSource) {
      DiscountSource.none => 0,
      DiscountSource.promo => promo?.discountFor(subtotal) ?? 0,
      DiscountSource.manual => manualDiscountPercent > 0
          ? (subtotal * manualDiscountPercent) ~/ 100
          : manualDiscountAmount,
    };
    return raw.clamp(0, subtotal);
  }

  /// Human label for the applied discount, or null when there is none.
  String? get discountLabel => switch (discountSource) {
    DiscountSource.none => null,
    DiscountSource.promo => promo?.name,
    DiscountSource.manual => manualDiscountPercent > 0
        ? '$manualDiscountPercent%'
        : null,
  };

  /// Basis before Service Charge and PB1: subtotal minus discount.
  int get taxableBase => subtotal - discountAmount;

  /// Service Charge: one flat calculation over the whole basket — unlike
  /// PB1 there is no per-product override, since a service charge is a
  /// blanket restaurant policy, not a tax classification — rounded
  /// half-up ONCE, matching PB1's own rounding convention. [rate] is 0 both
  /// when the feature is off and when it's configured to 0%; the caller
  /// resolves `settings.serviceChargeEnabled` into that before calling in.
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
      final discountShare =
          discount == 0 ? 0 : (discount * l.lineTotal) ~/ sub;
      final serviceChargeShare =
          serviceCharge == 0 ? 0 : (serviceCharge * l.lineTotal) ~/ sub;
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
    String? note,
    DiscountSource? discountSource,
    Promo? promo,
    int? manualDiscountPercent,
    int? manualDiscountAmount,
    String? discountAuthorizedBy,
    bool clearTable = false,
    bool clearCustomer = false,
    bool clearNote = false,
    bool clearDiscount = false,
  }) => CartState(
    lines: lines ?? this.lines,
    type: type ?? this.type,
    table: clearTable ? null : (table ?? this.table),
    customerName: clearCustomer ? null : (customerName ?? this.customerName),
    note: clearNote ? null : (note ?? this.note),
    discountSource: clearDiscount
        ? DiscountSource.none
        : (discountSource ?? this.discountSource),
    promo: clearDiscount ? null : (promo ?? this.promo),
    manualDiscountPercent: clearDiscount
        ? 0
        : (manualDiscountPercent ?? this.manualDiscountPercent),
    manualDiscountAmount: clearDiscount
        ? 0
        : (manualDiscountAmount ?? this.manualDiscountAmount),
    discountAuthorizedBy: clearDiscount
        ? null
        : (discountAuthorizedBy ?? this.discountAuthorizedBy),
  );
}

class CartNotifier extends StateNotifier<CartState> {
  CartNotifier() : super(const CartState());

  void add(
    Product product, {
    int qty = 1,
    ProductVariant? variant,
    List<SelectedModifier> modifiers = const [],
  }) {
    // Built once so `.key` (which already knows how to fold variant +
    // modifiers into one identity string) is the single source of truth for
    // whether this merges into an existing line or starts a new one.
    final candidate = CartLine(
      product: product,
      variant: variant,
      modifiers: modifiers,
      quantity: qty,
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

  /// Replaces one line's variant/modifier selections, keeping its quantity.
  ///
  /// Implemented as remove-then-[add] rather than an in-place field change:
  /// the line's `key` is derived from exactly these two things, so changing
  /// either one is a change of identity, not an edit — and routing back
  /// through [add] means a line edited to match another already-open line
  /// (say, two "Kopi Susu Large" ordered separately) merges the same way two
  /// separate adds would, instead of silently duplicating a line the cashier
  /// would then have to notice and clean up by hand.
  void updateLineSelections(
    String oldKey, {
    ProductVariant? variant,
    List<SelectedModifier> modifiers = const [],
  }) {
    final existing = state.lines.indexWhere((l) => l.key == oldKey);
    if (existing < 0) return;
    final line = state.lines[existing];
    state = state.copyWith(
      lines: [...state.lines]..removeAt(existing),
    );
    add(line.product, qty: line.quantity, variant: variant, modifiers: modifiers);
  }

  void decrement(String lineKey) {
    final existing = state.lines.indexWhere((l) => l.key == lineKey);
    if (existing < 0) return;
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
    final lines = [...state.lines];
    lines[existing] = lines[existing].copyWith(note: note);
    state = state.copyWith(lines: lines);
  }

  void removeLine(String lineKey) {
    state = state.copyWith(
      lines: state.lines.where((l) => l.key != lineKey).toList(),
    );
  }

  void setType(OrderType type) {
    state = state.copyWith(type: type, clearTable: type != OrderType.dineIn);
  }

  void setTable(RestaurantTable? table) => state = state.copyWith(table: table);

  void setCustomerName(String? name) =>
      state = state.copyWith(customerName: name);

  void setOrderNote(String? note) => state = state.copyWith(note: note);

  /// Applies a configured promotion. No approval needed — the owner already
  /// approved it when they created it.
  ///
  /// Built through the constructor rather than `copyWith` because switching
  /// between discount kinds has to CLEAR the other one, and this codebase's
  /// `copyWith` convention treats null as "leave alone".
  void applyPromo(Promo promo) => state = CartState(
    lines: state.lines,
    type: state.type,
    table: state.table,
    customerName: state.customerName,
    note: state.note,
    discountSource: DiscountSource.promo,
    promo: promo,
  );

  /// Applies a hand-typed discount, recording who approved it.
  ///
  /// [authorizedBy] is required rather than optional: the whole point of a
  /// manual discount being manager-gated is that it carries a name, and an
  /// optional parameter is an invitation to forget it at one call site.
  void applyManualDiscount({
    required String authorizedBy,
    int percent = 0,
    int amount = 0,
  }) {
    state = CartState(
      lines: state.lines,
      type: state.type,
      table: state.table,
      customerName: state.customerName,
      note: state.note,
      discountSource: DiscountSource.manual,
      manualDiscountPercent: percent.clamp(0, 100),
      manualDiscountAmount: amount < 0 ? 0 : amount,
      discountAuthorizedBy: authorizedBy,
    );
  }

  void clearDiscount() => state = state.copyWith(clearDiscount: true);

  void clear() => state = const CartState();
}

final cartProvider = StateNotifierProvider<CartNotifier, CartState>(
  (ref) => CartNotifier(),
);
