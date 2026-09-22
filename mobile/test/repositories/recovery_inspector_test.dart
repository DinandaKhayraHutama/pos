import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/recovery/recovery_inspector.dart';
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
    'an empty queue is not healthy while a recovery session remains',
    () async {
      await db.insert('shifts', {
        'id': 'session-1',
        'employee_id': 'employee-1',
        'employee_name': 'Sari',
        'pos_id': 'register-1',
        'opened_at': 1,
        'opening_cash': 0,
        'closed_at': 2,
      });
      await db.insert('_till_sessions', {
        'id': 'session-1',
        'state': 'recovery_required',
        'employee_id': 'employee-1',
        'receipt_next': 1,
        'receipt_end': 10,
        'recovery_id': 'recovery-1',
      });

      final result = await RecoveryInspector.instance.inspect();

      expect(result.pending, isEmpty);
      expect(result.deadLetters, isEmpty);
      expect(result.status, RecoveryClassification.recoveryRequired);
      expect(
        result.diagnostics.map((e) => e.code),
        contains('session_recovery_required'),
      );
    },
  );
}
