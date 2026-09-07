/// A POS session: one till, opened with a cash float and closed with a count.
///
/// Called a shift because that is what staff call it, but it is the session
/// the whole sell flow hangs off — a cashier signs on to a register, and the
/// orders they ring up carry this row's id so the drawer can be reconciled
/// against exactly the sales that went into it.
///
/// The point of it is accountability for cash. Card and QRIS settle elsewhere,
/// so only cash is counted here — mixing them would produce an "expected"
/// figure no one can check against the drawer.
///
/// The session belongs to the REGISTER, not to a person. A handover mid-shift
/// keeps the same session and the same physical cash box: [employeeName] is
/// who opened it, [closedByName] is who counted it, and each order keeps its
/// own cashier's name. Splitting the session on every handover would put two
/// expected balances on one drawer.
class Shift {
  const Shift({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.openedAt,
    required this.openingCash,
    this.posId,
    this.posName,
    this.outletId,
    this.outletName,
    this.closedAt,
    this.countedCash,
    this.expectedCash,
    this.closedById,
    this.closedByName,
    this.note,
  });

  final String id;
  final String employeeId;

  /// Copied at open time, not joined.
  ///
  /// A shift report has to keep reading correctly after the employee is
  /// renamed or removed — the same reason `Order` stores `cashierName`.
  final String employeeName;

  /// Which till this session holds, and which branch it stands in.
  ///
  /// Null only for a session opened before registers existed. Those stay
  /// sellable and closeable exactly as they were; nothing backfills a guess.
  /// The names are snapshots alongside the ids, for the same reason the
  /// cashier's is: renaming a till must not rewrite what a past session says.
  final String? posId;
  final String? posName;
  final String? outletId;
  final String? outletName;

  final DateTime openedAt;

  /// Float in the drawer at open.
  final int openingCash;

  /// Null while the shift is still running.
  final DateTime? closedAt;

  /// What the cashier physically counted at close.
  final int? countedCash;

  /// What the system expected: opening float + cash sales during the shift.
  ///
  /// Frozen into the row at close rather than recomputed on read. A later edit
  /// or refund would otherwise silently rewrite history and make a signed-off
  /// variance stop matching the paper it was signed on.
  final int? expectedCash;

  /// Who counted the drawer, when that is not who opened it.
  ///
  /// Null while open, and null on a session closed by the same person who
  /// opened it would be indistinguishable from "not recorded" — so it is
  /// written on every close, whoever it was.
  final String? closedById;
  final String? closedByName;

  final String? note;

  bool get isOpen => closedAt == null;

  /// Whether this session is bound to a till, which sessions opened before
  /// v16 are not.
  bool get hasRegister => posId != null && posId!.isNotEmpty;

  /// Counted minus expected. Positive is a surplus, negative a shortfall.
  int? get variance => countedCash == null || expectedCash == null
      ? null
      : countedCash! - expectedCash!;

  factory Shift.fromMap(Map<String, dynamic> m) => Shift(
    id: m['id'] as String,
    employeeId: m['employee_id'] as String,
    employeeName: m['employee_name'] as String,
    posId: m['pos_id'] as String?,
    posName: m['pos_name'] as String?,
    outletId: m['outlet_id'] as String?,
    outletName: m['outlet_name'] as String?,
    openedAt: DateTime.fromMillisecondsSinceEpoch(
      (m['opened_at'] as num).toInt(),
    ),
    openingCash: (m['opening_cash'] as num).toInt(),
    closedAt: m['closed_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch((m['closed_at'] as num).toInt()),
    countedCash: (m['counted_cash'] as num?)?.toInt(),
    expectedCash: (m['expected_cash'] as num?)?.toInt(),
    closedById: m['closed_by_id'] as String?,
    closedByName: m['closed_by_name'] as String?,
    note: m['note'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'employee_id': employeeId,
    'employee_name': employeeName,
    'pos_id': posId,
    'pos_name': posName,
    'outlet_id': outletId,
    'outlet_name': outletName,
    'opened_at': openedAt.millisecondsSinceEpoch,
    'opening_cash': openingCash,
    'closed_at': closedAt?.millisecondsSinceEpoch,
    'counted_cash': countedCash,
    'expected_cash': expectedCash,
    'closed_by_id': closedById,
    'closed_by_name': closedByName,
    'note': note,
  };
}

/// What a shift took, broken down by how it was paid.
///
/// Only [cash] feeds the drawer count; the rest is shown so the cashier can
/// see the whole session rather than a number that looks too small.
class ShiftTotals {
  const ShiftTotals({
    required this.cash,
    required this.nonCash,
    required this.orderCount,
  });

  final int cash;
  final int nonCash;
  final int orderCount;

  int get total => cash + nonCash;
}
