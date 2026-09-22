import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/device_registration.dart';
import 'package:nti_pos/data/device/till_coordinator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

DeviceRegistration _registration() => DeviceRegistration(
  baseUrl: 'https://pos.test/api/v2',
  token: 'tok',
  expiresAt: DateTime.utc(2030),
  device: {'id': 'device-1', 'device_uuid': 'installation'},
  tenant: {'id': 'tenant-1', 'name': 'Business'},
  outlet: {'id': 'outlet-1', 'name': 'Branch'},
  register: {'id': 'register-1', 'outlet_id': 'outlet-1', 'name': 'Kasir 1'},
);

class _ScriptedTillCoordinator extends TillCoordinator {
  _ScriptedTillCoordinator(super.binding, this.responses);

  final List<Map<String, dynamic>> responses;

  @override
  Future<Map<String, dynamic>> call(
    String employee,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    expect(path, '/till/sessions/current');
    expect(query?['local_session_id'], 'session-1');
    return responses.removeAt(0);
  }
}

/// `TillCoordinator.holdsPermit` is the single answer to "may this device sell
/// into this drawer", and these are the states where `shifts` and the server
/// disagree.
///
/// The bug it was extracted for: the till picker read `shifts` while the POS
/// context resolver read `_till_sessions`. A drawer that was open locally but
/// held no confirmed claim was offered as "Resume", and the tap resolved
/// straight back to "no session" — no error, no state change, and no way off
/// the screen. That state is reachable in production: a session that reached
/// the server through the legacy push path never gets a `till_claims` row.
void main() {
  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    TillCoordinator.current = TillCoordinator(_registration());
  });

  tearDown(() async {
    TillCoordinator.current?.client.close();
    TillCoordinator.current = null;
    if (db.isOpen) await db.close();
  });

  Future<void> openShift({int? closedAt}) => db.insert('shifts', {
    'id': 'session-1',
    'employee_id': 'employee-1',
    'employee_name': 'Sari',
    'pos_id': 'register-1',
    'opened_at': 1,
    'opening_cash': 0,
    'closed_at': closedAt,
  });

  Future<void> permit({
    String state = 'active_confirmed',
    String employee = 'employee-1',
  }) => db.insert('_till_sessions', {
    'id': 'session-1',
    'state': state,
    'employee_id': employee,
    'receipt_next': 1,
    'receipt_end': 100,
  });

  _ScriptedTillCoordinator scripted(List<Map<String, dynamic>> responses) {
    TillCoordinator.current?.client.close();
    final coordinator = _ScriptedTillCoordinator(_registration(), responses);
    TillCoordinator.current = coordinator;
    return coordinator;
  }

  test('a confirmed drawer may be sold into', () async {
    await openShift();
    await permit();
    expect(
      await TillCoordinator.holdsPermit(db, 'session-1', 'employee-1'),
      isTrue,
    );
  });

  test('an open drawer the server never claimed may not', () async {
    // Exactly the production state: `shifts` is open, `_till_sessions` has no
    // row at all because the session never went through /till/sessions/open.
    await openShift();
    expect(
      await TillCoordinator.holdsPermit(db, 'session-1', 'employee-1'),
      isFalse,
    );
    await expectLater(
      TillCoordinator.assertSellable(db, 'session-1', 'employee-1'),
      throwsA(isA<TillOperationException>()),
    );
  });

  test('a force-closed or conflicted drawer may not', () async {
    await openShift();
    await permit(state: 'recovery_required');
    expect(
      await TillCoordinator.holdsPermit(db, 'session-1', 'employee-1'),
      isFalse,
    );
    await db.update('_till_sessions', {'state': 'conflict'});
    expect(
      await TillCoordinator.holdsPermit(db, 'session-1', 'employee-1'),
      isFalse,
    );
    await db.update('_till_sessions', {'state': 'closing_pending'});
    expect(
      await TillCoordinator.holdsPermit(db, 'session-1', 'employee-1'),
      isFalse,
      reason: 'a close in flight is not a licence to ring up more',
    );
  });

  test('a drawer confirmed for somebody else may not', () async {
    await openShift();
    await permit(employee: 'employee-2');
    expect(
      await TillCoordinator.holdsPermit(db, 'session-1', 'employee-1'),
      isFalse,
    );
  });

  test('a locally closed drawer may not, however confirmed', () async {
    await openShift(closedAt: 99);
    await permit();
    expect(
      await TillCoordinator.holdsPermit(db, 'session-1', 'employee-1'),
      isFalse,
    );
  });

  test('a missing session is never a permit', () async {
    expect(await TillCoordinator.holdsPermit(db, null, 'employee-1'), isFalse);
    expect(await TillCoordinator.holdsPermit(db, '', 'employee-1'), isFalse);
    expect(
      await TillCoordinator.holdsPermit(db, 'nope', 'employee-1'),
      isFalse,
    );
  });

  // `recover` asks the server about the drawer `pendingDrawer` returns, so a
  // drawer it cannot see can never be reconciled. The original query started
  // `FROM _till_sessions JOIN shifts`, which could not see a shift opened by a
  // build from before coordinated tills existed — no permit row was ever
  // written for it. That drawer was unresumable AND uncloseable, and even
  // re-activating the device did not clear it.
  group('pendingDrawer', () {
    TillCoordinator coordinator() => TillCoordinator.current!;

    test('sees an open shift that has no permit row at all', () async {
      await openShift();
      expect(
        await coordinator().pendingDrawer(db, 'employee-1'),
        'session-1',
        reason: 'the legacy-push drawer is exactly what needs an answer',
      );
      // Any cashier on this device may have it reconciled: the drawer blocks
      // the register for everyone, and mirroring a server closure is not
      // inheriting somebody's till.
      expect(await coordinator().pendingDrawer(db, 'employee-2'), 'session-1');
    });

    test(
      'sees its own confirmed drawer, so a normal resume still works',
      () async {
        await openShift();
        await permit();
        expect(
          await coordinator().pendingDrawer(db, 'employee-1'),
          'session-1',
        );
      },
    );

    test(
      'keeps a conflicted drawer visible after a later manager takeover',
      () async {
        await openShift();
        await permit(state: 'conflict');

        // The first check can legitimately precede the manager's takeover and
        // therefore find no recovery case. The next check must still send the
        // same local_session_id so the newly-created case can be discovered.
        expect(
          await coordinator().pendingDrawer(db, 'employee-1'),
          'session-1',
        );
        expect(
          await coordinator().pendingDrawer(db, 'employee-2'),
          'session-1',
          reason: 'conflict is not another cashier selling permit',
        );

        await db.update('_till_sessions', {'state': 'recovery_required'});
        expect(
          await coordinator().pendingDrawer(db, 'employee-2'),
          'session-1',
          reason: 'an interrupted close must remain recoverable too',
        );
      },
    );

    test(
      'conflict before takeover resolves after takeover creates a case',
      () async {
        await openShift();
        final coordinator = scripted([
          {'data': null, 'recovery': null},
          {
            'data': null,
            'recovery': {'id': 'recovery-1', 'forced_at_ms': 200},
          },
        ]);

        expect(
          await coordinator.recover('employee-1'),
          TillRecoveryOutcome.conflict,
        );
        expect((await db.query('_till_sessions')).single['state'], 'conflict');
        expect((await db.query('shifts')).single['closed_at'], isNull);

        expect(
          await coordinator.recover('employee-2'),
          TillRecoveryOutcome.recoveryRequired,
        );
        final permitRow = (await db.query('_till_sessions')).single;
        expect(permitRow['state'], 'recovery_required');
        expect(permitRow['recovery_id'], 'recovery-1');
        expect((await db.query('shifts')).single['closed_at'], 200);
        expect(coordinator.responses, isEmpty);
      },
    );

    test('a confirmed server claim clears a provisional conflict', () async {
      await openShift();
      await permit(state: 'conflict');
      final coordinator = scripted([
        {
          'data': {
            'session': {
              'id': 'session-1',
              'employee_id': 'employee-1',
              'employee_name': 'Sari',
              'pos_name': 'Kasir 1',
              'outlet_name': 'Branch',
              'opened_at_ms': 1,
              'opening_cash': 0,
              'closed_at_ms': null,
            },
            'current_employee_id': 'employee-1',
            'receipt_start': 1,
            'receipt_end': 100,
          },
        },
      ]);

      expect(
        await coordinator.recover('employee-1'),
        TillRecoveryOutcome.active,
      );
      expect(
        (await db.query('_till_sessions')).single['state'],
        'active_confirmed',
      );
    });

    test('leaves a drawer whose permit names another cashier alone', () async {
      await openShift();
      await permit(employee: 'employee-2');
      expect(
        await coordinator().pendingDrawer(db, 'employee-1'),
        isNull,
        reason: 'it may be legitimately held after a handover',
      );
    });

    test('ignores a drawer already closed locally', () async {
      await openShift(closedAt: 99);
      expect(await coordinator().pendingDrawer(db, 'employee-1'), isNull);
    });

    test('ignores a drawer on another register', () async {
      await db.insert('shifts', {
        'id': 'session-elsewhere',
        'employee_id': 'employee-1',
        'employee_name': 'Sari',
        'pos_id': 'register-2',
        'opened_at': 1,
        'opening_cash': 0,
      });
      expect(await coordinator().pendingDrawer(db, 'employee-1'), isNull);
    });

    // There is never a choice to make between two open drawers on one
    // register: `shifts(pos_id) WHERE closed_at IS NULL` is a partial unique
    // index, so a second one cannot be written. The `ORDER BY (t.id IS NULL)`
    // in the query is therefore defensive, not load-bearing — recorded here so
    // nobody removes the index believing the ordering covers for it.
    test('one register can only have one open drawer to ask about', () async {
      await openShift();
      await permit();
      await expectLater(
        db.insert('shifts', {
          'id': 'session-stranded',
          'employee_id': 'employee-1',
          'employee_name': 'Sari',
          'pos_id': 'register-1',
          'opened_at': 99,
          'opening_cash': 0,
        }),
        throwsA(isA<DatabaseException>()),
      );
      expect(await coordinator().pendingDrawer(db, 'employee-1'), 'session-1');
    });
  });

  test(
    'demo mode has no server to confirm anything, so shifts is truth',
    () async {
      TillCoordinator.current?.client.close();
      TillCoordinator.current = null;
      await openShift();
      expect(
        await TillCoordinator.holdsPermit(db, 'session-1', 'employee-1'),
        isTrue,
      );
      await TillCoordinator.assertSellable(db, 'session-1', 'employee-1');
    },
  );
}
