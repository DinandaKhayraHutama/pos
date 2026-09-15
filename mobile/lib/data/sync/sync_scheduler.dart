import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'device_sync_runner.dart';
import 'retry_gate.dart';
import 'sync_client.dart';

typedef TimerFactory = Timer Function(Duration delay, void Function() onFire);

/// How long a device waits after launch before its first request.
///
/// `hash(device_id) mod 300` seconds: deterministic, needs no coordination, and
/// turns fifteen thousand tills opening at 08:00 into a flat five-minute ramp
/// instead of a spike. SHA-256 rather than `String.hashCode`, which is not
/// promised to be stable across runs or Dart versions.
Duration startupSpreadFor(String deviceId, {int windowSeconds = 300}) {
  final bytes = sha256.convert(utf8.encode(deviceId)).bytes;
  final value =
      ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
      0x7fffffff;
  return Duration(seconds: value % windowSeconds);
}

/// Decides WHEN a sync runs. [DeviceSyncRunner] decides what one does.
///
/// - Polls every `next_poll_ms` from the server (60s by default), multiplied by
///   uniform jitter in [0.8, 1.2] so a fleet does not synchronise.
/// - A connectivity change or app resume [nudge]s a sync: debounced by 5s and
///   bounded to once per 30s, so a flapping network is not a request storm.
/// - **The startup spread cannot be shortened by a nudge.** Until the first
///   scheduled run fires, nudges are ignored; the run they would have asked for
///   is already booked. A radio reporting "connected" the moment the app opens
///   used to cut a four-minute spread to five seconds on every till at once.
/// - **`Retry-After` binds every trigger.** Timer, nudge and the manual button
///   all consult the shared [RetryGate]; none of them can move a request
///   earlier than the server allowed.
/// - A request-level failure backs off exponentially, 2s doubling to 5m, with
///   full jitter. Rows that are merely still owed while the server is reachable
///   retry sooner, but never slower than the normal poll — one stuck row must
///   not slow the catalogue down.
/// - [syncNow] is the manual button: immediate and full, unless the gate says
///   the server asked for quiet. A person pressing a button is not the fleet
///   stampede the startup spread exists for, so it may run inside the spread.
class SyncScheduler {
  SyncScheduler({
    required this.run,
    RetryGate? gate,
    Random? random,
    DateTime Function()? clock,
    TimerFactory? timer,
    this.defaultPoll = const Duration(seconds: 60),
    this.minBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(minutes: 5),
    this.debounce = const Duration(seconds: 5),
    this.minNudgeGap = const Duration(seconds: 30),
    this.outdatedRecheck = const Duration(hours: 1),
  }) : _random = random ?? Random(),
       _clock = clock ?? DateTime.now,
       _timer = timer ?? Timer.new,
       _poll = defaultPoll,
       gate = gate ?? RetryGate(clock: clock);

  final Future<SyncOutcome?> Function({required bool full}) run;
  final RetryGate gate;
  final Duration defaultPoll;
  final Duration minBackoff;
  final Duration maxBackoff;
  final Duration debounce;
  final Duration minNudgeGap;
  final Duration outdatedRecheck;

  final Random _random;
  final DateTime Function() _clock;
  final TimerFactory _timer;

  Duration _poll;
  int _failures = 0;
  Timer? _pending;
  DateTime? _dueAt;
  DateTime? _lastRunAt;
  DateTime? _startupUntil;
  bool _started = false;
  bool _inFlight = false;

  bool get isStarted => _started;

  /// When the next scheduled run fires, for diagnostics and tests.
  DateTime? get nextRunAt => _dueAt;

  /// Starts the schedule. [initialDelay] is the startup spread at launch; no
  /// nudge fires a request before it has passed.
  void start({Duration initialDelay = Duration.zero}) {
    _started = true;
    _startupUntil = initialDelay > Duration.zero
        ? _clock().add(initialDelay)
        : null;
    _schedule(initialDelay);
  }

  void stop() {
    _started = false;
    _cancel();
  }

  /// Connectivity came back, or the app came to the foreground.
  void nudge() {
    if (!_started) return;
    final now = _clock();

    // Inside the startup spread: the first run is already booked at the end of
    // it, and moving it earlier is exactly what the spread forbids.
    final startup = _startupUntil;
    if (startup != null && startup.isAfter(now)) return;

    var delay = debounce;
    final last = _lastRunAt;
    if (last != null) {
      final gapLeft = last.add(minNudgeGap).difference(now);
      if (gapLeft > delay) delay = gapLeft;
    }
    final blocked = gate.remaining;
    if (blocked > delay) delay = blocked;

    final due = now.add(delay);
    // Something sooner is already booked; a nudge never postpones it. A booking
    // that falls inside a block armed after it was made does not count: it
    // would only wake to find the gate closed, so it is re-booked for when the
    // server allows.
    final booked = _dueAt;
    final unblock = gate.blockedUntil;
    final bookedAllowed =
        booked != null && (unblock == null || !unblock.isAfter(booked));
    if (bookedAllowed && !booked.isAfter(due)) return;
    _schedule(delay);
  }

  /// The manual "Sync now": runs at once, pulling every feed — unless the
  /// server asked for quiet, in which case nothing is sent and the returned
  /// outcome says how long is left.
  Future<SyncOutcome?> syncNow() => _execute(full: true);

  Future<SyncOutcome?> _execute({required bool full}) async {
    if (_inFlight) return null;

    final blocked = gate.remaining;
    if (blocked > Duration.zero) {
      // Refused without a request. The timer is re-booked for the moment the
      // server allows, if nothing is booked sooner-but-still-allowed.
      if (_started) _schedule(blocked);
      return SyncOutcome(failure: SyncFailure.rateLimited, retryAfter: blocked);
    }

    _inFlight = true;
    _cancel();
    _lastRunAt = _clock();
    _startupUntil = null;

    SyncOutcome? outcome;
    try {
      outcome = await run(full: full);
    } catch (_) {
      outcome = null;
    } finally {
      _inFlight = false;
    }

    if (_started) {
      if (outcome?.unauthorized ?? false) {
        // The app goes back to activation; nothing here can fix a revoked token.
        stop();
      } else {
        _schedule(nextDelay(outcome));
      }
    }
    return outcome;
  }

  /// The delay before the next run after [outcome], before the gate is
  /// applied.
  @visibleForTesting
  Duration nextDelay(SyncOutcome? outcome) {
    final serverPoll = outcome?.nextPoll;
    if (serverPoll != null) _poll = serverPoll;

    // Null: the runner was already busy. Carry on at the normal cadence.
    if (outcome == null) return _jittered(_poll);

    if (outcome.schemaOutdated) return outdatedRecheck;

    if (outcome.failure == null && !outcome.pushNeedsRetry) {
      _failures = 0;
      return _jittered(_poll);
    }

    _failures++;
    final exponent = min(_failures - 1, 20);
    final capMs = min(
      maxBackoff.inMilliseconds,
      minBackoff.inMilliseconds * pow(2, exponent).toInt(),
    );
    var delay = Duration(
      milliseconds: max(1000, (_random.nextDouble() * capMs).round()),
    );

    if (outcome.failure == null) {
      // The server answered; only rows are still owed. Keep the poll cadence
      // as the ceiling so stuck rows cannot slow every other kind of sync.
      final poll = _jittered(_poll);
      if (delay > poll) delay = poll;
    }

    final wait = outcome.retryAfter;
    if (wait != null && wait > delay) delay = wait;
    return delay;
  }

  Duration _jittered(Duration base) => Duration(
    milliseconds: (base.inMilliseconds * (0.8 + _random.nextDouble() * 0.4))
        .round(),
  );

  void _schedule(Duration delay) {
    // No trigger books a run earlier than the server allowed.
    final blocked = gate.remaining;
    if (blocked > delay) delay = blocked;
    _cancel();
    _dueAt = _clock().add(delay);
    _pending = _timer(delay, () {
      _pending = null;
      _dueAt = null;
      unawaited(_execute(full: false));
    });
  }

  void _cancel() {
    _pending?.cancel();
    _pending = null;
    _dueAt = null;
  }
}
