import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Server-issued binding. Local selections never override this identity.
class DeviceRegistration {
  DeviceRegistration({
    required this.baseUrl,
    required this.token,
    required this.expiresAt,
    required this.device,
    required this.tenant,
    required this.outlet,
    required this.register,
  });

  final String baseUrl;
  final String token;
  final DateTime expiresAt;
  final Map<String, dynamic> device;
  final Map<String, dynamic> tenant;
  final Map<String, dynamic> outlet;
  final Map<String, dynamic> register;

  String get deviceId => device['id'] as String;

  String get storageScope => sha256
      .convert(
        utf8.encode(
          '$baseUrl/${tenant['id']}/${device['id']}/${register['id']}',
        ),
      )
      .toString();

  /// Reads a binding from the v2 `data` object (plus `base_url`), or from what
  /// [toJson] stored.
  ///
  /// Expiry is epoch milliseconds, `token_expires_at_ms`, like every v2
  /// timestamp. An ISO `token_expires_at` is still read, because a binding
  /// saved by a v1 build may sit in secure storage until it is replaced.
  factory DeviceRegistration.fromJson(Map<String, dynamic> json) {
    final expiresMs = json['token_expires_at_ms'];
    final legacyExpiry = json['token_expires_at'];
    final DateTime expiresAt;
    if (expiresMs is int) {
      expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresMs, isUtc: true);
    } else if (legacyExpiry is String) {
      expiresAt = DateTime.parse(legacyExpiry);
    } else {
      throw const FormatException('Missing token expiry');
    }

    final record = DeviceRegistration(
      baseUrl: json['base_url'] as String,
      token: json['token'] as String,
      expiresAt: expiresAt,
      device: Map<String, dynamic>.from(json['device'] as Map),
      tenant: Map<String, dynamic>.from(json['tenant'] as Map),
      outlet: Map<String, dynamic>.from(json['outlet'] as Map),
      register: Map<String, dynamic>.from(json['pos_register'] as Map),
    );
    for (final entity in [
      record.device,
      record.tenant,
      record.outlet,
      record.register,
    ]) {
      if (entity['id'] is! String || (entity['id'] as String).isEmpty) {
        throw const FormatException('Missing binding identity');
      }
    }
    if (record.token.isEmpty ||
        record.register['outlet_id'] != record.outlet['id']) {
      throw const FormatException('Invalid device binding');
    }
    return record;
  }

  Map<String, dynamic> toJson() => {
    'base_url': baseUrl,
    'token': token,
    'token_expires_at_ms': expiresAt.millisecondsSinceEpoch,
    'device': device,
    'tenant': tenant,
    'outlet': outlet,
    'pos_register': register,
  };
}
