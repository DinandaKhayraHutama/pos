import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

/// The v30 upgrade (paritas F1) has to leave everything that holds money or
/// owes the server work exactly as it found it, and rebuild only the ONE table
/// that is a read cache.
///
/// The rebuild is the part worth guarding: `_remote_orders` gains the viewer in
/// its primary key, which SQLite cannot do in place, so the table is recreated
/// and its rows copied. A migration that dropped them instead would still look
/// green on a fresh install and quietly lose an offline till's downloaded
/// history on a real one.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v29 queues survive v30, and the remote cache is rebuilt not dropped', () async {
    await initFfi();
    final dir = await Directory.systemTemp.createTemp('nti_pos_v29_');
    final path = '${dir.path}${Platform.pathSeparator}legacy.db';
    addTearDown(() async {
      await deleteDatabase(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    var db = await openDatabase(
      path,
      version: 29,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE _outbox(
          id INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL,
          entity_id TEXT NOT NULL, revision INTEGER NOT NULL,
          payload TEXT NOT NULL, queued_at INTEGER NOT NULL)''');
        await db.execute('''CREATE TABLE _dead_letter(
          id INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT NOT NULL,
          entity_id TEXT NOT NULL, revision INTEGER NOT NULL,
          payload TEXT NOT NULL, code TEXT NOT NULL, message TEXT,
          details TEXT, rejected_at INTEGER NOT NULL, recovery_id TEXT)''');
        await db.execute('''CREATE TABLE _till_sessions(
          id TEXT PRIMARY KEY, state TEXT NOT NULL, employee_id TEXT NOT NULL,
          receipt_next INTEGER NOT NULL, receipt_end INTEGER NOT NULL,
          recovery_id TEXT, recovery_detected_at INTEGER)''');
        // The v29 shape: keyed by receipt alone, with no scope columns.
        await db.execute('''CREATE TABLE _remote_orders(
          id TEXT PRIMARY KEY, employee_id TEXT NOT NULL,
          business_date TEXT NOT NULL, payload TEXT NOT NULL,
          fetched_at INTEGER NOT NULL)''');
      },
    );
    await db.insert('_outbox', {
      'entity': 'orders',
      'entity_id': 'order-queued',
      'revision': 1,
      'payload': '{"id":"order-queued"}',
      'queued_at': 1,
    });
    await db.insert('_dead_letter', {
      'entity': 'orders',
      'entity_id': 'order-refused',
      'revision': 2,
      'payload': '{"id":"order-refused"}',
      'code': 'session_closed',
      'rejected_at': 1,
    });
    await db.insert('_till_sessions', {
      'id': 'session-1',
      'state': 'active_confirmed',
      'employee_id': 'employee-1',
      'receipt_next': 7,
      'receipt_end': 100,
    });
    await db.insert('_remote_orders', {
      'id': 'order-remote',
      'employee_id': 'employee-1',
      'business_date': '2026-09-20',
      'payload':
          '{"id":"order-remote","status":"paid","placed_at_ms":1758326400000,'
          '"pos_id":"register-1","cashier_id":"employee-9"}',
      'fetched_at': 42,
    });
    await db.close();

    db = await AppDatabase.openForTest(path: path, seed: false);
    addTearDown(db.close);

    // Nothing that owes the server work was touched.
    expect(await db.query('_outbox'), hasLength(1));
    expect(await db.query('_dead_letter'), hasLength(1));
    final session = (await db.query('_till_sessions')).single;
    expect(session['receipt_next'], 7, reason: 'the receipt block is untouched');
    expect(session['receipt_end'], 100);

    // The cached receipt came across, and the columns the new reads need were
    // derived from the payload the server had already sent.
    final cached = (await db.query('_remote_orders')).single;
    expect(cached['id'], 'order-remote');
    expect(cached['employee_id'], 'employee-1');
    expect(cached['business_date'], '2026-09-20');
    expect(cached['scope'], 'register');
    expect(cached['register_id'], 'register-1');
    expect(cached['cashier_id'], 'employee-9');
    expect(cached['status'], 'paid');
    expect(cached['placed_at_ms'], 1758326400000);
    expect(cached['fetched_at'], 42, reason: 'when it was downloaded is kept');

    // The new key is (receipt, viewer): one receipt can now be cached for two
    // people without either overwriting the other.
    await db.insert('_remote_orders', {
      'id': 'order-remote',
      'employee_id': 'employee-2',
      'business_date': '2026-09-20',
      'scope': 'outlet',
      'payload': '{"id":"order-remote"}',
      'fetched_at': 43,
    });
    expect(await db.query('_remote_orders'), hasLength(2));

    // And the two tables the F1 screens read from exist.
    expect(await db.query('_remote_history_meta'), isEmpty);
    expect(await db.query('_remote_reports'), isEmpty);
  });

  test('a fresh install creates the F1 cache tables', () async {
    await initFfi();
    final dir = await Directory.systemTemp.createTemp('nti_pos_fresh_');
    final path = '${dir.path}${Platform.pathSeparator}fresh.db';
    addTearDown(() async {
      await deleteDatabase(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    final db = await AppDatabase.openForTest(path: path, seed: false);
    addTearDown(db.close);

    expect(await db.query('_remote_orders'), isEmpty);
    expect(await db.query('_remote_history_meta'), isEmpty);
    expect(await db.query('_remote_reports'), isEmpty);
    // A fresh store and a migrated one must end up with the same columns, or
    // a query written against one crashes on the other.
    expect(
      (await db.rawQuery('PRAGMA table_info(_remote_orders)')).map((r) => r['name']),
      containsAll([
        'id',
        'employee_id',
        'business_date',
        'scope',
        'register_id',
        'cashier_id',
        'status',
        'placed_at_ms',
        'payload',
        'fetched_at',
      ]),
    );
  });
}
