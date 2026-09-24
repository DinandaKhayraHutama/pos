import 'package:sqflite/sqflite.dart';

class CustomerPush {
  const CustomerPush._();
  static const entity = 'customers';

  static Future<Map<String, Object?>?> payloadWithin(
    DatabaseExecutor txn,
    String id,
  ) async {
    final rows = await txn.query(
      'customers',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'id': row['id'],
      'name': row['name'],
      'phone': row['phone'],
      'email': row['email'],
      'address': row['address'],
      'note': row['note'],
    };
  }
}
