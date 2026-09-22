import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/shift.dart';
import '../sync/outbox_store.dart';
import '../sync/sync_client.dart';
import 'device_registration.dart';

class TillOperationException implements Exception {
  const TillOperationException(this.code);
  final String code;
  @override
  String toString() => code;
}

/// The server verdict after checking a local drawer during sign-in or a
/// manual reconciliation from the register picker.
enum TillRecoveryOutcome { noPendingDrawer, active, conflict, recoveryRequired }

/// A device credential activates an installation. A cashier credential permits
/// reading that person's history and requesting ownership of a drawer.
class TillCoordinator {
  TillCoordinator(this.binding)
    : client = SyncClient(baseUrl: binding.baseUrl, token: binding.token);
  static TillCoordinator? current;
  final DeviceRegistration binding;
  final SyncClient client;
  static const _storage = FlutterSecureStorage();
  String _key(String employee) => 'till_${binding.storageScope}_$employee';

  Future<void> authenticate(String employee, String pin) async {
    final res = await client.post('/till/login', {
      'employee_id': employee,
      'pin': pin,
    });
    final data = res['data'] as Map<String, dynamic>;
    await _storage.write(key: _key(employee), value: jsonEncode(data));
  }

  Future<SyncClient> _as(String employee) async {
    final raw = await _storage.read(key: _key(employee));
    if (raw == null) {
      throw const TillOperationException('cashier_auth_required');
    }
    final data = jsonDecode(raw) as Map<String, dynamic>;
    if ((data['expires_at_ms'] as int) <=
        DateTime.now().millisecondsSinceEpoch) {
      throw const TillOperationException('cashier_auth_required');
    }
    // Each operation owns its headers; simultaneous history/open requests may
    // never borrow a manager's credential while another cashier signs in.
    return SyncClient(baseUrl: binding.baseUrl, token: binding.token)
      ..extraHeaders = {'X-Cashier-Token': data['token'] as String};
  }

  Future<Map<String, dynamic>> call(
    String employee,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final api = await _as(employee);
    try {
      return body == null
          ? await api.get(path, query)
          : await api.post(path, body);
    } on SyncException catch (e) {
      throw TillOperationException(e.detail ?? e.failure.name);
    } finally {
      api.close();
    }
  }

  Future<Shift> open(Shift proposed) async {
    final db = await AppDatabase.instance.db;
    // Persist BEFORE calling the server. A lost response reuses precisely this
    // opening snapshot and id, including after a process restart.
    late Map<String, dynamic> payload;
    await db.transaction((tx) async {
      final pending = await tx.query(
        '_till_open_requests',
        where: 'register_id = ?',
        whereArgs: [proposed.posId],
      );
      if (pending.isNotEmpty) {
        payload =
            jsonDecode(pending.first['payload'] as String)
                as Map<String, dynamic>;
        if (payload['employee_id'] != proposed.employeeId) {
          throw const TillOperationException('opening_pending');
        }
      } else {
        payload = {
          'id': proposed.id,
          'revision': 1,
          'employee_id': proposed.employeeId,
          'employee_name': proposed.employeeName,
          'pos_name': proposed.posName,
          'outlet_name': proposed.outletName,
          'opened_at_ms': proposed.openedAt.millisecondsSinceEpoch,
          'opening_cash': proposed.openingCash,
        };
        await tx.insert('_till_open_requests', {
          'register_id': proposed.posId,
          'payload': jsonEncode(payload),
        });
      }
    });
    final response = await call(
      proposed.employeeId,
      '/till/sessions/open',
      body: payload,
    );
    return _save(response['data'] as Map<String, dynamic>);
  }

  Future<Shift> _save(Map<String, dynamic> data) async {
    final s = data['session'] as Map<String, dynamic>;
    final row = <String, dynamic>{
      ...s,
      'opened_at': s['opened_at_ms'],
      'closed_at': s['closed_at_ms'],
      'pos_id': binding.register['id'],
      'outlet_id': binding.outlet['id'],
    };
    final shift = Shift.fromMap(row);
    final db = await AppDatabase.instance.db;
    await db.transaction((tx) async {
      final existing = await tx.query(
        'shifts',
        where: 'id = ?',
        whereArgs: [shift.id],
      );
      if (existing.isEmpty) await tx.insert('shifts', shift.toMap());
      // Preserve a local close made while its acknowledgement was in flight.
      final closed =
          !shift.isOpen ||
          (existing.isNotEmpty && existing.first['closed_at'] != null);
      await tx.rawInsert(
        '''INSERT INTO _till_sessions(id,state,employee_id,receipt_next,receipt_end)
        VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
        employee_id=excluded.employee_id,
        state=CASE WHEN _till_sessions.state IN ('closing_pending','closed','recovery_required')
          THEN _till_sessions.state ELSE excluded.state END''',
        [
          shift.id,
          closed ? 'closing_pending' : 'active_confirmed',
          data['current_employee_id'] ?? shift.employeeId,
          data['receipt_start'],
          data['receipt_end'],
        ],
      );
      await tx.rawInsert(
        'INSERT OR IGNORE INTO _push_revisions(entity,entity_id,revision) VALUES(?,?,1)',
        ['pos_sessions', shift.id],
      );
      await tx.delete(
        '_till_open_requests',
        where: 'register_id = ?',
        whereArgs: [shift.posId],
      );
    });
    return shift;
  }

  /// The open local drawer this device needs the server's verdict on, if any.
  ///
  /// **The LEFT join is the point.** Two kinds of open shift need an answer:
  /// one this coordinator knows, because it has a `_till_sessions` permit
  /// naming [employee]; and one it has never heard of, which has an open
  /// `shifts` row and **no permit row at all**. The second kind is not
  /// hypothetical — a session opened by a build from before coordinated tills
  /// existed went out through the legacy outbox push, so `_save` never ran for
  /// it. An INNER join could not see those, so `recover` returned having done
  /// nothing and the drawer stayed open forever: unresumable (no permit, so
  /// `holdsPermit` refuses) and uncloseable (nothing ever reconciled it). That
  /// is the "cannot be resumed — needs a manager" dead end, and re-activating
  /// the device did not clear it because the query could not see the row.
  ///
  /// A confirmed shift whose permit names ANOTHER cashier is deliberately
  /// excluded: it may be legitimately held after a handover. Conflict and
  /// recovery states are different. They grant no selling permit and must stay
  /// visible to every cashier until a later takeover can attach the server's
  /// recovery case and close the stale local shift.
  ///
  /// Ordering prefers a session this cashier can actually resume; a stranded
  /// one is only asked about when there is nothing to resume.
  Future<String?> pendingDrawer(DatabaseExecutor tx, String employee) async {
    final rows = await tx.rawQuery(
      '''SELECT s.id FROM shifts s LEFT JOIN _till_sessions t ON t.id=s.id
         WHERE s.pos_id=? AND s.closed_at IS NULL
           AND (t.id IS NULL
                OR t.state IN ('conflict','recovery_required')
                OR (t.employee_id=?
                    AND t.state IN ('active_confirmed','closing_pending')))
         ORDER BY (t.id IS NULL), s.opened_at DESC LIMIT 1''',
      [binding.register['id'], employee],
    );
    return rows.isEmpty ? null : rows.first['id'] as String;
  }

  Future<TillRecoveryOutcome> recover(String employee) async {
    final db = await AppDatabase.instance.db;
    final localSession = await pendingDrawer(db, employee);
    final result = await call(
      employee,
      '/till/sessions/current',
      query: localSession == null ? null : {'local_session_id': localSession},
    );
    if (result['data'] is Map<String, dynamic>) {
      await _save(result['data'] as Map<String, dynamic>);
      return TillRecoveryOutcome.active;
    }
    // A locally active coordinated session that vanished from the server was
    // force-closed or otherwise needs investigation. Keep all local rows, but
    // block checkout until Backoffice has decided their fate.
    if (localSession == null) return TillRecoveryOutcome.noPendingDrawer;
    final recovery = result['recovery'];
    final recoveryId = recovery is Map<String, dynamic>
        ? recovery['id'] as String?
        : null;
    final forcedAt = recovery is Map<String, dynamic>
        ? recovery['forced_at_ms'] as int?
        : null;
    // `recovery_required` is a promise that a manager has a case to decide, so
    // it is only claimed when the server named one. Without a case id the
    // honest answer is `conflict`: this device's session disagrees with the
    // server and a human has to look. Writing `recovery_required` with a null
    // id manufactured a state nobody could ever clear — no case in the
    // Backoffice to accept or reject, and the Recovery Center pointing at
    // nothing.
    final state = recoveryId == null ? 'conflict' : 'recovery_required';
    await db.transaction((tx) async {
      // INSERT-or-update, because a stranded session has no permit row to
      // update and an UPDATE would silently touch nothing — leaving the state
      // invisible to the Recovery Center and to `RecoveryInspector`.
      //
      // The receipt block is written exhausted (`receipt_next` past
      // `receipt_end`) rather than invented. This drawer is closed and will
      // never number another receipt, so an empty block is the truth; if it
      // somehow were asked, `nextReceipt` falls back to a UUID label rather
      // than reusing a number.
      await tx.rawInsert(
        '''INSERT INTO _till_sessions(id,state,employee_id,receipt_next,receipt_end,
             recovery_id,recovery_detected_at)
           VALUES(?,?,?,1,0,?,?)
           ON CONFLICT(id) DO UPDATE SET
             state=excluded.state,
             recovery_id=excluded.recovery_id,
             recovery_detected_at=excluded.recovery_detected_at''',
        [
          localSession,
          state,
          employee,
          recoveryId,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      if (forcedAt != null) {
        // Mirrors the server timestamp so the stale open-row index no longer
        // prevents this installation from opening its replacement drawer.
        // Cash counts stay untouched as recovery evidence.
        await tx.rawUpdate(
          'UPDATE shifts SET closed_at=? WHERE id=? AND closed_at IS NULL',
          [forcedAt, localSession],
        );
      }
    });
    return recoveryId == null
        ? TillRecoveryOutcome.conflict
        : TillRecoveryOutcome.recoveryRequired;
  }

  Future<Map<String, dynamic>> recoveryStatus(
    String employee,
    String recoveryId,
  ) => call(employee, '/till/recoveries/$recoveryId');

  Future<void> handover(String employee, String session) async {
    if (await OutboxStore.instance.count() > 0) {
      throw const TillOperationException('sync_before_handover');
    }
    final response = await call(
      employee,
      '/till/sessions/handover',
      body: {'id': session},
    );
    await _save(response['data'] as Map<String, dynamic>);
  }

  /// Whether this device holds a server-confirmed selling permit for
  /// [session] as [employee].
  ///
  /// **The one definition of that question.** `shifts` says a drawer is open;
  /// `_till_sessions` says whether the SERVER agrees this device may sell into
  /// it, and the two can legitimately disagree — a session that reached the
  /// server through the legacy push path never got a claim, a force-closed one
  /// is `recovery_required`, and a handed-over one names the other cashier.
  /// When the picker asked `shifts` and the resolver asked `_till_sessions`,
  /// the picker offered a Resume that resolved straight back to "no session":
  /// a dead button with no explanation, and no way off the screen. Anything
  /// that offers or gates a session has to call THIS.
  ///
  /// In demo mode there is no server to confirm anything, so `shifts` is the
  /// only truth and the answer is always yes.
  static Future<bool> holdsPermit(
    DatabaseExecutor tx,
    String? session,
    String employee,
  ) async {
    if (current == null) return true;
    if (session == null || session.isEmpty) return false;
    final rows = await tx.rawQuery(
      '''SELECT 1 FROM shifts s JOIN _till_sessions t ON t.id=s.id
         WHERE s.id=? AND s.closed_at IS NULL
         AND t.state='active_confirmed' AND t.employee_id=?''',
      [session, employee],
    );
    return rows.isNotEmpty;
  }

  static Future<void> assertSellable(
    DatabaseExecutor tx,
    String? session,
    String employee,
  ) async {
    if (!await holdsPermit(tx, session, employee)) {
      throw const TillOperationException('session_not_confirmed');
    }
  }

  static Future<int?> nextReceipt(DatabaseExecutor tx, String? session) async {
    if (current == null) return null;
    final rows = await tx.query(
      '_till_sessions',
      where: 'id = ?',
      whereArgs: [session],
    );
    if (rows.isEmpty) {
      throw const TillOperationException('session_not_confirmed');
    }
    final n = rows.first['receipt_next'] as int;
    if (n > (rows.first['receipt_end'] as int)) {
      return null; // UUID fallback below
    }
    await tx.update(
      '_till_sessions',
      {'receipt_next': n + 1},
      where: 'id = ?',
      whereArgs: [session],
    );
    return n;
  }

  static String uniqueReceipt() => 'R-${const Uuid().v4()}';
}
