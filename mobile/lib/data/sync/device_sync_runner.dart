import 'dart:async';

import '../device/device_registration.dart';
import 'catalogue_sync.dart';
import 'outbox_push.dart';
import 'retry_gate.dart';
import 'sync_client.dart';
import 'sync_meta_store.dart';

/// What one sync run found and did.
class SyncOutcome {
  const SyncOutcome({
    this.pull,
    this.push,
    this.failure,
    this.retryAfter,
    this.nextPoll,
    this.deviceRevision,
    this.pullInterrupted = false,
  });

  final SyncReport? pull;
  final PushReport? push;

  /// The first failure any step hit, or null when every step completed.
  final SyncFailure? failure;

  /// How long the server asked this device to wait, when it did.
  final Duration? retryAfter;

  /// The poll interval the server asked for in `/sync/changes`.
  final Duration? nextPoll;

  /// The binding revision from `/sync/changes`. When it differs from the one
  /// this device last confirmed, `/devices/me` is worth one request.
  final int? deviceRevision;

  /// The pull stopped part-way. Pages before the failure may have committed,
  /// so mounted screens still need to re-read.
  final bool pullInterrupted;

  bool get unauthorized => failure == SyncFailure.unauthorized;
  bool get schemaOutdated => failure == SyncFailure.schemaOutdated;

  /// Rows are still queued after the push, though the server was reachable.
  bool get pushNeedsRetry => push?.needsRetry ?? false;
}

/// One sync: ask what changed, pull that, push what is owed.
///
/// Exists because sync has several triggers — just activated, the poll timer,
/// app resumed, connectivity back, someone tapped "Sync now" — and running two
/// at once against the same SQLite would interleave two page writes on the
/// same cursor. A re-entrancy guard makes "already syncing" a no-op instead of
/// a corruption. When to run is `SyncScheduler`'s job, not this class's.
///
/// Failures never propagate as crashes. A till that cannot reach the server
/// must keep selling from what it already has; a sync error is a status line,
/// not a blocked screen. The one exception is [SyncFailure.unauthorized],
/// reported through [onUnauthorized] so the app can send the user to
/// re-activation — no amount of retrying fixes a revoked device.
class DeviceSyncRunner {
  DeviceSyncRunner({
    required DeviceRegistration binding,
    SyncClient? client,
    RetryGate? gate,
    this.onUnauthorized,
  }) : _client =
           client ??
           SyncClient(
             baseUrl: binding.baseUrl,
             token: binding.token,
             gate: gate,
           ) {
    _pull = CatalogueSync(_client);
    _push = OutboxPush(_client);
  }

  final SyncClient _client;
  late final CatalogueSync _pull;
  late final OutboxPush _push;

  /// The client's `Retry-After` gate, shared with the scheduler and
  /// `/devices/me`.
  RetryGate get gate => _client.gate;

  /// Called when the server says this device is no longer known.
  final void Function()? onUnauthorized;

  static const _minPoll = Duration(seconds: 5);
  static const _maxPoll = Duration(hours: 1);

  bool _running = false;
  DateTime? _lastSuccess;
  SyncFailure? _lastFailure;

  bool get isRunning => _running;
  DateTime? get lastSuccess => _lastSuccess;
  SyncFailure? get lastFailure => _lastFailure;

  /// Runs one sync unless one is already in flight (then returns null).
  ///
  /// [full] skips `/sync/changes` and asks every feed — right after
  /// activation, when nothing has been pulled, and for a manual "Sync now".
  ///
  /// **The push runs even when the changes call or the pull failed** — what is
  /// queued is money already taken — with one exception: **a response that
  /// names a `Retry-After` ends the run.** The server is saying this device
  /// must wait, and a push right behind it would be exactly the request it
  /// asked not to receive.
  Future<SyncOutcome?> syncNow({bool full = false}) async {
    if (_running) return null;
    _running = true;

    SyncReport? pull;
    PushReport? push;
    SyncFailure? failure;
    Duration? retryAfter;
    Duration? nextPoll;
    int? deviceRevision;
    var pullInterrupted = false;

    void note(Object error) {
      if (error is SyncException) {
        failure ??= error.failure;
        final wait = error.retryAfter;
        if (wait != null && (retryAfter == null || wait > retryAfter!)) {
          retryAfter = wait;
        }
      } else {
        // A SQLite constraint, an unexpected shape: still just a failed step.
        // Every page and every outbox move is its own transaction, so nothing
        // half-applied is left behind.
        failure ??= SyncFailure.server;
      }
    }

    bool fatal(Object error) =>
        error is SyncException &&
        (error.failure == SyncFailure.unauthorized ||
            error.failure == SyncFailure.schemaOutdated ||
            error.retryAfter != null);

    try {
      Map<String, int>? hints;
      if (!full) {
        try {
          final changes = await _client.get('/sync/changes');
          hints = _cursors(changes);
          nextPoll = _pollInterval(changes['next_poll_ms']);
          final revision = changes['device_revision'];
          if (revision is int) deviceRevision = revision;
          final serverTime = changes['server_time_ms'];
          if (serverTime is int) {
            await SyncMetaStore.instance.recordServerTime(serverTime);
          }
        } catch (e) {
          if (fatal(e)) rethrow;
          note(e);
        }
      }

      // Without hints (the changes call failed) the pull is skipped rather than
      // widened to every feed: whatever broke that request is likely to break
      // a dozen more, and the next poll asks again.
      if (full || hints != null) {
        try {
          pull = await _pull.run(hints: full ? null : hints);
        } catch (e) {
          pullInterrupted = true;
          if (fatal(e)) rethrow;
          note(e);
        }
      }

      try {
        push = await _push.run();
        if (push.failure != null) note(push.failure!);
      } catch (e) {
        if (fatal(e)) rethrow;
        note(e);
      }

      // Read back only the affected projection, not the whole catalogue.
      // An ACK identifies the sequence but a superseded event does not tell
      // us the winning status. This also clears a resolved conflict promptly.
      // The same client gate still prevents requests after any Retry-After.
      if ((push?.tableStatusSeq ?? 0) > 0 && retryAfter == null) {
        try {
          final refreshed = await _pull.run(
            hints: {'table_status': push!.tableStatusSeq},
          );
          pull = SyncReport(
            applied: {
              ...?pull?.applied,
              for (final e in refreshed.applied.entries)
                e.key: (pull?.applied[e.key] ?? 0) + e.value,
            },
            deleted: {
              ...?pull?.deleted,
              for (final e in refreshed.deleted.entries)
                e.key: (pull?.deleted[e.key] ?? 0) + e.value,
            },
          );
        } catch (e) {
          pullInterrupted = true;
          if (fatal(e)) rethrow;
          note(e);
        }
      }

      if (failure == null) _lastSuccess = DateTime.now();
      _lastFailure = failure;

      return SyncOutcome(
        pull: pull,
        push: push,
        failure: failure,
        retryAfter: retryAfter,
        nextPoll: nextPoll,
        deviceRevision: deviceRevision,
        pullInterrupted: pullInterrupted,
      );
    } on SyncException catch (e) {
      _lastFailure = e.failure;
      if (e.failure == SyncFailure.unauthorized) onUnauthorized?.call();
      return SyncOutcome(
        pull: pull,
        push: push,
        failure: e.failure,
        retryAfter: e.retryAfter,
        nextPoll: nextPoll,
        pullInterrupted: pullInterrupted,
      );
    } finally {
      _running = false;
    }
  }

  static Map<String, int> _cursors(Map<String, dynamic> changes) {
    final cursors = changes['cursors'];
    if (cursors is! Map<String, dynamic>) {
      throw const SyncException(
        SyncFailure.malformed,
        'changes has no cursors',
      );
    }
    final out = <String, int>{};
    for (final entry in cursors.entries) {
      final value = entry.value;
      if (value is! int || value < 0) {
        throw const SyncException(
          SyncFailure.malformed,
          'changes cursor is not a whole number',
        );
      }
      out[entry.key] = value;
    }
    return out;
  }

  static Duration? _pollInterval(Object? raw) {
    if (raw is! int || raw < 1) return null;
    final interval = Duration(milliseconds: raw);
    if (interval < _minPoll) return _minPoll;
    if (interval > _maxPoll) return _maxPoll;
    return interval;
  }

  void close() => _client.close();
}
