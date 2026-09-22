import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/database/db_platform.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'desktop production factory persists data across a real reopen',
    () async {
      if (!Platform.isWindows && !Platform.isLinux) return;

      configureDatabaseFactory();
      final dir = await Directory.systemTemp.createTemp('nti_pos_native_db_');
      final path = '${dir.path}${Platform.pathSeparator}connected_test.db';
      addTearDown(() async {
        await deleteDatabase(path);
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      var db = await AppDatabase.openForTest(path: path, seed: false);
      await db.insert('categories', {
        'id': 'category-1',
        'name': 'Persisted category',
      });
      await db.insert('_outbox', {
        'entity': 'categories',
        'entity_id': 'category-1',
        'revision': 1,
        'payload': '{"id":"category-1","revision":1}',
        'queued_at': 1,
      });
      await db.insert('_dead_letter', {
        'entity': 'orders',
        'entity_id': '00000000-0000-4000-8000-000000000001',
        'revision': 1,
        'payload': '{}',
        'code': 'schema_rejected',
        'rejected_at': 2,
      });
      await db.close();

      db = await AppDatabase.openForTest(path: path, seed: false);
      addTearDown(db.close);
      expect(
        (await db.query(
          'categories',
          where: 'id = ?',
          whereArgs: ['category-1'],
        )).single['name'],
        'Persisted category',
      );
      expect((await db.query('_outbox')).length, 1);
      expect((await db.query('_dead_letter')).length, 1);
      expect(
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')),
        AppDatabase.currentVersion,
      );
      expect(
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA foreign_keys')),
        1,
      );
    },
  );
}
