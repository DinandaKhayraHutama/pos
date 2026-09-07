import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/pos_register_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';

import '../helpers/db_helper.dart';

const _outlet = 'outlet-1';

void main() {
  setUpAll(() async {
    await initFfi();
  });

  late Database db;
  final shifts = ShiftRepository.instance;

  setUp(() async {
    db = await openInMemoryAppDb(seed: true);
    await AppDatabase.instance.useTestDb(db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<String> firstRegisterId() async =>
      (await PosRegisterRepository.instance.byOutlet(_outlet)).first.id;

  /// A sale attributed to [cashierId], optionally filed under a session.
  Future<void> insertOrder({
    required String id,
    required String cashierId,
    required int total,
    String? sessionId,
    PaymentMethod payment = PaymentMethod.cash,
    OrderStatus status = OrderStatus.paid,
    DateTime? at,
  }) async {
    await db.insert('orders', {
      'id': id,
      'number': id,
      'created_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
      'type': OrderType.takeaway.wire,
      'subtotal': total,
      'discount': 0,
      'tax': 0,
      'total': total,
      'amount_paid': total,
      'payment_method': payment.wire,
      'status': status.wire,
      'cashier_id': cashierId,
      'cashier_name': cashierId,
      'outlet_id': _outlet,
      'pos_session_id': sessionId,
    });
  }

  group('opening a session', () {
    test('binds the session to a till and a branch', () async {
      final posId = await firstRegisterId();
      final shift = await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 200000,
        posId: posId,
        posName: 'Kasir 1',
        outletId: _outlet,
        outletName: 'Bintaro',
      );

      expect(shift.posId, posId);
      expect(shift.hasRegister, isTrue);
      expect(shift.outletId, _outlet);
      expect(shift.isOpen, isTrue);
      expect(await shifts.openSessionForRegister(posId), isNotNull);
    });

    test('a second cashier cannot open a till somebody is holding', () async {
      final posId = await firstRegisterId();
      await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 100000,
        posId: posId,
        posName: 'Kasir 1',
      );

      // The whole point of the lock: two drawers on one cash box cannot be
      // reconciled afterwards, so the second open has to fail loudly and name
      // who has it.
      await expectLater(
        shifts.open(
          employeeId: 'emp_2',
          employeeName: 'Dani',
          openingCash: 50000,
          posId: posId,
          posName: 'Kasir 1',
        ),
        throwsA(
          isA<RegisterBusyException>().having(
            (e) => e.holderName,
            'holderName',
            'Siti',
          ),
        ),
      );
    });

    test('the same till is free again once its session closes', () async {
      final posId = await firstRegisterId();
      final shift = await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 100000,
        posId: posId,
        posName: 'Kasir 1',
      );
      await shifts.close(
        shift: shift,
        countedCash: 100000,
        closedById: 'emp_1',
        closedByName: 'Siti',
      );

      expect(await shifts.openSessionForRegister(posId), isNull);
      // And somebody else can take it — which is the requirement stated as
      // "after the session is closed the POS is available again".
      final next = await shifts.open(
        employeeId: 'emp_2',
        employeeName: 'Dani',
        openingCash: 0,
        posId: posId,
        posName: 'Kasir 1',
      );
      expect(next.isOpen, isTrue);
    });

    test('a different till is unaffected by a busy one', () async {
      final registers = await PosRegisterRepository.instance.byOutlet(_outlet);
      expect(registers.length, greaterThan(1));

      await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 0,
        posId: registers[0].id,
        posName: registers[0].name,
      );
      final second = await shifts.open(
        employeeId: 'emp_2',
        employeeName: 'Dani',
        openingCash: 0,
        posId: registers[1].id,
        posName: registers[1].name,
      );
      expect(second.isOpen, isTrue);
    });
  });

  group('closing a session', () {
    test('records who counted the drawer, and freezes the expectation',
        () async {
      final posId = await firstRegisterId();
      final shift = await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 100000,
        posId: posId,
        posName: 'Kasir 1',
      );
      await insertOrder(
        id: 'o1',
        cashierId: 'emp_1',
        total: 50000,
        sessionId: shift.id,
      );

      final closed = await shifts.close(
        shift: shift,
        countedCash: 145000,
        // After a handover this is not the person who opened it, which is the
        // whole reason it is a separate field.
        closedById: 'emp_2',
        closedByName: 'Dani',
      );

      expect(closed.expectedCash, 150000);
      expect(closed.variance, -5000);
      expect(closed.closedByName, 'Dani');
      expect(closed.employeeName, 'Siti');
      expect(closed.isOpen, isFalse);
    });
  });

  group('totalsFor — attribution by session', () {
    test('counts a second cashier sales after a handover', () async {
      final posId = await firstRegisterId();
      final shift = await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 0,
        posId: posId,
        posName: 'Kasir 1',
      );

      await insertOrder(
        id: 'o1',
        cashierId: 'emp_1',
        total: 30000,
        sessionId: shift.id,
      );
      // The handover case: a different cashier, the same physical cash box.
      // Attributing by cashier would leave this money out of the expectation
      // and hand somebody an unexplained surplus at close.
      await insertOrder(
        id: 'o2',
        cashierId: 'emp_2',
        total: 20000,
        sessionId: shift.id,
      );

      final totals = await shifts.totalsFor(shift);
      expect(totals.cash, 50000);
      expect(totals.orderCount, 2);
    });

    test('ignores a sale rung up on another session', () async {
      final registers = await PosRegisterRepository.instance.byOutlet(_outlet);
      final mine = await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 0,
        posId: registers[0].id,
        posName: registers[0].name,
      );
      final theirs = await shifts.open(
        employeeId: 'emp_2',
        employeeName: 'Dani',
        openingCash: 0,
        posId: registers[1].id,
        posName: registers[1].name,
      );

      await insertOrder(
        id: 'o1',
        cashierId: 'emp_1',
        total: 30000,
        sessionId: mine.id,
      );
      await insertOrder(
        id: 'o2',
        cashierId: 'emp_2',
        total: 90000,
        sessionId: theirs.id,
      );

      expect((await shifts.totalsFor(mine)).cash, 30000);
      expect((await shifts.totalsFor(theirs)).cash, 90000);
    });

    test('excludes voided and refunded sales', () async {
      final posId = await firstRegisterId();
      final shift = await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 0,
        posId: posId,
        posName: 'Kasir 1',
      );
      await insertOrder(
        id: 'o1',
        cashierId: 'emp_1',
        total: 30000,
        sessionId: shift.id,
      );
      await insertOrder(
        id: 'o2',
        cashierId: 'emp_1',
        total: 99000,
        sessionId: shift.id,
        status: OrderStatus.cancelled,
      );
      await insertOrder(
        id: 'o3',
        cashierId: 'emp_1',
        total: 77000,
        sessionId: shift.id,
        status: OrderStatus.refunded,
      );

      expect((await shifts.totalsFor(shift)).cash, 30000);
    });

    test('splits cash from card and QRIS', () async {
      final posId = await firstRegisterId();
      final shift = await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 0,
        posId: posId,
        posName: 'Kasir 1',
      );
      await insertOrder(
        id: 'o1',
        cashierId: 'emp_1',
        total: 30000,
        sessionId: shift.id,
      );
      await insertOrder(
        id: 'o2',
        cashierId: 'emp_1',
        total: 45000,
        sessionId: shift.id,
        payment: PaymentMethod.qris,
      );

      final totals = await shifts.totalsFor(shift);
      // Only cash feeds the drawer; the rest settles with the processor.
      expect(totals.cash, 30000);
      expect(totals.nonCash, 45000);
      expect(totals.total, 75000);
    });

    test('a session opened before registers still reads its own sales',
        () async {
      // What an install mid-shift at upgrade time looks like: no pos_id on the
      // session, no pos_session_id on the orders. The window-and-cashier
      // fallback is what keeps that drawer countable.
      final openedAt = DateTime.now().subtract(const Duration(hours: 2));
      await db.insert('shifts', {
        'id': 'legacy_shift',
        'employee_id': 'emp_1',
        'employee_name': 'Siti',
        'opened_at': openedAt.millisecondsSinceEpoch,
        'opening_cash': 100000,
      });
      final legacy = (await shifts.openShifts()).firstWhere(
        (s) => s.id == 'legacy_shift',
      );
      expect(legacy.hasRegister, isFalse);

      await insertOrder(
        id: 'o1',
        cashierId: 'emp_1',
        total: 25000,
        at: openedAt.add(const Duration(minutes: 10)),
      );
      // Somebody else working the same hours must not inflate this drawer.
      await insertOrder(
        id: 'o2',
        cashierId: 'emp_2',
        total: 500000,
        at: openedAt.add(const Duration(minutes: 20)),
      );

      expect((await shifts.totalsFor(legacy)).cash, 25000);
    });
  });

  group('openShifts scoping', () {
    test('keeps a session with no branch visible from every branch', () async {
      await db.insert('shifts', {
        'id': 'legacy_shift',
        'employee_id': 'emp_1',
        'employee_name': 'Siti',
        'opened_at': DateTime.now().millisecondsSinceEpoch,
        'opening_cash': 0,
      });

      // An open drawer that appears in no branch list is worse than one that
      // appears in two — nobody would ever be prompted to close it.
      final bintaro = await shifts.openShifts(outletId: _outlet);
      final kemang = await shifts.openShifts(outletId: 'outlet-2');
      expect(bintaro.any((s) => s.id == 'legacy_shift'), isTrue);
      expect(kemang.any((s) => s.id == 'legacy_shift'), isTrue);
    });

    test('a branch does not see another branch drawers', () async {
      final posId = await firstRegisterId();
      await shifts.open(
        employeeId: 'emp_1',
        employeeName: 'Siti',
        openingCash: 0,
        posId: posId,
        posName: 'Kasir 1',
        outletId: _outlet,
        outletName: 'Bintaro',
      );

      final kemang = await shifts.openShifts(outletId: 'outlet-2');
      expect(kemang, isEmpty);
    });
  });
}
