import '../database/app_database.dart';
import '../models/employee_role.dart';

class EmployeeRoleRepository {
  EmployeeRoleRepository._();
  static final instance = EmployeeRoleRepository._();

  Future<EmployeeRoleDefinition?> byId(String? id) async {
    if (id == null || id.isEmpty) return null;
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'roles',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : EmployeeRoleDefinition.fromMap(rows.first);
  }
}
