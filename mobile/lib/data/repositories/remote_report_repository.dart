import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../device/till_coordinator.dart';
import '../models/server_report.dart';
import '../sync/wire_values.dart';

/// Which report to ask the server for.
///
/// Two endpoints rather than one with a flag, matching the API: the permission
/// is part of the contract, so an account that may not see costs cannot ask
/// for the financial body and be handed the summary one with fields missing.
enum ServerReportKind {
  /// `viewDailySummary`: sales, receipts and the waterfall. No costs.
  summary('/till/reports/summary'),

  /// `viewFinancialReports`: everything, costs and breakdowns included.
  sales('/till/reports/sales');

  const ServerReportKind(this.path);
  final String path;
}

/// A server report, and where this copy of it came from.
class ServerReportResult {
  const ServerReportResult({
    this.report,
    this.fromCache = false,
    this.cachedAt,
    this.forbidden = false,
  });

  final ServerReport? report;

  /// True when the network failed and this came out of SQLite.
  final bool fromCache;

  /// When the cached copy was downloaded. Null for a live answer.
  final DateTime? cachedAt;

  /// True when the server refused: this account may not open this report.
  /// Distinct from "no data", which is a report with zeroes in it.
  final bool forbidden;

  /// True when there is nothing to show at all — not refused, not cached,
  /// simply never downloaded. The screen says so rather than drawing zeroes,
  /// because an outlet total of zero and an outlet total nobody has is not the
  /// same claim.
  bool get unavailable => report == null && !forbidden;
}

/// Outlet-wide report figures, read from the server and cached for offline.
///
/// The cache is keyed by viewer, endpoint and filter. All three matter:
///
///  * **viewer**, so signing a different person in never shows the last
///    person's takings, and a manager's copy is not served to a cashier;
///  * **endpoint**, because the summary body has no costs in it and must not
///    stand in for the financial one;
///  * **filter**, because "the last report I downloaded" is only a meaningful
///    claim about one period and one outlet.
class RemoteReportRepository {
  /// Asks the server, caching what comes back. A network failure falls back to
  /// the cached copy for exactly this key, labelled as cached.
  static Future<ServerReportResult> fetch({
    required String employee,
    required ServerReportKind kind,
    required DateTime from,
    required DateTime to,
    String? outletId,
  }) async {
    final api = TillCoordinator.current;
    final key = _key(from, to, outletId);
    if (api == null) return const ServerReportResult();

    try {
      final response = await api.call(
        employee,
        kind.path,
        query: {
          'period': 'custom',
          'from': businessDateFor(from),
          'to': businessDateFor(to),
          if (outletId != null && outletId.isNotEmpty) 'outlet_id': outletId,
        },
      );
      final data = Map<String, dynamic>.from(response['data'] as Map);
      await _store(employee, kind, key, data);
      return ServerReportResult(report: ServerReport.fromJson(data));
    } on TillOperationException catch (e) {
      // A refusal is an answer, not an outage: falling back to a cached copy
      // would show figures the account has just been told it may not see.
      if (e.code == 'forbidden') {
        return const ServerReportResult(forbidden: true);
      }
      return _cached(employee, kind, key);
    }
  }

  /// The cached copy without touching the network.
  static Future<ServerReportResult> cached({
    required String employee,
    required ServerReportKind kind,
    required DateTime from,
    required DateTime to,
    String? outletId,
  }) => _cached(employee, kind, _key(from, to, outletId));

  static String _key(DateTime from, DateTime to, String? outletId) =>
      '${businessDateFor(from)}|${businessDateFor(to)}|${outletId ?? ''}';

  static Future<void> _store(
    String employee,
    ServerReportKind kind,
    String key,
    Map<String, dynamic> data,
  ) async {
    final db = await AppDatabase.instance.db;
    await db.insert('_remote_reports', {
      'employee_id': employee,
      'endpoint': kind.name,
      'filter_key': key,
      'payload': jsonEncode(data),
      'fetched_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<ServerReportResult> _cached(
    String employee,
    ServerReportKind kind,
    String key,
  ) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      '_remote_reports',
      where: 'employee_id = ? AND endpoint = ? AND filter_key = ?',
      whereArgs: [employee, kind.name, key],
      limit: 1,
    );
    if (rows.isEmpty) return const ServerReportResult(fromCache: true);
    final row = rows.first;
    return ServerReportResult(
      report: ServerReport.fromJson(
        jsonDecode(row['payload'] as String) as Map<String, dynamic>,
      ),
      fromCache: true,
      cachedAt: DateTime.fromMillisecondsSinceEpoch(row['fetched_at'] as int),
    );
  }
}
