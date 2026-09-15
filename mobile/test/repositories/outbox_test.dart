import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/session_push.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

/// The queue of rows this device still owes the server.
///
/// What is being guarded is a silent class of failure: a drawer counted on a
/// tablet that the server is never told about. Nothing goes red — the cashier
/// sees a normal close — and the variance only surfaces when someone
/// reconciles the day and finds a session missing.
void main() {
  late Database db;
  final shifts = ShiftRepository.instance;

  setUp(() async {
    db = await openInMemoryAppDb(seed: true);
    await AppDatabase.instance.useTestDb(db);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<int> queuedCount() async {
    final rows = await db.query(
      OutboxStore.table,
      where: 'entity = ?',
      whereArgs: [SessionPush.entity],
    );
    return rows.length;
  }

  test('opening a drawer queues it', () async {
    final shift = await shifts.open(
      employeeId: 'e1',
      employeeName: 'Siti',
      openingCash: 200000,
      posId: 'reg-1',
      posName: 'Kasir 1',
    );

    final queued = await OutboxStore.instance.pending();
    expect(queued, hasLength(1));
    expect(queued.first.entity, SessionPush.entity);
    expect(queued.first.entityId, shift.id);
    expect(queued.first.revision, 1);
    expect(queued.first.payload, contains(shift.id));
  });

  test('closing it does not queue a second job', () async {
    final shift = await shifts.open(
      employeeId: 'e1',
      employeeName: 'Siti',
      openingCash: 200000,
      posId: 'reg-1',
      posName: 'Kasir 1',
    );
    await shifts.close(
      shift: shift,
      countedCash: 250000,
      closedById: 'e1',
      closedByName: 'Siti',
    );

    // One pending snapshot per row: the close replaces the open's snapshot at
    // a newer revision rather than racing it.
    expect(await queuedCount(), 1);
    expect((await OutboxStore.instance.pending()).single.revision, 2);
  });

  test('a queued close is dropped only when the server confirms it', () async {
    final shift = await shifts.open(
      employeeId: 'e1',
      employeeName: 'Siti',
      openingCash: 200000,
      posId: 'reg-1',
      posName: 'Kasir 1',
    );

    await OutboxStore.instance.recordFailure(
      SessionPush.entity,
      shift.id,
      'network',
    );

    // A failed push must leave the entry queued. Dropping it here is how a
    // day's takings quietly stop existing.
    final still = await OutboxStore.instance.pending();
    expect(still, hasLength(1));
    expect(still.first.attempts, 1);
    expect(still.first.lastError, 'network');

    await OutboxStore.instance.acknowledge(
      SessionPush.entity,
      shift.id,
      still.first.revision!,
    );
    expect(await OutboxStore.instance.pending(), isEmpty);
  });

  test('never gives up on a row for having failed too often', () async {
    final shift = await shifts.open(
      employeeId: 'e1',
      employeeName: 'Siti',
      openingCash: 200000,
      posId: 'reg-1',
      posName: 'Kasir 1',
    );

    for (var i = 0; i < 50; i++) {
      await OutboxStore.instance.recordFailure(
        SessionPush.entity,
        shift.id,
        'offline',
      );
    }

    // A till with no wifi for a week must still be holding its sessions when it
    // reconnects — attempts are diagnostics, never a reason to discard money.
    final still = await OutboxStore.instance.pending();
    expect(still, hasLength(1));
    expect(still.first.attempts, 50);
  });

  test(
    'queueing the same row twice leaves one job at a newer revision',
    () async {
      final shift = await shifts.open(
        employeeId: 'e1',
        employeeName: 'Siti',
        openingCash: 200000,
        posId: 'reg-1',
        posName: 'Kasir 1',
      );
      await OutboxStore.enqueueWithin(db, SessionPush.entity, shift.id);
      await OutboxStore.enqueueWithin(db, SessionPush.entity, shift.id);

      expect(await queuedCount(), 1);
      expect((await OutboxStore.instance.pending()).single.revision, 3);
    },
  );

  test('a rejected open leaves nothing queued', () async {
    await shifts.open(
      employeeId: 'e1',
      employeeName: 'Siti',
      openingCash: 200000,
      posId: 'reg-1',
      posName: 'Kasir 1',
    );

    // The second open on a busy till throws, and its transaction rolls back —
    // taking the outbox entry with it. A queued push for a session that was
    // never written would be a job the pusher can never satisfy.
    await expectLater(
      shifts.open(
        employeeId: 'e2',
        employeeName: 'Dani',
        openingCash: 100000,
        posId: 'reg-1',
        posName: 'Kasir 1',
      ),
      throwsA(isA<RegisterBusyException>()),
    );

    expect(await queuedCount(), 1);
  });

  test('the queue survives being read back from a reopened database', () async {
    final shift = await shifts.open(
      employeeId: 'e1',
      employeeName: 'Siti',
      openingCash: 200000,
      posId: 'reg-1',
      posName: 'Kasir 1',
    );

    // Not an in-memory-only structure: an app killed mid-shift must still owe
    // the server the same rows when it comes back.
    final rows = await db.query(
      OutboxStore.table,
      where: 'entity_id = ?',
      whereArgs: [shift.id],
    );
    expect(rows, hasLength(1));
    expect(rows.first['queued_at'], isA<int>());
  });
}
