import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../sync/retry_gate.dart';
import '../sync/sync_client.dart' show parseRetryAfter;
import 'device_registration.dart';

abstract interface class DeviceCredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureDeviceCredentialStore implements DeviceCredentialStore {
  const SecureDeviceCredentialStore();
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

enum ActivationFailure {
  invalidCode,
  rateLimited,
  network,
  storage,
  revoked,
  configuration,
}

class DeviceActivationException implements Exception {
  const DeviceActivationException(this.failure);
  final ActivationFailure failure;
}

/// Activates this installation against a register through `/api/v2`.
///
/// No automatic retry of a one-use activation POST. A lost response needs a
/// newly issued code; guessing whether the first transaction committed is unsafe.
class DeviceActivationRepository {
  DeviceActivationRepository({
    required String baseUrl,
    http.Client? client,
    DeviceCredentialStore? store,
    DateTime Function()? clock,
  }) : baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), ''),
       _client = client ?? http.Client(),
       _store = store ?? const SecureDeviceCredentialStore(),
       _clock = clock ?? DateTime.now {
    final uri = Uri.tryParse(this.baseUrl);
    final local = [
      'localhost',
      '127.0.0.1',
      '::1',
      '10.0.2.2',
    ].contains(uri?.host);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(local && uri.scheme == 'http'))) {
      throw const DeviceActivationException(ActivationFailure.configuration);
    }
  }

  final String baseUrl;
  final http.Client _client;
  final DeviceCredentialStore _store;
  final DateTime Function() _clock;
  String get _key => 'device_binding_${sha256.convert(utf8.encode(baseUrl))}';
  void close() => _client.close();

  Future<DeviceRegistration?> load() async {
    try {
      final raw = await _store.read(_key);
      if (raw == null) return null;
      final binding = DeviceRegistration.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (binding.baseUrl != baseUrl || !binding.expiresAt.isAfter(_clock())) {
        await _store.delete(_key);
        return null;
      }
      return binding;
    } catch (_) {
      throw const DeviceActivationException(ActivationFailure.storage);
    }
  }

  Future<DeviceRegistration> activate(
    String code, {
    required String platform,
  }) async {
    String installation;
    try {
      installation =
          await _store.read('${_key}_installation') ?? const Uuid().v4();
      await _store.write('${_key}_installation', installation);
    } catch (_) {
      throw const DeviceActivationException(ActivationFailure.storage);
    }
    final normalized = code.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    final response = await _send(
      http.Request('POST', Uri.parse('$baseUrl/devices/activate'))
        ..headers.addAll({
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode({
          'code': normalized,
          'device_uuid': installation,
          'platform': platform,
        }),
    );
    if (response.statusCode == 429) {
      throw const DeviceActivationException(ActivationFailure.rateLimited);
    }
    // `invalid_code` and `bound_to_another_register` alike: both need a new
    // code, and the server deliberately does not say which condition tripped.
    if (response.statusCode == 422) {
      throw const DeviceActivationException(ActivationFailure.invalidCode);
    }
    // v2 answers 200. Anything else — a v1 server's 201 included — is not the
    // contract this build speaks, and is treated as not having activated.
    if (response.statusCode != 200) {
      throw const DeviceActivationException(ActivationFailure.network);
    }
    late DeviceRegistration binding;
    try {
      binding = DeviceRegistration.fromJson({
        ..._data(response.body),
        'base_url': baseUrl,
      });
      if (!binding.expiresAt.isAfter(_clock())) {
        throw const FormatException('Expired token');
      }
    } catch (_) {
      throw const DeviceActivationException(ActivationFailure.network);
    }
    try {
      // Token and binding are one atomic secure-storage value.
      await _store.write(_key, jsonEncode(binding.toJson()));
    } catch (_) {
      throw const DeviceActivationException(ActivationFailure.storage);
    }
    return binding;
  }

  /// Re-reads the binding from `/devices/me`, persists it, and returns it.
  ///
  /// Called only when `/sync/changes` reports a `device_revision` this device
  /// has not confirmed — never at launch and never on a timer, so it rides
  /// inside the startup spread and the poll cadence rather than around them.
  ///
  /// **The refreshed binding is written back to secure storage.** Returning it
  /// and dropping it meant the next launch read the old one again.
  ///
  /// [gate] is the device's shared `Retry-After` gate: a blocked gate sends
  /// nothing, and a 429 (or a 503 naming a wait) arms it for every other
  /// request too.
  Future<DeviceRegistration> verify(
    DeviceRegistration binding, {
    RetryGate? gate,
  }) async {
    if (!binding.expiresAt.isAfter(_clock())) {
      await _store.delete(_key);
      throw const DeviceActivationException(ActivationFailure.revoked);
    }
    if (gate != null && gate.isBlocked) {
      throw const DeviceActivationException(ActivationFailure.rateLimited);
    }
    final response = await _send(
      http.Request('GET', Uri.parse('$baseUrl/devices/me'))
        ..headers.addAll({
          'Accept': 'application/json',
          'Authorization': 'Bearer ${binding.token}',
        }),
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      await _store.delete(_key);
      throw const DeviceActivationException(ActivationFailure.revoked);
    }
    final wait = parseRetryAfter(response.headers['retry-after']);
    if (response.statusCode == 429 ||
        (response.statusCode == 503 && wait != null)) {
      gate?.arm(wait);
      throw const DeviceActivationException(ActivationFailure.rateLimited);
    }
    if (response.statusCode != 200) {
      throw const DeviceActivationException(ActivationFailure.network);
    }
    late DeviceRegistration refreshed;
    try {
      refreshed = DeviceRegistration.fromJson({
        ...binding.toJson(),
        ..._data(response.body),
      });
    } catch (_) {
      throw const DeviceActivationException(ActivationFailure.network);
    }
    if (refreshed.storageScope != binding.storageScope) {
      await _store.delete(_key);
      throw const DeviceActivationException(ActivationFailure.revoked);
    }
    try {
      await _store.write(_key, jsonEncode(refreshed.toJson()));
    } catch (_) {
      throw const DeviceActivationException(ActivationFailure.storage);
    }
    return refreshed;
  }

  /// The `data` object of a v2 envelope.
  static Map<String, dynamic> _data(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic> ||
        decoded['data'] is! Map<String, dynamic>) {
      throw const FormatException('Missing data envelope');
    }
    return decoded['data'] as Map<String, dynamic>;
  }

  Future<http.Response> _send(http.Request request) async {
    // Never forward a bearer token or activation secret across a redirect.
    request.followRedirects = false;
    try {
      return await (() async {
        final streamed = await _client.send(request);
        return http.Response.fromStream(streamed);
      })().timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const DeviceActivationException(ActivationFailure.network);
    }
  }
}
