import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../device/till_coordinator.dart';
import '../sync/dead_letter_store.dart';
import '../sync/outbox_store.dart';

enum RecoveryClassification { healthy, pending, conflict, recoveryRequired }

/// What a finding tells the operator to do next. The text belongs to the UI —
/// this layer has no `BuildContext` and must not hold user-facing strings.
enum RecoveryAction {
  waitForScheduler,
  waitForManager,
  incompatible,
  keepSnapshot,
  checkTillMigration,
  blockedUntilDecided,
  matchMovement,
  finishDependencies,
  reconcileBySigningIn,
}

class LocalDiagnostic {
  const LocalDiagnostic({
    required this.classification,
    required this.code,
    required this.entity,
    required this.entityId,
    required this.action,
  });

  final RecoveryClassification classification;
  final String code;
  final String entity;
  final String entityId;
  final RecoveryAction action;
}

class RecoverySnapshot {
  const RecoverySnapshot({
    required this.status,
    required this.pending,
    required this.deadLetters,
    required this.diagnostics,
  });

  final RecoveryClassification status;
  final List<OutboxEntry> pending;
  final List<DeadLetter> deadLetters;
  final List<LocalDiagnostic> diagnostics;
}

/// Read-only inspection of every local table that can explain a stuck till.
/// It never deletes, requeues or changes a business row — which is what makes
/// it safe to run on a till that is already in trouble.
class RecoveryInspector {
  const RecoveryInspector._();
  static const instance = RecoveryInspector._();

  /// Refusals a manager has to decide in the Backoffice. The till cannot clear
  /// these by retrying, so saying "retry scheduled" about them would be a lie.
  static const managerCodes = {
    'recovery_required',
    'session_closed',
    'register_busy',
    'register_mismatch',
  };

  Future<RecoverySnapshot> inspect() async {
    final db = await AppDatabase.instance.db;
    final pending = await OutboxStore.instance.pending(limit: 100000);
    final dead = await DeadLetterStore.instance.all();
    final findings = <LocalDiagnostic>[];

    for (final entry in pending) {
      findings.add(
        LocalDiagnostic(
          classification: RecoveryClassification.pending,
          code: entry.lastError == null
              ? 'waiting_to_upload'
              : 'retry_scheduled',
          entity: entry.entity,
          entityId: entry.entityId,
          action: RecoveryAction.waitForScheduler,
        ),
      );
      final source = await OutboxStore.payloadWithin(
        db,
        entry.entity,
        entry.entityId,
      );
      if (source == null) {
        findings.add(
          LocalDiagnostic(
            classification: RecoveryClassification.conflict,
            code: 'source_row_missing',
            entity: entry.entity,
            entityId: entry.entityId,
            action: RecoveryAction.keepSnapshot,
          ),
        );
      }
    }

    for (final letter in dead) {
      final needsManager = managerCodes.contains(letter.code);
      findings.add(
        LocalDiagnostic(
          classification: letter.code == 'recovery_required'
              ? RecoveryClassification.recoveryRequired
              : RecoveryClassification.conflict,
          code: letter.code,
          entity: letter.entity,
          entityId: letter.entityId,
          action: needsManager
              ? RecoveryAction.waitForManager
              : RecoveryAction.incompatible,
        ),
      );
    }

    await _appendRows(
      db,
      findings,
      '''SELECT t.id FROM _till_sessions t
         LEFT JOIN shifts s ON s.id=t.id WHERE s.id IS NULL''',
      RecoveryClassification.conflict,
      'till_state_without_shift',
      '_till_sessions',
      RecoveryAction.checkTillMigration,
    );
    await _appendRows(
      db,
      findings,
      '''SELECT id FROM _till_sessions WHERE state='recovery_required' ''',
      RecoveryClassification.recoveryRequired,
      'session_recovery_required',
      '_till_sessions',
      RecoveryAction.blockedUntilDecided,
    );
    if (TillCoordinator.current != null) {
      // An open drawer this coordinator has never heard of — no permit row at
      // all. A session opened by a build from before coordinated tills existed
      // looks exactly like this, and it can neither be sold into nor resumed,
      // so it has to be NAMED rather than left as a picker tile that refuses.
      // Signing in is what asks the server to reconcile it.
      await _appendRows(
        db,
        findings,
        '''SELECT s.id FROM shifts s LEFT JOIN _till_sessions t ON t.id=s.id
           WHERE s.closed_at IS NULL AND t.id IS NULL''',
        RecoveryClassification.conflict,
        'shift_without_till_permit',
        'shifts',
        RecoveryAction.reconcileBySigningIn,
      );
    }
    await _appendRows(
      db,
      findings,
      '''SELECT sm.id FROM stock_movements sm
         WHERE sm.order_id IS NOT NULL
         AND NOT EXISTS(SELECT 1 FROM orders o WHERE o.id=sm.order_id)''',
      RecoveryClassification.conflict,
      'sale_movement_without_order',
      'stock_movements',
      RecoveryAction.matchMovement,
    );

    final closing = await db.rawQuery(
      "SELECT id FROM _till_sessions WHERE state='closing_pending'",
    );
    if (closing.isNotEmpty &&
        (pending.any((e) => e.entity != 'pos_sessions') || dead.isNotEmpty)) {
      for (final row in closing) {
        findings.add(
          LocalDiagnostic(
            classification: RecoveryClassification.pending,
            code: 'closing_waits_for_dependencies',
            entity: '_till_sessions',
            entityId: row['id'] as String,
            action: RecoveryAction.finishDependencies,
          ),
        );
      }
    }

    var status = RecoveryClassification.healthy;
    for (final finding in findings) {
      if (finding.classification == RecoveryClassification.recoveryRequired) {
        status = RecoveryClassification.recoveryRequired;
        break;
      }
      if (finding.classification == RecoveryClassification.conflict) {
        status = RecoveryClassification.conflict;
      } else if (status == RecoveryClassification.healthy) {
        status = RecoveryClassification.pending;
      }
    }
    return RecoverySnapshot(
      status: status,
      pending: pending,
      deadLetters: dead,
      diagnostics: findings,
    );
  }

  Future<void> _appendRows(
    Database db,
    List<LocalDiagnostic> out,
    String sql,
    RecoveryClassification classification,
    String code,
    String entity,
    RecoveryAction action,
  ) async {
    for (final row in await db.rawQuery(sql)) {
      out.add(
        LocalDiagnostic(
          classification: classification,
          code: code,
          entity: entity,
          entityId: row['id'] as String,
          action: action,
        ),
      );
    }
  }
}
