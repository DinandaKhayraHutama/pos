import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/core/auth/permissions.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/preferences/app_preferences.dart';
import 'package:nti_pos/providers/settings_provider.dart';

import '../helpers/db_helper.dart';
import '../helpers/provider_helpers.dart';

/// A pull that changes the signed-in person's role or status reaches the
/// live session (Fase 3). Removed, deactivated or locked out of the POS means
/// signed out — never the permissive owner default a standalone till keeps.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late ProviderContainer container;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    await db.insert('roles', {
      'id': 'r_stock',
      'name': 'Gudang',
      'permissions': 'adjustStock',
      'pos_access': 1,
    });
    await db.insert('employees', {
      'id': 'e1',
      'name': 'Siti',
      'role': 'cashier',
      'active': 1,
    });
    AppPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({
      'employee_id': 'e1',
      'cashier_name': 'Siti',
      'logged_in': true,
    });
    container = makeContainer();
  });

  tearDown(() async {
    container.dispose();
    if (db.isOpen) await db.close();
  });

  Future<SettingsState> refresh() async {
    await container.read(settingsProvider.notifier).refreshSignedInEmployee();
    return container.read(settingsProvider).requireValue;
  }

  test('a cashier signs in as a cashier', () async {
    final state = await container.read(settingsProvider.future);
    expect(state.loggedIn, isTrue);
    expect(state.can(AppPermission.sell), isTrue);
    expect(state.can(AppPermission.manageEmployees), isFalse);
  });

  test('a role change applies to the live session', () async {
    await container.read(settingsProvider.future);
    await db.update(
      'employees',
      {'role': 'custom', 'role_id': 'r_stock'},
      where: 'id = ?',
      whereArgs: ['e1'],
    );
    final state = await refresh();
    expect(state.loggedIn, isTrue);
    expect(state.can(AppPermission.adjustStock), isTrue);
    expect(state.can(AppPermission.sell), isFalse);
    expect(state.homeRoute, '/settings');
  });

  test('a deactivated employee is signed out', () async {
    await container.read(settingsProvider.future);
    await db.update(
      'employees',
      {'active': 0},
      where: 'id = ?',
      whereArgs: ['e1'],
    );
    final state = await refresh();
    expect(state.loggedIn, isFalse);
    expect(state.employeeId, isEmpty);
  });

  test('a removed employee is signed out, not promoted to owner', () async {
    await container.read(settingsProvider.future);
    await db.delete('employees', where: 'id = ?', whereArgs: ['e1']);
    final state = await refresh();
    expect(state.loggedIn, isFalse);
  });

  test('a role that cannot open the POS signs its holder out', () async {
    await db.update('roles', {'pos_access': 0});
    await db.update(
      'employees',
      {'role': 'custom', 'role_id': 'r_stock'},
      where: 'id = ?',
      whereArgs: ['e1'],
    );
    // On a cold start as well: the remembered identity is not let back in.
    final state = await container.read(settingsProvider.future);
    expect(state.loggedIn, isFalse);
    expect(state.can(AppPermission.sell), isFalse);
  });

  test('a custom role whose row has not arrived yet grants nothing', () async {
    await db.update(
      'employees',
      {'role': 'custom', 'role_id': 'r_unknown'},
      where: 'id = ?',
      whereArgs: ['e1'],
    );
    final state = await container.read(settingsProvider.future);
    expect(state.loggedIn, isFalse);
    expect(state.permissions, isEmpty);
  });
}
