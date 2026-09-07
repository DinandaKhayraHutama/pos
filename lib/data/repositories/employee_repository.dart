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
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'employees',
      where: 'pin = ? AND active = 1',
      whereArgs: [pin],
      limit: 1,
    );
    return rows.isEmpty ? null : Employee.fromMap(rows.first);
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
      where: 'id = ? AND pin = ? AND active = 1',
      whereArgs: [id, pin],
      limit: 1,
    );
    return rows.isEmpty ? null : Employee.fromMap(rows.first);
  }

  /// True when [pin] is already taken by someone other than [exceptId].
  ///
  /// Two people sharing a PIN would silently attribute every sale to whoever
  /// the query happened to return first, so the form blocks it up front.
  Future<bool> isPinTaken(String pin, {String? exceptId}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'employees',
      where: exceptId == null ? 'pin = ?' : 'pin = ? AND id != ?',
      whereArgs: exceptId == null ? [pin] : [pin, exceptId],
      limit: 1,
    );
    return rows.isNotEmpty;
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
