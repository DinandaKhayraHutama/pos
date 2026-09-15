import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import 'dead_letter_store.dart';
import 'device_sync_runner.dart';
import 'outbox_store.dart';
import 'retry_gate.dart';
import 'sync_client.dart';
import 'sync_meta_store.dart';
import 'sync_scheduler.dart';

/// What the Settings screen shows about sync.
@immutable
class DeviceSyncStatus {
  const DeviceSyncStatus({
    this.running = false,
    this.lastSuccessAt,
    this.lastFailure,
    this.pending = 0,
    this.deadLetters = 0,
  });

  final bool running;
  final DateTime? lastSuccessAt;

  /// The failure of the most recent completed run, or null if it succeeded.
  final SyncFailure? lastFailure;

  /// Rows still owed to the server.
  final int pending;

  /// Rows the server refused, kept for recovery.
  final int deadLetters;

  bool get updateRequired => lastFailure == SyncFailure.schemaOutdated;

  DeviceSyncStatus copyWith({
    bool? running,
    DateTime? lastSuccessAt,
    SyncFailure? Function()? lastFailure,
    int? pending,
    int? deadLetters,
  }) => DeviceSyncStatus(
    running: running ?? this.running,
    lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
    lastFailure: lastFailure == null ? this.lastFailure : lastFailure(),
    pending: pending ?? this.pending,
    deadLetters: deadLetters ?? this.deadLetters,
  );
}

/// Emits whenever the platform reports a usable network that differs from the
/// one it reported before.
///
/// **The first report is never a change.** `connectivity_plus` announces the
/// current state when a listener attaches, and treating that as "connectivity
/// came back" nudged a sync the moment the app opened — on every till at
/// once. Only transitions after it count, including dead wifi → mobile data,
/// which is exactly when a sale that failed a minute ago can go now. The
/// scheduler debounces and bounds what this produces, and ignores it inside
/// the startup spread.
Stream<bool> connectivityRegained([Stream<List<ConnectivityResult>>? changes]) {
  List<ConnectivityResult>? previous;
  return (changes ?? Connectivity().onConnectivityChanged)
      .where((results) {
        final online = results.any((r) => r != ConnectivityResult.none);
        final changed = previous != null && !listEquals(previous, results);
        previous = results;
        return online && changed;
      })
      .map((_) => true);
}

/// Owns sync for one activated binding: the runner, its schedule, the shared
/// `Retry-After` gate, and the status the UI reads.
///
/// Lives outside the connected store's `ProviderScope` — it is created by
/// `BackendApp` and handed in as an override — because it has to outlive a
/// cashier signing out and must be torn down when the device is revoked.
class DeviceSyncController extends ChangeNotifier {
  DeviceSyncController({
    required DeviceSyncRunner runner,
    Stream<bool>? reconnections,
    this.onDeviceRevisionChanged,
    this.onDataChanged,
    SyncScheduler Function(
      Future<SyncOutcome?> Function({required bool full}) run,
      RetryGate gate,
    )?
    schedulerFactory,
  }) : _runner = runner {
    _scheduler =
        schedulerFactory?.call(_run, runner.gate) ??
        SyncScheduler(run: _run, gate: runner.gate);
    _reconnections = reconnections?.listen(
      (_) => _scheduler.nudge(),
      // A platform without the plugin simply has no connectivity signal; the
      // poll and the resume trigger still run.
      onError: (Object _) {},
    );
  }

  final DeviceSyncRunner _runner;
  late final SyncScheduler _scheduler;
  StreamSubscription<bool>? _reconnections;

  /// The binding changed on the server since this device last confirmed it.
  /// Returns whether the new binding was fetched and stored; only then is the
  /// revision remembered, so a failed check is asked again next poll.
  final Future<bool> Function()? onDeviceRevisionChanged;

  /// Pulled rows were written: mounted screens should re-read them.
  final void Function()? onDataChanged;

  bool _disposed = false;
  DeviceSyncStatus _status = const DeviceSyncStatus();

  DeviceSyncStatus get status => _status;

  /// The gate every request from this device honours, `/devices/me` included.
  RetryGate get gate => _runner.gate;

  /// Starts the schedule. At launch, [initialDelay] is the startup spread;
  /// right after activation the caller runs [syncNow] instead.
  void start({Duration initialDelay = Duration.zero}) {
    _scheduler.start(initialDelay: initialDelay);
    unawaited(refreshCounts());
  }

  /// App resumed: sync soon, debounced, never inside the startup spread.
  void nudge() => _scheduler.nudge();

  /// Manual "Sync now", and the awaited first sync after activation.
  Future<SyncOutcome?> syncNow() => _scheduler.syncNow();

  /// Sends every refused row that still exists up again.
  Future<int> retryRejected() async {
    final requeued = await DeadLetterStore.instance.requeueAll();
    await refreshCounts();
    if (requeued > 0) unawaited(syncNow());
    return requeued;
  }

  Future<void> refreshCounts() async {
    try {
      final pending = await OutboxStore.instance.count();
      final dead = await DeadLetterStore.instance.count();
      _update(_status.copyWith(pending: pending, deadLetters: dead));
    } catch (_) {
      // Counts are a status line; a failed read must not break sync.
    }
  }

  Future<SyncOutcome?> _run({required bool full}) async {
    _update(_status.copyWith(running: true));
    final outcome = await _runner.syncNow(full: full);
    if (outcome?.failure case final failure?) {
      // The failure kind only: no credentials, URLs or response bodies.
      debugPrint('Device sync failed: ${failure.name}');
    }
    _update(
      _status.copyWith(
        running: false,
        lastSuccessAt: _runner.lastSuccess,
        lastFailure: outcome == null ? null : () => outcome.failure,
      ),
    );
    await refreshCounts();

    final revision = outcome?.deviceRevision;
    final check = onDeviceRevisionChanged;
    if (revision != null && check != null && !_disposed) {
      try {
        if (await SyncMetaStore.instance.deviceRevision() != revision &&
            await check()) {
          await SyncMetaStore.instance.recordDeviceRevision(revision);
        }
      } catch (_) {
        // Asked again on the next poll.
      }
    }
    if (outcome != null &&
        ((outcome.pull?.changedAnything ?? false) ||
            (outcome.push?.changedAnything ?? false) ||
            outcome.pullInterrupted)) {
      // Also after an interrupted pull: earlier pages may have committed.
      onDataChanged?.call();
    }
    return outcome;
  }

  void _update(DeviceSyncStatus next) {
    if (_disposed) return;
    _status = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _scheduler.stop();
    unawaited(_reconnections?.cancel());
    _runner.close();
    super.dispose();
  }
}
