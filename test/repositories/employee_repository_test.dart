import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/repositories/employee_repository.dart';

import '../helpers/db_helper.dart';

/// Seeded staff (see `AppDatabase.seedEmployees`): `emp_kasir_1` / PIN 2345,
/// `emp_kasir_2` / PIN 3456.
const _cashierId = 'emp_kasir_1';
const _cashierPin = '2345';
const _otherCashierId = 'emp_kasir_2';
const _otherCashierPin = '3456';

/// [EmployeeRepository.verify] is the whole trust boundary behind two
/// separate flows: the login keypad, and now confirming a cashier's own PIN
/// before their POS session closes. Both depend on it rejecting a PIN that
/// does not belong to the SPECIFIC account being checked — a global "does
/// this PIN exist anywhere" match would let a colleague's valid PIN close a
/// drawer that is not theirs to sign.
void main() {
  setUpAll(() async {
    await initFfi();
  });

  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb(seed: true);
    await AppDatabase.instance.useTestDb(db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  group('EmployeeRepository.verify — scoped to one account', () {
    test('the right id with the right PIN resolves', () async {
      final employee = await EmployeeRepository.instance.verify(
        id: _cashierId,
        pin: _cashierPin,
      );
      expect(employee, isNotNull);
      expect(employee!.id, _cashierId);
    });

    test('the right id with the wrong PIN returns null', () async {
      final employee = await EmployeeRepository.instance.verify(
        id: _cashierId,
        pin: '0000',
      );
      expect(employee, isNull);
    });

    test(
        "a colleague's own valid PIN is rejected — it is not this account's "
        'PIN', () async {
      // The exact case a close-session re-confirmation exists to prevent:
      // Dani's PIN is a real, correct PIN, just not Siti's.
      final employee = await EmployeeRepository.instance.verify(
        id: _cashierId,
        pin: _otherCashierPin,
      );
      expect(employee, isNull);
    });

    test('a deactivated account is rejected even with the correct PIN',
        () async {
      final row = await EmployeeRepository.instance.byId(_cashierId);
      await EmployeeRepository.instance.upsert(
        row!.copyWith(active: false),
      );

      final employee = await EmployeeRepository.instance.verify(
        id: _cashierId,
        pin: _cashierPin,
      );
      expect(employee, isNull);
    });

    test('an unknown id returns null regardless of the PIN', () async {
      final employee = await EmployeeRepository.instance.verify(
        id: 'not_a_real_id',
        pin: _cashierPin,
      );
      expect(employee, isNull);
    });
  });

  group('EmployeeRepository.byPin — the login keypad path', () {
    test('resolves to the one active employee holding that PIN', () async {
      final employee = await EmployeeRepository.instance.byPin(
        _otherCashierPin,
      );
      expect(employee?.id, _otherCashierId);
    });

    test('a deactivated employee cannot sign in by PIN either', () async {
      final row = await EmployeeRepository.instance.byId(_otherCashierId);
      await EmployeeRepository.instance.upsert(
        row!.copyWith(active: false),
      );

      expect(await EmployeeRepository.instance.byPin(_otherCashierPin), isNull);
    });
  });
}
