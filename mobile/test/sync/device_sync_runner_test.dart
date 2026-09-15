import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/device_registration.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/sync/device_sync_runner.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:nti_pos/data/sync/sync_state_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _pullable = [
  'employees',
  'outlets',
  'pos_registers',
  'categories',
  'products',
  'product_variants',
  'modifier_groups',
  'promos',
];

/// A fake v2 device API: changes, manifest, pull and push.
class _Api {
  final requests = <String>[];
  Map<String, int> cursors = {};
  final rows = <String, List<Map<String, dynamic>>>{};
  int? changesStatus;
  String changesBody = '{}';
  int? pullStatus;

  http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

  http.Client get client => MockClient((request) async {
    final url = request.url;
    requests.add(url.path.replaceFirst('/api/v2', ''));
    switch (url.path) {
      case '/api/v2/sync/changes':
        if (changesStatus != null) {
          return http.Response(changesBody, changesStatus!);
        }
        return _json({
          'cursors': cursors,
          'device_revision': 7,
          'server_time_ms': 1757800000000,
          'next_poll_ms': 30000,
        });
      case '/api/v2/sync/manifest':
        return _json({
          'schema_version': 1,
          'entities': [
            for (final name in _pullable)
              {
                'name': name,
                'scope': 'company',
                'key': ['id'],
                'depends_on': <String>[],
                'pull': true,
                'push': false,
                'apply': 'upsert',
              },
            for (final name in ['pos_sessions', 'orders'])
              {
                'name': name,
                'scope': 'outlet',
                'key': ['id'],
                'depends_on': <String>[],
                'pull': false,
                'push': true,
                'apply': 'upsert',
              },
          ],
        });
      case '/api/v2/sync/pull':
        if (pullStatus != null) return http.Response('{}', pullStatus!);
        final entity = url.queryParameters['entity']!;
        final after = int.parse(url.queryParameters['after_seq']!);
        final above = [
          for (final row in rows[entity] ?? const <Map<String, dynamic>>[])
            if ((row['sync_seq'] as int) > after) row,
        ];
        return _json({
          'entity': entity,
          'rows': above,
          'next_seq': above.isEmpty ? after : above.last['sync_seq'],
          'has_more': false,
          'schema_version': 1,
        });
      case '/api/v2/sync/push':
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final results = <Map<String, Object?>>[];
        final batches = body['batches'] as List;
        for (var b = 0; b < batches.length; b++) {
          final batch = batches[b] as Map<String, dynamic>;
          final list = batch['rows'] as List;
          for (var r = 0; r < list.length; r++) {
            final row = list[r] as Map<String, dynamic>;
            results.add({
              'batch_index': b,
              'row_index': r,
              'entity': batch['entity'],
              'id': row['id'],
              'revision': row['revision'],
              'status': 'accepted',
            });
          }
        }
        return _json({'results': results, 'server_time_ms': 1757800000000});
    }
    return http.Response('{"error":{"code":"not_found"}}', 404);
  });
}

DeviceRegistration _binding() => DeviceRegistration(
  baseUrl: 'https://api.test/api/v2',
  token: 'tok',
  expiresAt: DateTime.utc(2030),
  device: {'id': 'device-1'},
  tenant: {'id': 'tenant-1', 'name': 'Warung'},
  outlet: {'id': 'outlet-1', 'name': 'Kemang'},
  register: {
    'id': 'register-1',
    'outlet_id': 'outlet-1',
    'name': 'Kasir 1',
    'table_service': true,
  },
);

/// One sync run: the fast path, the pull it decides on, and the push that must
/// happen whatever the pull did.
void main() {
  late Database db;
  late _Api api;
  var revoked = 0;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    api = _Api();
    revoked = 0;
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  DeviceSyncRunner runner() {
    final client = SyncClient(
      baseUrl: 'https://api.test/api/v2',
      token: 'tok',
      client: api.client,
    );
    addTearDown(client.close);
    return DeviceSyncRunner(
      binding: _binding(),
      client: client,
      onUnauthorized: () => revoked++,
    );
  }

  Future<void> queueSale() async {
    final shift = await ShiftRepository.instance.open(
      employeeId: 'e1',
      employeeName: 'Siti',
      openingCash: 100000,
      posId: 'register-1',
      posName: 'Kasir 1',
    );
    await OrderRepository.instance.create(
      type: OrderType.takeaway,
      items: const [
        OrderItemDraft(
          productId: 'p1',
          productName: 'Es Teh',
          unitPrice: 5000,
          quantity: 1,
        ),
      ],
      subtotal: 5000,
      discount: 0,
      tax: 0,
      total: 5000,
      amountPaid: 5000,
      paymentMethod: PaymentMethod.cash,
      cashierId: 'e1',
      cashierName: 'Siti',
      posSessionId: shift.id,
    );
  }

  test('nothing changed: one request for the whole poll', () async {
    final outcome = await runner().syncNow();

    expect(api.requests, ['/sync/changes']);
    expect(outcome!.failure, isNull);
    expect(outcome.nextPoll, const Duration(seconds: 30));
    expect(outcome.deviceRevision, 7);
  });

  test('a moved cursor pulls that feed and no other', () async {
    api.cursors = {'categories': 3, 'products': 0};
    api.rows['categories'] = [
      {
        'id': 'c1',
        'name': 'Minuman',
        'icon_key': 'local_cafe',
        'sort_order': 0,
        'is_popular': false,
        'sync_seq': 3,
        'deleted_at_ms': null,
      },
    ];

    await runner().syncNow();

    expect(api.requests, ['/sync/changes', '/sync/manifest', '/sync/pull']);
    expect(await db.query('categories'), hasLength(1));
    expect(await SyncStateStore.instance.lastSeq('categories'), 3);

    // The hint was never stored as a cursor for a feed that was not pulled.
    expect(await SyncStateStore.instance.lastSeq('products'), 0);
  });

  test('the push still runs when the pull fails', () async {
    api.cursors = {'categories': 3};
    api.pullStatus = 500;
    await queueSale();

    final outcome = await runner().syncNow();

    expect(api.requests.last, '/sync/push');
    expect(outcome!.failure, SyncFailure.server);
    expect(outcome.pullInterrupted, isTrue);
    expect(await OutboxStore.instance.count(), 0);
  });

  test('a revoked device says so once and keeps every queued sale', () async {
    await queueSale();
    api.changesStatus = 401;

    final outcome = await runner().syncNow();

    expect(outcome!.unauthorized, isTrue);
    expect(revoked, 1);
    expect(api.requests, ['/sync/changes']);
    expect(await OutboxStore.instance.count(), 2);
  });

  test('an outdated app stops and touches nothing', () async {
    await queueSale();
    api.changesStatus = 409;
    api.changesBody =
        '{"error":{"code":"device_schema_outdated","message":"update"}}';

    final outcome = await runner().syncNow();

    expect(outcome!.schemaOutdated, isTrue);
    expect(revoked, 0);
    expect(await OutboxStore.instance.count(), 2);
  });

  test('a full sync asks every supported feed and skips the rest', () async {
    await runner().syncNow(full: true);

    expect(api.requests.contains('/sync/changes'), isFalse);
    final pulls = api.requests.where((p) => p == '/sync/pull').length;
    // Fase 6 now consumes modifiers and promos too. Push-only feeds stay out.
    expect(pulls, _pullable.length);
  });
}
