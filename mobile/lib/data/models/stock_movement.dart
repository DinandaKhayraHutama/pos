/// Why a stock level changed.
///
/// Stored as the enum name, and every count change writes one. A stock figure
/// with no history is a number nobody can defend: when the shelf and the app
/// disagree, the only useful question is "what did we say happened to it?".
enum StockReason {
  /// Sold at the till. Written automatically by the order transaction.
  sale,

  /// Returned to the shelf because the sale was voided or refunded.
  voidReturn,

  /// Goods arrived from a supplier.
  received,

  /// Spoiled, broken or otherwise lost.
  waste,

  /// A recount: the shelf was right and the app was wrong.
  correction,

  /// The opening count when the product started being tracked.
  opening,

  /// A stock opname: the shelf was counted. On an activated till the server
  /// turns the counted quantity into a delta against its own count.
  count,

  /// Moved in from another branch. Written by the Backoffice, pulled here.
  transferIn,

  /// Moved out to another branch. Written by the Backoffice, pulled here.
  transferOut,
}

extension StockReasonX on StockReason {
  String get wire => name;

  static StockReason fromWire(String v) => StockReason.values.firstWhere(
    (e) => e.name == v,
    orElse: () => StockReason.correction,
  );

  /// Reasons a person picks by hand. The other two are written by the app and
  /// would be nonsense as choices in an adjustment form.
  static const manual = <StockReason>[
    StockReason.received,
    StockReason.waste,
    StockReason.correction,
  ];
}

/// One line in a product's stock history.
class StockMovement {
  const StockMovement({
    required this.id,
    required this.productId,
    required this.productName,
    required this.delta,
    required this.balanceAfter,
    required this.reason,
    required this.createdAt,
    required this.employeeId,
    required this.employeeName,
    this.note,
    this.outletId,
  });

  final String id;
  final String productId;

  /// Copied, not joined — the same reason `Order` stores `cashierName`. A
  /// history that goes blank when a product is deleted is not a history.
  final String productName;

  /// Signed: negative took stock off the shelf, positive put it back.
  final int delta;

  /// On-hand count immediately after this movement, so the history reads as a
  /// running balance without the UI having to replay every row.
  final int balanceAfter;

  final StockReason reason;
  final DateTime createdAt;
  final String employeeId;
  final String employeeName;
  final String? note;

  /// Which branch's shelf moved. Null only on rows written before outlets
  /// existed and never backfilled — the ledger is filtered by it, so a null
  /// would quietly vanish from that branch's history.
  final String? outletId;

  bool get isIncrease => delta > 0;

  factory StockMovement.fromMap(Map<String, dynamic> m) => StockMovement(
    id: m['id'] as String,
    productId: m['product_id'] as String,
    productName: m['product_name'] as String,
    delta: (m['delta'] as num).toInt(),
    balanceAfter: (m['balance_after'] as num).toInt(),
    reason: StockReasonX.fromWire(m['reason'] as String),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (m['created_at'] as num).toInt(),
    ),
    employeeId: (m['employee_id'] as String?) ?? '',
    employeeName: (m['employee_name'] as String?) ?? '',
    note: m['note'] as String?,
    outletId: m['outlet_id'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'outlet_id': outletId,
    'product_id': productId,
    'product_name': productName,
    'delta': delta,
    'balance_after': balanceAfter,
    'reason': reason.wire,
    'created_at': createdAt.millisecondsSinceEpoch,
    'employee_id': employeeId,
    'employee_name': employeeName,
    'note': note,
  };
}
