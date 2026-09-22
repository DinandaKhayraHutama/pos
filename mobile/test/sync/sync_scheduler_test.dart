import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/sync/device_sync_runner.dart';
import 'package:nti_pos/data/sync/outbox_push.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:nti_pos/data/sync/sync_scheduler.dart';

class _FixedRandom implements Random {
  _FixedRandom(this.value);
  double value;

  @override
  double nextDouble() => value;
  @override
  bool nextBool() => value >= 0.5;
  @override
  int nextInt(int max) => (value * max).floor();
}

class _FakeTimer implements Timer {
  _FakeTimer(this.delay, this._onFire);
  final Duration delay;
  final void Function() _onFire;
  bool _active = true;

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;

  void fire() {
    if (!_active) return;
    _active = false;
    _onFire();
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// When a till syncs.
///
/// Fifteen thousand devices follow these rules at once, so every number here
/// is a load on the server: a missing jitter synchronises a fleet, a missing
/// bound turns a flapping network into a request storm, and a missing backoff
/// hammers a server that is already down.
void main() {
  late DateTime now;
  late List<_FakeTimer> timers;
  late List<bool> runs;
  late _FixedRandom random;
  late SyncOutcome? Function() nextOutcome;

  SyncScheduler scheduler() => SyncScheduler(
    run: ({required bool full}) async {
      runs.add(full);
      return nextOutcome();
    },
    random: random,
    clock: () => now,
    timer: (delay, onFire) {
      final timer = _FakeTimer(delay, onFire);
      timers.add(timer);
      return timer;
    },
  );

  setUp(() {
    now = DateTime.utc(2026, 9, 14, 8);
    timers = [];
    runs = [];
    random = _FixedRandom(0.5);
    nextOutcome = () => const SyncOutcome(nextPoll: Duration(seconds: 60));
  });

  test(
    'startup spread is deterministic per device and inside five minutes',
    () {
      final spreads = [
        for (var i = 0; i < 200; i++) startupSpreadFor('device-$i'),
      ];
      for (final spread in spreads) {
        expect(spread, lessThan(const Duration(seconds: 300)));
        expect(spread, greaterThanOrEqualTo(Duration.zero));
      }
      expect(startupSpreadFor('device-7'), startupSpreadFor('device-7'));
      // Spread out, not one bucket: that would be the 08:00 spike again.
      expect(spreads.toSet().length, greaterThan(100));
    },
  );

  // Shared with backend-go/scripts/loadtest (TestTheStartupSpreadMatchesTheFlutterTill).
  //
  // The Fase 9 morning-rush scenario claims the spread flattens fifteen
  // thousand tills to under 50 requests a second. That is a claim about the
  // distribution THIS function produces, so the harness ports it byte for
  // byte; these vectors are what keeps the two implementations honest. If this
  // test has to change, the Go one changes in the same commit — otherwise the
  // load test is measuring a fleet that does not exist.
  test('startup spread matches the load harness on fixed vectors', () {
    expect(startupSpreadFor('device-7'), const Duration(seconds: 261));
    expect(
      startupSpreadFor('0f2b6c1e-0000-4000-8000-000000000001'),
      const Duration(seconds: 289),
    );
    expect(startupSpreadFor('till-jakarta-01'), const Duration(seconds: 44));
    expect(startupSpreadFor(''), const Duration(seconds: 162));
  });

  test('polls at the server-controlled interval with ±20% jitter', () {
    final s = scheduler();
    const outcome = SyncOutcome(nextPoll: Duration(seconds: 90));

    random.value = 0;
    expect(s.nextDelay(outcome), const Duration(seconds: 72));
    random.value = 1;
    expect(s.nextDelay(outcome), const Duration(seconds: 108));
  });

  test(
    'request failures back off 2s doubling to a 5m cap, with full jitter',
    () {
      final s = scheduler();
      const failed = SyncOutcome(failure: SyncFailure.network);

      random.value = 1;
      final delays = [for (var i = 0; i < 12; i++) s.nextDelay(failed)];
      expect(delays.take(4), const [
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
        Duration(seconds: 16),
      ]);
      expect(delays.last, const Duration(minutes: 5));

      // Full jitter reaches down to zero; a floor keeps it from a tight loop.
      random.value = 0;
      expect(s.nextDelay(failed), const Duration(seconds: 1));
    },
  );

  test('a success resets the backoff', () {
    final s = scheduler();
    random.value = 1;
    for (var i = 0; i < 6; i++) {
      s.nextDelay(const SyncOutcome(failure: SyncFailure.server));
    }
    s.nextDelay(const SyncOutcome());
    expect(
      s.nextDelay(const SyncOutcome(failure: SyncFailure.server)),
      const Duration(seconds: 2),
    );
  });

  test('Retry-After wins when it asks for longer', () {
    final s = scheduler();
    random.value = 0;
    expect(
      s.nextDelay(
        const SyncOutcome(
          failure: SyncFailure.rateLimited,
          retryAfter: Duration(seconds: 45),
        ),
      ),
      const Duration(seconds: 45),
    );
  });

  test('rows still owed while the server answers never wait longer than a '
      'poll', () {
    final s = scheduler();
    random.value = 1;
    const owed = SyncOutcome(
      nextPoll: Duration(seconds: 60),
      push: PushReport(remaining: 3),
    );
    for (var i = 0; i < 20; i++) {
      expect(s.nextDelay(owed), lessThanOrEqualTo(const Duration(seconds: 72)));
    }
  });

  test('an outdated app rechecks hourly instead of hammering', () {
    final s = scheduler();
    expect(
      s.nextDelay(const SyncOutcome(failure: SyncFailure.schemaOutdated)),
      const Duration(hours: 1),
    );
  });

  test(
    'a nudge is debounced, and bounded to once per 30s after a run',
    () async {
      final s = scheduler()..start(initialDelay: const Duration(minutes: 4));
      expect(timers.single.delay, const Duration(minutes: 4));

      // Inside the startup spread a nudge changes nothing: the spread is the
      // fleet's, and shortening it is the stampede it exists to prevent.
      s.nudge();
      expect(timers, hasLength(1));
      expect(timers.single.isActive, isTrue);

      timers.last.fire();
      await _settle();
      expect(runs, [false]);

      // Connectivity back after that run, past the 30s bound: debounced 5s.
      now = now.add(const Duration(seconds: 40));
      s.nudge();
      expect(timers.last.delay, const Duration(seconds: 5));
      timers.last.fire();
      await _settle();
      expect(runs, [false, false]);

      // Ten seconds after that run, another nudge waits out the 30s bound.
      now = now.add(const Duration(seconds: 10));
      s.nudge();
      expect(timers.last.delay, const Duration(seconds: 20));
    },
  );

  test('a nudge never postpones a run that is already due sooner', () {
    final s = scheduler()..start(initialDelay: const Duration(seconds: 2));
    s.nudge();
    expect(timers, hasLength(1));
    expect(timers.single.isActive, isTrue);
  });

  test('"Sync now" runs a full pull at once', () async {
    final s = scheduler()..start(initialDelay: const Duration(minutes: 3));
    await s.syncNow();
    expect(runs, [true]);
    expect(timers.first.isActive, isFalse);
  });

  test('a revoked device stops being scheduled', () async {
    nextOutcome = () => const SyncOutcome(failure: SyncFailure.unauthorized);
    final s = scheduler()..start();
    timers.single.fire();
    await _settle();
    expect(s.isStarted, isFalse);
    expect(timers, hasLength(1));
  });
}
