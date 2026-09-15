import 'package:bcrypt/bcrypt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/employee.dart';
import 'package:nti_pos/data/repositories/employee_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

/// Signing in at the till, with no network.
///
/// This is the whole point of syncing staff down: a cashier the Owner created
/// in a browser yesterday must be able to work today on a tablet that has been
/// offline since. Every case here runs against local SQLite only — nothing in
/// this file may reach a server, because the till cannot either.
void main() {
  late Database db;
  final repo = EmployeeRepository.instance;

  String hash(String pin) => BCrypt.hashpw(pin, BCrypt.gensalt());

  Future<void> insert(Employee employee) async {
    await db.insert('employees', employee.toMap());
  }

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  group('a synced account (hash only)', () {
    setUp(() async {
      await insert(
        Employee(
          id: 'e1',
          name: 'Siti',
          pin: '', // no plain text — this account came from the server
          pinHash: hash('2345'),
          role: EmployeeRole.cashier,
        ),
      );
    });

    test('signs in with the right PIN, offline', () async {
      expect(await repo.verify(id: 'e1', pin: '2345'), isNotNull);
    });

    test('refuses the wrong PIN', () async {
      expect(await repo.verify(id: 'e1', pin: '9999'), isNull);
    });

    test('is found by PIN alone, for the manager override', () async {
      final found = await repo.byPin('2345');
      expect(found?.id, 'e1');
    });

    test('stores nothing that reveals the PIN', () async {
      final row = (await db.query('employees', where: 'id = ?', whereArgs: ['e1'])).first;
      expect(row['pin'], '');
      expect(row['pin_hash'], isNot(contains('2345')));
    });
  });

  group('a legacy account (plain text only)', () {
    setUp(() async {
      await insert(
        const Employee(
          id: 'e2',
          name: 'Dani',
          pin: '3456',
          role: EmployeeRole.cashier,
        ),
      );
    });

    test('still signs in — a device that has never synced is not locked out', () async {
      // The reason both columns exist. Dropping plain text would strand every
      // cashier on exactly the till that most needs to keep selling.
      expect(await repo.verify(id: 'e2', pin: '3456'), isNotNull);
    });

    test('refuses the wrong PIN', () async {
      expect(await repo.verify(id: 'e2', pin: '0000'), isNull);
    });
  });

  test('a hashed account never falls back to a stale plain-text PIN', () async {
    // The dangerous case: a row that has BOTH, because it was adopted with a
    // plain-text PIN and later synced. Once the server owns the credential, the
    // old column must not be a second way in.
    await insert(
      Employee(
        id: 'e3',
        name: 'Rotated',
        pin: '1111', // what it used to be
        pinHash: hash('2222'), // what the Owner set in the Backoffice
        role: EmployeeRole.cashier,
      ),
    );

    expect(await repo.verify(id: 'e3', pin: '2222'), isNotNull);
    expect(await repo.verify(id: 'e3', pin: '1111'), isNull);
  });

  test('verification is scoped to the chosen account', () async {
    await insert(
      Employee(id: 'a', name: 'Siti', pinHash: hash('2345'), role: EmployeeRole.cashier),
    );
    await insert(
      Employee(id: 'b', name: 'Dani', pinHash: hash('3456'), role: EmployeeRole.cashier),
    );

    // Tapping one name and typing another person's PIN must fail, or the
    // account choice is theatre and the sale is attributed to the wrong person.
    expect(await repo.verify(id: 'a', pin: '3456'), isNull);
    expect(await repo.verify(id: 'a', pin: '2345'), isNotNull);
  });

  test('a deactivated account cannot sign in by either route', () async {
    await insert(
      Employee(
        id: 'gone',
        name: 'Former',
        pinHash: hash('2345'),
        role: EmployeeRole.cashier,
        active: false,
      ),
    );

    expect(await repo.verify(id: 'gone', pin: '2345'), isNull);
    expect(await repo.byPin('2345'), isNull);
  });

  test('a corrupt hash denies rather than crashing the login screen', () async {
    await insert(
      const Employee(
        id: 'bad',
        name: 'Corrupt',
        pinHash: 'not-a-bcrypt-hash',
        role: EmployeeRole.cashier,
      ),
    );

    expect(await repo.verify(id: 'bad', pin: '2345'), isNull);
  });

  test('PIN uniqueness works across hashed and legacy accounts alike', () async {
    await insert(
      Employee(id: 'h', name: 'Hashed', pinHash: hash('2345'), role: EmployeeRole.cashier),
    );
    await insert(
      const Employee(id: 'p', name: 'Plain', pin: '3456', role: EmployeeRole.cashier),
    );

    expect(await repo.isPinTaken('2345'), isTrue);
    expect(await repo.isPinTaken('3456'), isTrue);
    expect(await repo.isPinTaken('9999'), isFalse);
    // Editing someone must not collide with themselves.
    expect(await repo.isPinTaken('2345', exceptId: 'h'), isFalse);
  });

  test('an empty PIN never matches an account with no credential', () async {
    await insert(
      const Employee(id: 'none', name: 'No creds', pin: '', role: EmployeeRole.manager),
    );

    expect(await repo.verify(id: 'none', pin: ''), isNull);
    expect(await repo.byPin(''), isNull);
  });
}
