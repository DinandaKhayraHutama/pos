import 'dart:convert';

import 'package:http/http.dart' as http;

import 'retry_gate.dart';

/// The sync schema this build reads and writes.
///
/// Sent on every sync request as `X-Schema-Version`. A server that has moved
/// past it answers 409 `device_schema_outdated`, and the till asks for an app
/// update instead of guessing at columns it cannot store.
const kClientSchemaVersion = 1;

/// Features this build can execute safely. Sent on activation and every API
/// request so the server can refuse a v2 rollout while an old till remains.
const kClientCapabilities = 'bills-v1,pricing-v2,roles-v1';

/// Why a sync request stopped.
///
/// **None of these ever authorizes deleting queued work.** The v1 client mapped
/// a 422 and a non-object 2xx body to `malformed` and then DROPPED the queued
/// sale. In v2 every failure here leaves the outbox exactly as it was; only a
/// per-row `accepted` result removes a row, and only a per-row `rejected`
/// result moves one — into the dead-letter table, never into nothing.
enum SyncFailure {
  /// No response at all: offline, timeout, TLS, DNS, or a redirect.
  network,

  /// 401/403: revoked or expired. Only re-activation fixes it.
  unauthorized,

  /// 409 `device_schema_outdated`: this build is too old for the server.
  schemaOutdated,

  /// 429: wait for [SyncException.retryAfter] before asking again.
  rateLimited,

  /// Any other non-2xx — 400, 413, 422, 5xx. Retryable.
  server,

  /// A 2xx whose body is not a JSON object, or lacks what the contract
  /// promises. Retryable, and never a reason to drop a row.
  malformed,
}

class SyncException implements Exception {
  const SyncException(this.failure, [this.detail, this.retryAfter]);

  final SyncFailure failure;
  final String? detail;

  /// From `Retry-After` on a 429 or 503, when the server sent one.
  final Duration? retryAfter;

  @override
  String toString() =>
      'SyncException($failure${detail == null ? '' : ': $detail'})';
}

/// The one place a device talks to the sync API.
///
/// Pull and push share it so they cannot drift on the things that must match:
/// the bearer token, the schema header, the timeout, and — most importantly —
/// what each status code MEANS. A 401 handled as "retry later" in one direction
/// and "re-activate" in the other is a till that spins forever on a revoked
/// token.
class SyncClient {
  SyncClient({
    required String baseUrl,
    required String token,
    http.Client? client,
    RetryGate? gate,
    this.timeout = const Duration(seconds: 30),
  }) : baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), ''),
       _token = token,
       _client = client ?? http.Client(),
       gate = gate ?? RetryGate();

  final String baseUrl;
  final String _token;
  final http.Client _client;
  final Duration timeout;

  /// Armed by any `Retry-After`; while armed, no request leaves this client.
  final RetryGate gate;

  void close() => _client.close();

  Map<String, String> extraHeaders = const {};

  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) {
    var uri = Uri.parse('$baseUrl$path');
    if (query != null) uri = uri.replace(queryParameters: query);
    return _send(http.Request('GET', uri));
  }

  /// POSTs [body]. A [String] is sent verbatim, so a retry resends the exact
  /// bytes of a stored snapshot; anything else is JSON-encoded.
  Future<Map<String, dynamic>> post(String path, Object body) {
    final request = http.Request('POST', Uri.parse('$baseUrl$path'))
      ..headers['Content-Type'] = 'application/json'
      ..body = body is String ? body : jsonEncode(body);
    return _send(request);
  }

  Future<Map<String, dynamic>> _send(http.Request request) async {
    // The server asked for quiet. Refused here, before any socket opens, so no
    // caller — pull, push, a retry loop — can ask again early.
    final blocked = gate.remaining;
    if (blocked > Duration.zero) {
      throw SyncException(
        SyncFailure.rateLimited,
        'not sent: waiting for Retry-After',
        blocked,
      );
    }

    request.headers.addAll({
      ...extraHeaders,
      'Authorization': 'Bearer $_token',
      'Accept': 'application/json',
      'X-Schema-Version': '$kClientSchemaVersion',
      'X-Device-Capabilities': kClientCapabilities,
    });
    // Never forward a bearer token across a redirect. A 3xx from the sync API
    // is a misconfiguration, and following it would hand the credential to
    // whatever host the Location header names.
    request.followRedirects = false;

    late http.Response response;
    try {
      response = await (() async {
        final streamed = await _client.send(request);
        return http.Response.fromStream(streamed);
      })().timeout(timeout);
    } catch (e) {
      // The type only: an exception's message can carry the request URL.
      throw SyncException(SyncFailure.network, e.runtimeType.toString());
    }

    final status = response.statusCode;

    // Not retryable: the device was revoked or its token expired, and the only
    // cure is re-activation. Surfaced distinctly so the caller sends the user to
    // the activation screen instead of spinning on a token nobody honours.
    if (status == 401 || status == 403) {
      throw const SyncException(SyncFailure.unauthorized);
    }

    if (status == 409 &&
        _errorCode(response.body) == 'device_schema_outdated') {
      throw const SyncException(SyncFailure.schemaOutdated);
    }

    if (status == 429) {
      final wait = _retryAfter(response) ?? RetryGate.defaultWait;
      gate.arm(wait);
      throw SyncException(
        SyncFailure.rateLimited,
        'HTTP 429',
        _longer(wait, gate.remaining),
      );
    }

    // Everything else that is not a 2xx is a server problem or a transient
    // one — including 422, which v2 never uses for row contents. Retrying later
    // is always safe, because nothing has been removed. A 503 that names a wait
    // arms the gate like a 429 does.
    if (status < 200 || status >= 300) {
      final wait = _retryAfter(response);
      if (wait != null) gate.arm(wait);
      throw SyncException(
        SyncFailure.server,
        _errorCode(response.body) ?? 'HTTP $status',
        wait == null ? null : _longer(wait, gate.remaining),
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const SyncException(SyncFailure.malformed, 'body is not JSON');
    }
    // The contract says every 2xx body is an object. `[]`, `"ok"`, `null` and
    // an empty body are all a server that is not keeping it, and the answer is
    // to keep every row and try again — not to guess what it meant.
    if (decoded is! Map<String, dynamic>) {
      throw const SyncException(
        SyncFailure.malformed,
        '2xx body is not a JSON object',
      );
    }
    return decoded;
  }

  static String? _errorCode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        final code = (decoded['error'] as Map)['code'];
        return code is String ? code : null;
      }
    } catch (_) {
      // An unreadable error body carries no code.
    }
    return null;
  }

  static Duration? _retryAfter(http.Response response) =>
      parseRetryAfter(response.headers['retry-after']);

  /// What the caller is told to wait: what this response asked for, or the
  /// longer block an earlier response already set.
  static Duration _longer(Duration a, Duration b) => a > b ? a : b;
}

/// Whole seconds from a `Retry-After` header, capped by [RetryGate.maxWait];
/// null when absent or unreadable.
Duration? parseRetryAfter(String? raw) {
  final seconds = raw == null ? null : int.tryParse(raw.trim());
  if (seconds == null || seconds < 1) return null;
  final value = Duration(seconds: seconds);
  return value > RetryGate.maxWait ? RetryGate.maxWait : value;
}
