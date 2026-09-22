import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'v28 queues and till state survive the additive recovery migration',
    () async {
      await initFfi();
      final dir = await Directory.systemTemp.createTemp('nti_pos_v28_');
      final path = '${dir.path}${Platform.pathSeparator}legacy.db';
      addTearDown(() async {
        await deleteDatabase(path);
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      var db = await openDatabase(
        path,
        version: 28,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE _dead_letter(
          id INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL,
          entity_id TEXT NOT NULL, revision INTEGER NOT NULL,
          payload TEXT NOT NULL, code TEXT NOT NULL, message TEXT,
          details TEXT, rejected_at INTEGER NOT NULL)''');
          await db.execute('''CREATE TABLE _till_sessions(
          id TEXT PRIMARY KEY, state TEXT NOT NULL, employee_id TEXT NOT NULL,
          receipt_next INTEGER NOT NULL, receipt_end INTEGER NOT NULL)''');
        },
      );
      await db.insert('_dead_letter', {
        'entity': 'orders',
        'entity_id': 'order-1',
        'revision': 1,
        'payload': '{"id":"order-1"}',
        'code': 'session_closed',
        'rejected_at': 1,
      });
      await db.insert('_till_sessions', {
        'id': 'session-1',
        'state': 'active_confirmed',
        'employee_id': 'employee-1',
        'receipt_next': 1,
        'receipt_end': 100,
      });
      await db.close();

      db = await AppDatabase.openForTest(path: path, seed: false);
      addTearDown(db.close);
      expect(await db.query('_dead_letter'), hasLength(1));
      expect(await db.query('_till_sessions'), hasLength(1));
      expect(
        (await db.rawQuery(
          'PRAGMA table_info(_dead_letter)',
        )).map((r) => r['name']),
        contains('recovery_id'),
      );
      expect(
        (await db.rawQuery(
          'PRAGMA table_info(_till_sessions)',
        )).map((r) => r['name']),
        containsAll(['recovery_id', 'recovery_detected_at']),
      );
    },
  );
}
