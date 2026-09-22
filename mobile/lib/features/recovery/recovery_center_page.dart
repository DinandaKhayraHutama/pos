import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../data/device/till_coordinator.dart';
import '../../data/recovery/recovery_inspector.dart';
import '../../data/sync/dead_letter_store.dart';
import '../../providers/device_sync_provider.dart';
import '../../providers/settings_provider.dart';

/// Where anyone finds out that this till is holding sales it cannot send.
///
/// Everything here is either read-only or one explicitly reviewed row at a
/// time: there is no "retry everything", because a blanket retry of a conflict
/// is exactly what the recovery model exists to prevent. A row refused with
/// `recovery_required` only offers its button once the server says a manager
/// accepted that exact entity and revision.
class RecoveryCenterPage extends ConsumerStatefulWidget {
  const RecoveryCenterPage({super.key});

  @override
  ConsumerState<RecoveryCenterPage> createState() => _RecoveryCenterPageState();
}

typedef _RecoveryView = ({
  RecoverySnapshot local,
  Map<String, Map<String, dynamic>> remote,
});

class _RecoveryCenterPageState extends ConsumerState<RecoveryCenterPage> {
  late Future<_RecoveryView> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_RecoveryView> _load() async {
    final local = await RecoveryInspector.instance.inspect();
    final remote = <String, Map<String, dynamic>>{};
    final coordinator = TillCoordinator.current;
    final employee = ref.read(settingsProvider).valueOrNull?.employeeId ?? '';
    if (coordinator != null && employee.isNotEmpty) {
      final cases = local.deadLetters
          .map((e) => e.recoveryId)
          .whereType<String>()
          .toSet();
      for (final id in cases) {
        try {
          remote[id] = await coordinator.recoveryStatus(employee, id);
        } on TillOperationException {
          // Local evidence stays useful while offline or before a fresh PIN.
        }
      }
    }
    return (local: local, remote: remote);
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  bool _managerAction(DeadLetter letter) =>
      RecoveryInspector.managerCodes.contains(letter.code);

  /// A refused row may be sent again only when the server's answer no longer
  /// stands: a busy register frees up, and a quarantined sale is approved by a
  /// manager for that exact revision.
  bool _canRetry(DeadLetter letter, Map<String, Map<String, dynamic>> remote) {
    if (letter.code == 'register_busy' || letter.code == 'session_closed') {
      return true;
    }
    if (letter.code != 'recovery_required' || letter.recoveryId == null) {
      return false;
    }
    final data = remote[letter.recoveryId]?['data'];
    if (data is! Map<String, dynamic>) return false;
    final items = data['items'];
    return items is List &&
        items.any(
          (item) =>
              item is Map<String, dynamic> &&
              item['entity_id'] == letter.entityId &&
              item['revision'] == letter.revision &&
              item['status'] == 'accepted',
        );
  }

  Future<void> _retry(DeadLetter letter) async {
    final l10n = context.l10n;
    final controller = ref.read(deviceSyncControllerProvider);
    final done = controller != null
        ? await controller.retryRejected(letter.id)
        : await DeadLetterStore.instance.requeue(letter.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          done ? l10n.recoveryRequeued : l10n.recoveryNotRetryable,
        ),
      ),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: GlassAppBar(title: l10n.recoveryTitle),
      body: FutureBuilder<_RecoveryView>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!;
          final pending = data.local.pending;
          final manager = data.local.deadLetters.where(_managerAction).toList();
          final investigate = data.local.deadLetters
              .where((e) => !_managerAction(e))
              .toList();
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.all(AppDimensions.space16),
              children: [
                Text(
                  l10n.recoveryLocalStatus(_statusLabel(data.local.status)),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppDimensions.space8),
                Text(l10n.recoveryIntro),
                const SizedBox(height: AppDimensions.space20),
                _heading(l10n.recoverySectionQueued, pending.length),
                for (final entry in pending)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.outbox_outlined),
                      title: Text('${entry.entity} · ${entry.entityId}'),
                      subtitle: Text(
                        [
                          l10n.recoveryQueuedDetail(
                            entry.revision?.toString() ?? '—',
                            entry.attempts,
                          ),
                          if (entry.lastError != null) entry.lastError!,
                        ].join('\n'),
                      ),
                    ),
                  ),
                if (pending.isEmpty) _Empty(l10n.recoverySectionQueuedEmpty),
                const SizedBox(height: AppDimensions.space20),
                _heading(l10n.recoverySectionManager, manager.length),
                for (final letter in manager) _letter(letter, data.remote),
                if (manager.isEmpty) _Empty(l10n.recoverySectionManagerEmpty),
                const SizedBox(height: AppDimensions.space20),
                _heading(l10n.recoverySectionInvestigate, investigate.length),
                for (final letter in investigate) _letter(letter, data.remote),
                if (investigate.isEmpty)
                  _Empty(l10n.recoverySectionInvestigateEmpty),
                const SizedBox(height: AppDimensions.space20),
                _heading(
                  l10n.recoverySectionDiagnostics,
                  data.local.diagnostics.length,
                ),
                for (final finding in data.local.diagnostics)
                  Card(
                    child: ListTile(
                      title: Text(
                        '${_statusLabel(finding.classification)} · ${finding.code}',
                      ),
                      subtitle: Text(
                        '${finding.entity} · ${finding.entityId}'
                        '\n${_actionLabel(finding.action)}',
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _heading(String label, int count) => Text(
    context.l10n.recoverySectionHeading(label, count),
    style: Theme.of(context).textTheme.titleMedium,
  );

  Widget _letter(DeadLetter letter, Map<String, Map<String, dynamic>> remote) {
    final l10n = context.l10n;
    final retry = _canRetry(letter, remote);
    final remoteCase = letter.recoveryId == null
        ? null
        : remote[letter.recoveryId]?['data'];
    final caseStatus = remoteCase is Map<String, dynamic>
        ? remoteCase['status'] as String?
        : null;
    return Card(
      child: ListTile(
        leading: Icon(
          letter.code == 'recovery_required'
              ? Icons.admin_panel_settings_outlined
              : Icons.warning_amber_rounded,
        ),
        title: Text('${letter.entity} · ${letter.entityId}'),
        subtitle: Text(
          [
            l10n.recoveryLetterDetail(letter.code, letter.revision),
            letter.message ?? l10n.recoveryNoServerMessage,
            if (letter.recoveryId != null)
              caseStatus == null
                  ? l10n.recoveryCaseLine(letter.recoveryId!)
                  : l10n.recoveryCaseLineWithStatus(
                      letter.recoveryId!,
                      caseStatus,
                    ),
          ].join('\n'),
        ),
        trailing: retry
            ? TextButton(
                onPressed: () => _retry(letter),
                child: Text(l10n.recoveryRetry),
              )
            : null,
      ),
    );
  }

  String _statusLabel(RecoveryClassification status) => switch (status) {
    RecoveryClassification.healthy => context.l10n.recoveryStatusHealthy,
    RecoveryClassification.pending => context.l10n.recoveryStatusPending,
    RecoveryClassification.conflict => context.l10n.recoveryStatusConflict,
    RecoveryClassification.recoveryRequired =>
      context.l10n.recoveryStatusRecoveryRequired,
  };

  String _actionLabel(RecoveryAction action) => switch (action) {
    RecoveryAction.waitForScheduler =>
      context.l10n.recoveryActionWaitForScheduler,
    RecoveryAction.waitForManager => context.l10n.recoveryActionWaitForManager,
    RecoveryAction.incompatible => context.l10n.recoveryActionIncompatible,
    RecoveryAction.keepSnapshot => context.l10n.recoveryActionKeepSnapshot,
    RecoveryAction.checkTillMigration =>
      context.l10n.recoveryActionCheckTillMigration,
    RecoveryAction.blockedUntilDecided =>
      context.l10n.recoveryActionBlockedUntilDecided,
    RecoveryAction.matchMovement => context.l10n.recoveryActionMatchMovement,
    RecoveryAction.finishDependencies =>
      context.l10n.recoveryActionFinishDependencies,
    RecoveryAction.reconcileBySigningIn =>
      context.l10n.recoveryActionReconcileBySigningIn,
  };
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppDimensions.space12),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
}
