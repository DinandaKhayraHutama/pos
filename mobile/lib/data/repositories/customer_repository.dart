import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/customer.dart';
import '../sync/customer_push.dart';
import '../sync/outbox_store.dart';

class CustomerRepository {
  CustomerRepository._();
  static final instance = CustomerRepository._();
  static const _uuid = Uuid();

  Future<List<Customer>> search(String query, {int limit = 50}) async {
    final db = await AppDatabase.instance.db;
    final q = query.trim();
    final rows = await db.query(
      'customers',
      where: q.isEmpty
          ? 'active = 1'
          : 'active = 1 AND (name LIKE ? OR phone LIKE ? OR email LIKE ?)',
      whereArgs: q.isEmpty ? null : List.filled(3, '%$q%'),
      orderBy: 'name COLLATE NOCASE',
      limit: limit,
    );
    return rows.map(Customer.fromMap).toList();
  }

  /// Creates locally first and queues the exact same UUID atomically. This is
  /// the offline guarantee: reconnecting changes neither identity nor order.
  Future<Customer> create({
    required String name,
    String? phone,
    String? email,
  }) async {
    final clean = name.trim();
    if (clean.isEmpty) throw ArgumentError.value(name, 'name', 'required');
    final customer = Customer(
      id: _uuid.v4(),
      name: clean,
      phone: _optional(phone),
      email: _optional(email),
    );
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      await txn.insert(
        'customers',
        customer.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      await OutboxStore.enqueueWithin(txn, CustomerPush.entity, customer.id);
    });
    return customer;
  }

  static String? _optional(String? value) {
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }
}
