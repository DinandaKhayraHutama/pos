import 'package:bcrypt/bcrypt.dart';
import '../device/till_coordinator.dart';
import '../sync/sync_client.dart';
import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/employee.dart';

/// The only place employees are read or written.
///
/// Same shape as every other repository here: swapping to a REST backend means
/// replacing these method bodies, not touching the model or any screen.
class EmployeeRepository {
  EmployeeRepository._();
  static final EmployeeRepository instance = EmployeeRepository._();

  Future<List<Employee>> all({bool onlyActive = false}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'employees',
      where: onlyActive ? 'active = 1' : null,
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(Employee.fromMap).toList();
  }

  Future<Employee?> byId(String id) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'employees',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Employee.fromMap(rows.first);
  }

  /// Resolves a typed PIN to the employee it belongs to.
  ///
  /// Only active employees can sign in — deactivating someone has to actually
  /// lock them out, otherwise the toggle is decoration. Returns null when no
  /// active employee owns that PIN, which the login screen shows as a wrong
  /// PIN rather than "no such user": telling an unknown person which PINs
  /// exist is not information a till should volunteer.
  Future<Employee?> byPin(String pin) async {
    for (final employee in await _activeEmployees()) {
      if (_matches(employee, pin)) return employee;
    }
    return null;
  }

  /// Checks [pin] against one specific employee.
  ///
  /// The counterpart to [byPin], for the flow where an account was picked
  /// first. It has to be scoped to that account: with a global lookup, tapping
  /// the cashier's tile and typing the owner's PIN would sign the owner in —
  /// the app would quietly ignore the choice the person just made.
  ///
  /// Same `active = 1` guard as [byPin], so a deactivated account cannot be
  /// signed into from either route.
  Future<Employee?> verify({required String id, required String pin}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'employees',
      where: 'id = ? AND active = 1',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final employee = Employee.fromMap(rows.first);
    if (!_matches(employee, pin)) return null;
    final coordinator = TillCoordinator.current;
    if (coordinator != null) {
      try {
        await coordinator.authenticate(id, pin);
      } on SyncException catch (e) {
        // Offline PIN login can resume an already confirmed local assignment.
        // An online denial must never be treated as an offline allowance.
        if (e.failure != SyncFailure.network) return null;
      }
    }
    return employee;
  }

  /// True when [pin] is already taken by someone other than [exceptId].
  ///
  /// Two people sharing a PIN would silently attribute every sale to whoever
  /// the query happened to return first, so the form blocks it up front.
  Future<bool> isPinTaken(String pin, {String? exceptId}) async {
    for (final employee in await _activeEmployees()) {
      if (employee.id == exceptId) continue;
      if (_matches(employee, pin)) return true;
    }
    return false;
  }

  /// Every active account, for the PIN comparisons that cannot be a query.
  ///
  /// A bcrypt hash is salted, so the same PIN produces a different string every
  /// time and `WHERE pin_hash = ?` can never match. Resolving a PIN therefore
  /// means comparing against each candidate in turn. The set is one shop's
  /// staff — a handful of rows — so this stays cheap.
  Future<List<Employee>> _activeEmployees() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'employees',
      where: 'active = 1',
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(Employee.fromMap).toList();
  }

  /// Does [pin] unlock [employee]?
  ///
  /// Hash first, plain text only as a fallback — and the fallback exists purely
  /// so a device that has not synced yet still lets its cashiers in. An account
  /// that carries a hash NEVER falls back: once the server owns a credential,
  /// a stale plain-text column must not be a second way past it.
  bool _matches(Employee employee, String pin) {
    if (employee.usesHashedPin) {
      try {
        return BCrypt.checkpw(pin, employee.pinHash!);
      } catch (_) {
        // Catches Error as well as Exception, deliberately: a malformed hash
        // makes bcrypt throw a RangeError, not an Exception, and `on Exception`
        // let it escape and take the login screen down for everyone.
        //
        // A corrupt row is not a valid sign-in, so the only safe reading of any
        // failure here is "denied".
        return false;
      }
    }

    return employee.pin.isNotEmpty && employee.pin == pin;
  }

  Future<void> upsert(Employee employee) async {
    final db = await AppDatabase.instance.db;
    await db.insert(
      'employees',
      employee.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String id) async {
    final db = await AppDatabase.instance.db;
    await db.delete('employees', where: 'id = ?', whereArgs: [id]);
  }
}
