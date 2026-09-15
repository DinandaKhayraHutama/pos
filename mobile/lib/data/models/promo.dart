/// How a promotion reduces the bill.
enum PromoKind {
  /// A share of the subtotal, e.g. 10%.
  percent,

  /// A flat sum off, e.g. Rp 5.000.
  amount,
}

extension PromoKindX on PromoKind {
  String get wire => name;

  static PromoKind fromWire(String v) => PromoKind.values.firstWhere(
    (e) => e.name == v,
    orElse: () => PromoKind.percent,
  );
}

/// A discount the owner configured once, that a cashier can apply without
/// asking anyone.
///
/// This is the counterweight to the manual discount: typing a free-form
/// percentage is a manager action because it is unauditable, but "Happy Hour
/// 15%" is a decision the owner already made, so any cashier may apply it and
/// the report can group by it afterwards.
class Promo {
  const Promo({
    required this.id,
    required this.name,
    required this.kind,
    required this.value,
    this.minSpend = 0,
    this.active = true,
    this.sortOrder = 0,
    this.allOutlets = true,
  });

  final String id;
  final String name;
  final PromoKind kind;

  /// Percentage points when [kind] is percent, otherwise an absolute amount.
  final int value;

  /// Smallest subtotal this promo may be applied to. 0 means no floor.
  final int minSpend;

  final bool active;
  final int sortOrder;

  /// Whether the promo is live at every branch. When false it is live only at
  /// the branches `promo_outlets` names (Fase 6). A promo made in the demo is
  /// company-wide, as every promo was before scoping existed.
  final bool allOutlets;

  /// What this promo takes off a bill of [subtotal].
  ///
  /// Clamped to the subtotal so a Rp 20.000 voucher on a Rp 12.000 bill takes
  /// the bill to zero rather than to a negative total the cashier then has to
  /// hand out as change.
  int discountFor(int subtotal) {
    if (subtotal <= 0) return 0;
    final raw = kind == PromoKind.percent
        ? (subtotal * value) ~/ 100
        : value;
    return raw.clamp(0, subtotal);
  }

  /// Whether this promo may be used on a bill of [subtotal].
  bool isEligible(int subtotal) => active && subtotal >= minSpend;

  factory Promo.fromMap(Map<String, dynamic> m) => Promo(
    id: m['id'] as String,
    name: m['name'] as String,
    kind: PromoKindX.fromWire(m['kind'] as String),
    value: (m['value'] as num).toInt(),
    minSpend: (m['min_spend'] as num?)?.toInt() ?? 0,
    active: ((m['active'] as int?) ?? 1) == 1,
    sortOrder: (m['sort_order'] as int?) ?? 0,
    allOutlets: ((m['all_outlets'] as int?) ?? 1) == 1,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'kind': kind.wire,
    'value': value,
    'min_spend': minSpend,
    'active': active ? 1 : 0,
    'sort_order': sortOrder,
    'all_outlets': allOutlets ? 1 : 0,
  };

  Promo copyWith({
    String? id,
    String? name,
    PromoKind? kind,
    int? value,
    int? minSpend,
    bool? active,
    int? sortOrder,
    bool? allOutlets,
  }) => Promo(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    value: value ?? this.value,
    minSpend: minSpend ?? this.minSpend,
    active: active ?? this.active,
    sortOrder: sortOrder ?? this.sortOrder,
    allOutlets: allOutlets ?? this.allOutlets,
  );
}
