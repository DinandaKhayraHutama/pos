import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/repositories/customer_repository.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

void main() {
  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  test(
    'offline create keeps one UUID in row and create-only outbox payload',
    () async {
      final customer = await CustomerRepository.instance.create(
        name: '  Sari  ',
        phone: '0812 3456',
        email: 'sari@example.test',
      );
      final rows = await db.query('customers');
      expect(rows.single['id'], customer.id);
      expect(rows.single['name'], 'Sari');

      final pending = await OutboxStore.instance.pending(entity: 'customers');
      expect(pending, hasLength(1));
      final payload =
          jsonDecode(pending.single.payload!) as Map<String, dynamic>;
      expect(payload['id'], customer.id);
      expect(payload['name'], 'Sari');
      expect(payload.containsKey('revision'), isFalse);
    },
  );

  test(
    'search returns active customers and ignores deactivated rows',
    () async {
      final a = await CustomerRepository.instance.create(name: 'Sari');
      await CustomerRepository.instance.create(name: 'Budi');
      await db.update(
        'customers',
        {'active': 0},
        where: 'id = ?',
        whereArgs: [a.id],
      );
      expect(await CustomerRepository.instance.search('Sari'), isEmpty);
      expect(
        (await CustomerRepository.instance.search('Budi')).single.name,
        'Budi',
      );
    },
  );

  test('customer tombstone cannot cascade-delete financial history', () async {
    final customer = await CustomerRepository.instance.create(name: 'Sari');
    await db.insert('orders', {
      'id': 'order-1',
      'number': 'K1-1',
      'created_at': 1,
      'type': 'takeaway',
      'customer_id': customer.id,
      'subtotal': 1000,
      'total': 1000,
      'payment_method': 'cash',
      'status': 'paid',
      'cashier_id': 'c',
      'cashier_name': 'Cashier',
    });
    await db.delete('customers', where: 'id = ?', whereArgs: [customer.id]);
    expect((await db.query('orders')).single['customer_id'], customer.id);
  });
}
