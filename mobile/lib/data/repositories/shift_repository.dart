import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../device/till_binding.dart';

import '../database/app_database.dart';
import '../models/enums.dart';
import '../models/shift.dart';
import '../sync/outbox_store.dart';
import '../sync/session_push.dart';

/// Thrown when a till already has somebody signed on to it.
///
/// A typed error rather than a null return: "could not open" and "opened, here
/// it is" are different enough that a call site should not be able to conflate
/// them, and the UI needs the name to say who is holding it.
class RegisterBusyException implements Exception {
  const RegisterBusyException(this.registerName, this.holderName);

  final String registerName;
  final String holderName;

  @override
  String toString() => 'Register $registerName is already open for $holderName';
}

/// POS sessions. The only place shifts are read or written.
class ShiftRepository {
  ShiftRepository._();
  static final ShiftRepository instance = ShiftRepository._();

  /// Session ids are UUIDs, like every other id the app writes.
  ///
  /// They used to be `shift_<millisecondsSinceEpoch>`, which is not unique:
  /// two tills opened in the same millisecond produced the same primary key,
  /// so the second open silently lost its row. That is a race two cashiers
  /// starting a shift together can genuinely lose, and the failure is
  /// invisible until somebody counts a drawer that has no session.
  static const _uuid = Uuid();

  /// The session this employee currently has open, if any.
  ///
  /// Scoped per employee on purpose: two cashiers on the same device each own
  /// their own drawer session, and closing should never sweep up someone
  /// else's takings. Used to RESUME — signing back in adopts your own open
  /// session rather than making you pick a till you are already standing at.
  ///
  /// [posId] narrows it to one till — on an activated device, the bound one,
  /// so a session opened elsewhere is never adopted into this till's books.
  Future<Shift?> openShiftFor(String employeeId, {String? posId}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'shifts',
      where: posId == null
          ? 'employee_id = ? AND closed_at IS NULL'
          : 'employee_id = ? AND closed_at IS NULL AND pos_id = ?',
      whereArgs: posId == null ? [employeeId] : [employeeId, posId],
      orderBy: 'opened_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Shift.fromMap(rows.first);
  }

  /// The session currently holding [posId], if any.
  ///
  /// This is the lock, read: the picker shows a till with one of these as
  /// taken, naming who has it rather than simply refusing.
  Future<Shift?> openSessionForRegister(String posId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'shifts',
      where: 'pos_id = ? AND closed_at IS NULL',
      whereArgs: [posId],
      limit: 1,
    );
    return rows.isEmpty ? null : Shift.fromMap(rows.first);
  }

  Future<Shift?> byId(String id) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'shifts',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Shift.fromMap(rows.first);
  }

  /// Signs an employee on to a till and opens its drawer.
  ///
  /// The busy check and the insert happen inside ONE transaction. Checking
  /// first and inserting after loses the race between two cashiers tapping
  /// Open at the same moment, and the loser gets a second drawer on a till
  /// that already has one — two expected balances for one physical cash box,
  /// which cannot be reconciled afterwards. The partial unique index on
  /// `shifts(pos_id) WHERE closed_at IS NULL` is the backstop; this is the
  /// path that produces a message a human can act on.
  ///
  /// Throws [RegisterBusyException] when the till is already held.
  Future<Shift> open({
    required String employeeId,
    required String employeeName,
    required int openingCash,
    required String posId,
    required String posName,
    String? outletId,
    String? outletName,
  }) async {
    // On an activated device the server files every session under the till
    // the token is bound to, whatever the row says. Opening one on any other
    // till would split the drawer between two sets of books, so it is refused
    // here rather than trusted to the picker. The bound outlet is stamped even
    // when the caller did not know it.
    final binding = TillBinding.current;
    if (binding != null) {
      if (posId != binding.registerId) {
        throw TillBindingException('session on register $posId');
      }
      if (outletId != null && outletId != binding.outletId) {
        throw TillBindingException('session in outlet $outletId');
      }
      outletId = binding.outletId;
    }

    final db = await AppDatabase.instance.db;
    final shift = Shift(
      id: _uuid.v4(),
      employeeId: employeeId,
      employeeName: employeeName,
      posId: posId,
      posName: posName,
      outletId: outletId,
      outletName: outletName,
      openedAt: DateTime.now(),
      openingCash: openingCash,
    );

    await db.transaction((txn) async {
      final held = await txn.query(
        'shifts',
        columns: ['employee_name'],
        where: 'pos_id = ? AND closed_at IS NULL',
        whereArgs: [posId],
        limit: 1,
      );
      if (held.isNotEmpty) {
        throw RegisterBusyException(
          posName,
          held.first['employee_name'] as String? ?? '',
        );
      }
      await txn.insert('shifts', shift.toMap());
      await OutboxStore.enqueueWithin(txn, SessionPush.entity, shift.id);
    });
    return shift;
  }

  /// Sales taken during [shift], split by payment type.
  ///
  /// Attributed by SESSION, not by cashier-and-clock. The session id is
  /// written onto every order as it is rung up, so this counts exactly the
  /// money that went into this drawer — including sales a second cashier rang
  /// up after a handover, which are physically in the same cash box and have
  /// to count towards the same expectation.
  ///
  /// The second branch covers sessions opened before registers existed, which
  /// carry no id on any order. Those fall back to the old window-and-cashier
  /// heuristic, so a shift somebody is part-way through when they upgrade
  /// still reads correctly. It is scoped to `pos_session_id IS NULL` so it can
  /// never double-count an order that already names its session.
  ///
  /// Cancelled and refunded orders are excluded — they took no money.
  Future<ShiftTotals> totalsFor(Shift shift) async {
    final db = await AppDatabase.instance.db;
    final until = (shift.closedAt ?? DateTime.now()).millisecondsSinceEpoch;
    final rows = await db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN payment_method = ? THEN total ELSE 0 END), 0) AS cash,
        COALESCE(SUM(CASE WHEN payment_method != ? THEN total ELSE 0 END), 0) AS non_cash,
        COUNT(*) AS order_count
      FROM orders
      WHERE $kRevenueStatusSql
        AND (
          pos_session_id = ?
          OR (
            pos_session_id IS NULL
            AND cashier_id = ?
            AND created_at >= ? AND created_at <= ?
          )
        )
      ''',
      [
        PaymentMethod.cash.wire,
        PaymentMethod.cash.wire,
        shift.id,
        shift.employeeId,
        shift.openedAt.millisecondsSinceEpoch,
        until,
      ],
    );
    final m = rows.first;
    return ShiftTotals(
      cash: (m['cash'] as num?)?.toInt() ?? 0,
      nonCash: (m['non_cash'] as num?)?.toInt() ?? 0,
      orderCount: (m['order_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Closes [shift] against a physical count, releasing its till.
  ///
  /// The expected figure is computed here and written into the row, so the
  /// variance the cashier signed off stays exactly what it was even if an
  /// order is edited afterwards.
  ///
  /// [closedById] and [closedByName] are required rather than optional: after
  /// a handover the person counting the drawer is not the person who opened
  /// it, and an optional parameter is an invitation to forget that at one call
  /// site — the one that would leave a variance with no name on it.
  Future<Shift> close({
    required Shift shift,
    required int countedCash,
    required String closedById,
    required String closedByName,
    String? note,
  }) async {
    final db = await AppDatabase.instance.db;

    // Read before the transaction opens: totalsFor runs several aggregates over
    // `orders`, and holding a write transaction open across them would block
    // the till from ringing up a sale while a drawer is being counted.
    final totals = await totalsFor(shift);

    final closed = Shift(
      id: shift.id,
      employeeId: shift.employeeId,
      employeeName: shift.employeeName,
      posId: shift.posId,
      posName: shift.posName,
      outletId: shift.outletId,
      outletName: shift.outletName,
      openedAt: shift.openedAt,
      openingCash: shift.openingCash,
      closedAt: DateTime.now(),
      countedCash: countedCash,
      expectedCash: shift.openingCash + totals.cash,
      closedById: closedById,
      closedByName: closedByName,
      note: note,
    );
    // The close and its outbox entry commit together. Writing the close first
    // and queueing after leaves a window where a crash produces a counted
    // drawer the server is never told about — a variance nobody can explain
    // because the evidence only exists on one tablet.
    await db.transaction((txn) async {
      await txn.update(
        'shifts',
        closed.toMap(),
        where: 'id = ?',
        whereArgs: [shift.id],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await OutboxStore.enqueueWithin(txn, SessionPush.entity, shift.id);
    });

    return closed;
  }

  /// Every till session currently open, oldest first.
  ///
  /// The manager's view of the floor: a supervisor needs to know what should
  /// be in each drawer right now, without waiting for the cashier to close —
  /// which is the whole point of being able to check before a handover rather
  /// than after.
  ///
  /// Scoped to one branch when [outletId] is given, like every other aggregate
  /// in the app. Sessions with no outlet at all — opened before registers
  /// existed — are kept in every branch list rather than dropped from all of
  /// them: an open drawer that appears nowhere is worse than one that appears
  /// twice.
  Future<List<Shift>> openShifts({String? outletId}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'shifts',
      where: outletId == null
          ? 'closed_at IS NULL'
          : 'closed_at IS NULL AND (outlet_id = ? OR outlet_id IS NULL)',
      whereArgs: outletId == null ? null : [outletId],
      orderBy: 'opened_at ASC',
    );
    return rows.map(Shift.fromMap).toList();
  }

  /// Most recent shifts, newest first — the closing history.
  Future<List<Shift>> recent({int limit = 30, String? outletId}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'shifts',
      where: outletId == null ? null : '(outlet_id = ? OR outlet_id IS NULL)',
      whereArgs: outletId == null ? null : [outletId],
      orderBy: 'opened_at DESC',
      limit: limit,
    );
    return rows.map(Shift.fromMap).toList();
  }
}
