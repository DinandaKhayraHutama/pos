import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../device/till_coordinator.dart';
import '../models/order.dart';
import '../models/order_item.dart';
import '../models/order_item_modifier.dart';
import '../sync/wire_values.dart';

/// How a page of server receipts was scoped.
///
/// The value is the server's own vocabulary, so what the app asked for and
/// what the server says it applied are comparable without a translation table.
class RemoteScope {
  static const register = 'register';
  static const outlet = 'outlet';
}

/// The group of statuses people ask for, as opposed to one kitchen status.
const String kRemoteStatusSales = 'sales';

/// One query over server receipts.
///
/// [key] is what the cache is filed under. It includes every field, so
/// changing any filter is a different cache entry rather than a stale one:
/// "the last page I downloaded" is only a meaningful claim about one filter.
class RemoteOrderFilter {
  const RemoteOrderFilter({
    required this.from,
    required this.to,
    this.scope = RemoteScope.register,
    this.status,
    this.receipt,
    this.cashierId,
  });

  /// Today on the device's clock, the view a till opens on.
  factory RemoteOrderFilter.today({String scope = RemoteScope.register}) {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    return RemoteOrderFilter(from: day, to: day, scope: scope);
  }

  final DateTime from;
  final DateTime to;
  final String scope;
  final String? status;
  final String? receipt;
  final String? cashierId;

  String get fromDate => businessDateFor(from);
  String get toDate => businessDateFor(to);

  bool get isSingleDay => fromDate == toDate;

  RemoteOrderFilter copyWith({
    DateTime? from,
    DateTime? to,
    String? scope,
    Object? status = _unset,
    Object? receipt = _unset,
    Object? cashierId = _unset,
  }) => RemoteOrderFilter(
    from: from ?? this.from,
    to: to ?? this.to,
    scope: scope ?? this.scope,
    status: status == _unset ? this.status : status as String?,
    receipt: receipt == _unset ? this.receipt : receipt as String?,
    cashierId: cashierId == _unset ? this.cashierId : cashierId as String?,
  );

  static const _unset = Object();

  String get key =>
      '$fromDate|$toDate|$scope|${status ?? ''}|${receipt ?? ''}|${cashierId ?? ''}';

  Map<String, String> get query => {
    'from': fromDate,
    'to': toDate,
    'scope': scope,
    if (status != null && status!.isNotEmpty) 'status': status!,
    if (receipt != null && receipt!.isNotEmpty) 'receipt_number': receipt!,
    if (cashierId != null && cashierId!.isNotEmpty) 'cashier_id': cashierId!,
  };

  @override
  bool operator ==(Object other) =>
      other is RemoteOrderFilter && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// One page of server receipts, and what the server said about it.
class RemoteOrderPage {
  const RemoteOrderPage({
    required this.orders,
    required this.next,
    required this.scope,
    required this.fromCache,
    this.cachedAt,
    this.complete = true,
  });

  final List<Order> orders;

  /// The server's cursor for the following page, empty at the end.
  final String next;

  /// The scope the SERVER applied, which may be narrower than the one asked
  /// for. A cashier who asked for the whole branch is given their own
  /// register, and the screen has to be able to say so.
  final String scope;

  /// True when the network failed and this came out of SQLite.
  final bool fromCache;

  /// When the cached copy was downloaded. Null for a live page.
  final DateTime? cachedAt;

  /// Whether the cached range had been downloaded to its end. False means
  /// "there is more, and this device has not seen it" — which is a different
  /// statement from "there is nothing more".
  final bool complete;

  bool get hasMore => next.isNotEmpty;
}

/// Read-only server receipts.
///
/// This cache never participates in the outbox, stock, receipt-number
/// allocation or local drawer totals. It is a picture of what the server holds,
/// and local rows always win when the two describe the same receipt: the
/// device's own sale is the one it is accountable for.
///
/// Three rules it keeps:
///
///  * **One page per request.** The old loop downloaded every page before
///    returning, which on a busy month was a minutes-long freeze and a
///    megabyte of receipts nobody scrolled to.
///  * **Cached per viewer.** The row key carries the employee, so a manager's
///    wider fetch cannot overwrite what a cashier is allowed to see, and
///    signing a different person in does not show them the last person's list.
///  * **Absence is recorded.** An empty period that WAS downloaded is
///    remembered as empty; a period that was never downloaded is not. Offline,
///    the two produce different screens.
class RemoteOrderRepository {
  /// Fetches one page from the server, caching what comes back.
  ///
  /// A network failure falls back to whatever this viewer already downloaded
  /// for exactly this filter, labelled as cached. It never falls back to a
  /// DIFFERENT filter's rows: showing last week's receipts under this week's
  /// heading is worse than saying the data is not here.
  static Future<RemoteOrderPage> page(
    String employee,
    RemoteOrderFilter filter, {
    String cursor = '',
  }) async {
    final api = TillCoordinator.current;
    if (api == null) {
      return const RemoteOrderPage(
        orders: [],
        next: '',
        scope: RemoteScope.register,
        fromCache: false,
      );
    }
    try {
      final response = await api.call(
        employee,
        '/till/orders',
        query: {...filter.query, if (cursor.isNotEmpty) 'before': cursor},
      );
      final data = response['data'] as Map<String, dynamic>;
      final rows = (data['rows'] as List).cast<Map<String, dynamic>>();
      final next = (data['next'] as String?) ?? '';
      // The scope the server actually applied, not the one that was asked for.
      final scope = (data['scope'] as String?) ?? filter.scope;

      await _store(employee, scope, filter, rows, cursor: cursor, next: next);
      return RemoteOrderPage(
        orders: rows.map(decode).toList(),
        next: next,
        scope: scope,
        fromCache: false,
      );
    } on TillOperationException {
      return _cached(employee, filter, cursor: cursor);
    }
  }

  /// Everything cached for one filter, without touching the network. Used by
  /// the offline path and by the tests that pin it.
  static Future<RemoteOrderPage> cachedPage(
    String employee,
    RemoteOrderFilter filter, {
    String cursor = '',
  }) => _cached(employee, filter, cursor: cursor);

  static Future<void> _store(
    String employee,
    String scope,
    RemoteOrderFilter filter,
    List<Map<String, dynamic>> rows, {
    required String cursor,
    required String next,
  }) async {
    final db = await AppDatabase.instance.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((tx) async {
      for (final row in rows) {
        await tx.insert('_remote_orders', {
          'id': row['id'],
          'employee_id': employee,
          // The business date comes from the payload, never from the device
          // clock: a receipt rung up at 00:10 belongs to the trading day the
          // till filed it under, not to the calendar day it is read on.
          'business_date': row['business_date'],
          'scope': scope,
          'register_id': row['pos_id'],
          'cashier_id': row['cashier_id'],
          'status': row['status'],
          'placed_at_ms': row['placed_at_ms'] ?? 0,
          'payload': jsonEncode(row),
          'fetched_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // The first page of a filter resets its record; a following page adds to
      // it. "Complete" means the server handed back no further cursor, so the
      // device has seen the whole range for this filter.
      final existing = cursor.isEmpty
          ? null
          : (await tx.query(
              '_remote_history_meta',
              where: 'employee_id = ? AND scope = ? AND filter_key = ?',
              whereArgs: [employee, scope, filter.key],
            )).firstOrNull;
      final seen = ((existing?['row_count'] as int?) ?? 0) + rows.length;
      await tx.insert('_remote_history_meta', {
        'employee_id': employee,
        'scope': scope,
        'filter_key': filter.key,
        'fetched_at': now,
        'complete': next.isEmpty ? 1 : 0,
        'row_count': seen,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Reads a page back out of SQLite with the same ordering and the same
  /// cursor shape the server uses, so an offline list pages exactly like an
  /// online one and a cursor works across the boundary.
  static Future<RemoteOrderPage> _cached(
    String employee,
    RemoteOrderFilter filter, {
    String cursor = '',
  }) async {
    final db = await AppDatabase.instance.db;
    final meta =
        (await db.query(
          '_remote_history_meta',
          where: 'employee_id = ? AND filter_key = ?',
          whereArgs: [employee, filter.key],
          orderBy: 'fetched_at DESC',
          limit: 1,
        )).firstOrNull;
    if (meta == null) {
      // Never downloaded. Deliberately NOT an empty list: the screen has to be
      // able to say "not available offline" rather than "no transactions".
      return RemoteOrderPage(
        orders: const [],
        next: '',
        scope: filter.scope,
        fromCache: true,
        complete: false,
      );
    }
    final scope = meta['scope'] as String;

    final where = StringBuffer(
      'employee_id = ? AND business_date BETWEEN ? AND ?',
    );
    final args = <Object?>[employee, filter.fromDate, filter.toDate];
    if (scope == RemoteScope.register) {
      final register =
          TillCoordinator.current?.binding.register['id'] as String?;
      if (register != null) {
        where.write(' AND (register_id IS NULL OR register_id = ?)');
        args.add(register);
      }
    }
    if (filter.cashierId != null && filter.cashierId!.isNotEmpty) {
      where.write(' AND cashier_id = ?');
      args.add(filter.cashierId);
    }
    if (filter.status == kRemoteStatusSales) {
      where.write(" AND status NOT IN ('cancelled', 'refunded')");
    } else if (filter.status != null && filter.status!.isNotEmpty) {
      where.write(' AND status = ?');
      args.add(filter.status);
    }
    if (filter.receipt != null && filter.receipt!.isNotEmpty) {
      where.write(" AND upper(json_extract(payload, '\$.number')) LIKE ?");
      args.add('${filter.receipt!.toUpperCase()}%');
    }
    final at = _parseCursor(cursor);
    if (at != null) {
      where.write(
        ' AND (business_date < ?'
        ' OR (business_date = ? AND placed_at_ms < ?)'
        ' OR (business_date = ? AND placed_at_ms = ? AND id < ?))',
      );
      args.addAll([at.date, at.date, at.ms, at.date, at.ms, at.id]);
    }

    const pageSize = 100;
    final rows = await db.query(
      '_remote_orders',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'business_date DESC, placed_at_ms DESC, id DESC',
      limit: pageSize + 1,
    );
    final page = rows.take(pageSize).toList();
    final more = rows.length > pageSize;
    return RemoteOrderPage(
      orders: page
          .map((r) => decode(jsonDecode(r['payload'] as String) as Map<String, dynamic>))
          .toList(),
      next: more && page.isNotEmpty
          ? '${page.last['business_date']}:${page.last['placed_at_ms']}:${page.last['id']}'
          : '',
      scope: scope,
      fromCache: true,
      cachedAt: DateTime.fromMillisecondsSinceEpoch(meta['fetched_at'] as int),
      complete: (meta['complete'] as int) == 1,
    );
  }

  static _Cursor? _parseCursor(String cursor) {
    if (cursor.isEmpty) return null;
    final parts = cursor.split(':');
    if (parts.length != 3) return null;
    final ms = int.tryParse(parts[1]);
    if (ms == null) return null;
    return _Cursor(parts[0], ms, parts[2]);
  }

  static Future<Order?> byId(String id, String employee) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      '_remote_orders',
      where: 'id = ? AND employee_id = ?',
      whereArgs: [id, employee],
    );
    return rows.isEmpty
        ? null
        : decode(jsonDecode(rows.first['payload'] as String) as Map<String, dynamic>);
  }

  /// Drops everything this device cached for a viewer. Signing out uses it, so
  /// the next person at the till never sees the last person's takings.
  static Future<void> forget(String employee) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((tx) async {
      await tx.delete(
        '_remote_orders',
        where: 'employee_id = ?',
        whereArgs: [employee],
      );
      await tx.delete(
        '_remote_history_meta',
        where: 'employee_id = ?',
        whereArgs: [employee],
      );
      await tx.delete(
        '_remote_reports',
        where: 'employee_id = ?',
        whereArgs: [employee],
      );
    });
  }

  static Order decode(Map<String, dynamic> row) {
    final items = (row['items'] as List).map((v) {
      final item = Map<String, dynamic>.from(v as Map);
      final mods = (item['modifiers'] as List? ?? []).map((v) {
        final m = Map<String, dynamic>.from(v as Map);
        return OrderItemModifier.fromMap({...m, 'order_item_id': item['id']});
      }).toList();
      return OrderItem.fromMap({
        ...item,
        'order_id': row['id'],
        'product_id': item['product_id'] ?? '',
      }, modifiers: mods);
    }).toList();
    return Order.fromMapRow({
      ...row,
      'created_at': row['placed_at_ms'],
      'read_only': true,
    }, items: items);
  }
}

class _Cursor {
  const _Cursor(this.date, this.ms, this.id);
  final String date;
  final int ms;
  final String id;
}
