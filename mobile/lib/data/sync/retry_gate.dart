/// "Do not ask the server again before …", shared by every request a device
/// makes.
///
/// A `Retry-After` is an instruction about the device, not about one request:
/// the server's limiter counts every call carrying this token. So the gate is
/// armed by any 429 (or a 503 with `Retry-After`) and consulted before every
/// sync request, the `/devices/me` check, the scheduler's timer, a
/// connectivity nudge and the manual "Sync now" alike. Honouring it in one of
/// those and not the others is not honouring it.
///
/// In memory only. A restart forgets it, and the startup spread then delays
/// the first request anyway.
class RetryGate {
  RetryGate({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  DateTime? _blockedUntil;

  /// A 429 that names no wait still means "not now".
  static const defaultWait = Duration(seconds: 30);

  /// Bounds a hostile or broken header, so a till never goes dark for a day.
  static const maxWait = Duration(hours: 1);

  DateTime? get blockedUntil {
    final until = _blockedUntil;
    if (until != null && !until.isAfter(_clock())) _blockedUntil = null;
    return _blockedUntil;
  }

  bool get isBlocked => blockedUntil != null;

  /// How long until requests may resume; zero when they already may.
  Duration get remaining {
    final until = blockedUntil;
    return until == null ? Duration.zero : until.difference(_clock());
  }

  /// Blocks requests for [wait] from now. Never shortens a longer block.
  void arm(Duration? wait) {
    var value = wait ?? defaultWait;
    if (value <= Duration.zero) value = defaultWait;
    if (value > maxWait) value = maxWait;
    final until = _clock().add(value);
    final current = blockedUntil;
    if (current == null || until.isAfter(current)) _blockedUntil = until;
  }
}
