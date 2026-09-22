import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/order.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import 'package:nti_pos/data/repositories/shift_repository.dart';
import 'package:nti_pos/data/sync/dead_letter_store.dart';
import 'package:nti_pos/data/sync/order_push.dart';
import 'package:nti_pos/data/sync/outbox_push.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/session_push.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

typedef _Verdict =
    Map<String, Object?> Function(Map<String, dynamic> row, String entity);

/// A fake `POST /api/v2/sync/push`.
///
/// By default it accepts every row, echoing `id` and `revision` exactly as the
/// Go server does for a valid row.
class _PushServer {
  final requests = <Map<String, dynamic>>[];
  final rawBodies = <String>[];
  http.Response Function(Map<String, dynamic> body)? respond;
  Future<void> Function()? duringRequest;

  http.Client get client => MockClient((request) async {
    rawBodies.add(request.body);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    requests.add(body);
    await duringRequest?.call();
    return (respond ?? acceptAll)(body);
  });

  static http.Response reply(Object body) =>
      http.Response(jsonEncode(body), 200);

  static List<Map<String, Object?>> resultsFor(
    Map<String, dynamic> body,
    _Verdict verdict,
  ) {
    final results = <Map<String, Object?>>[];
    final batches = body['batches'] as List;
    for (var b = 0; b < batches.length; b++) {
      final batch = batches[b] as Map<String, dynamic>;
      final entity = batch['entity'] as String;
      final rows = batch['rows'] as List;
      for (var r = 0; r < rows.length; r++) {
        final row = rows[r] as Map<String, dynamic>;
        results.add({
          'batch_index': b,
          'row_index': r,
          'entity': entity,
          'id': row['id'],
          'revision': row['revision'],
          ...verdict(row, entity),
        });
      }
    }
    return results;
  }

  static http.Response acceptAll(Map<String, dynamic> body) => reply({
    'results': resultsFor(body, (_, _) => {'status': 'accepted'}),
    'server_time_ms': 1757800000000,
  });

  List<Map<String, dynamic>> rowsOf(int request) => [
    for (final batch in requests[request]['batches'] as List)
      for (final row in (batch as Map<String, dynamic>)['rows'] as List)
        row as Map<String, dynamic>,
  ];
}

/// Sales and drawers going up.
///
/// Every case guards the same silent failure: a sale that exists on one tablet
/// and nowhere else. The v1 client deleted a queued sale when the server
/// answered with a `[]` body or a 422; these are the tests plan.md asks for
/// first in Fase 4.
void main() {
  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<String> openSession() async => (await ShiftRepository.instance.open(
    employeeId: 'e1',
    employeeName: 'Siti',
    openingCash: 100000,
    posId: 'reg-1',
    posName: 'Kasir 1',
  )).id;

  Future<Order> sell(String sessionId) => OrderRepository.instance.create(
    type: OrderType.takeaway,
    items: const [
      OrderItemDraft(
        productId: 'p1',
        productName: 'Nasi Goreng',
        unitPrice: 15000,
        quantity: 2,
      ),
    ],
    subtotal: 30000,
    discount: 0,
    tax: 3000,
    total: 33000,
    amountPaid: 50000,
    paymentMethod: PaymentMethod.cash,
    cashierId: 'e1',
    cashierName: 'Siti',
    posId: 'reg-1',
    posName: 'Kasir 1',
    posSessionId: sessionId,
  );

  Future<List<(Object?, Object?, Object?, Object?)>> queue() async => [
    for (final r in await db.query(
      OutboxStore.table,
      orderBy: 'entity, entity_id',
    ))
      (r['entity'], r['entity_id'], r['revision'], r['payload']),
  ];

  OutboxPush pusher(
    _PushServer server, {
    int maxRequests = 50,
    int maxRows = 200,
  }) {
    final client = SyncClient(
      baseUrl: 'https://api.test/api/v2',
      token: 'tok',
      client: server.client,
    );
    addTearDown(client.close);
    return OutboxPush(client, maxRequests: maxRequests, maxRows: maxRows);
  }

  for (final (label, response) in [
    ('[]', () => http.Response('[]', 200)),
    ('"ok"', () => http.Response('"ok"', 200)),
    ('null', () => http.Response('null', 200)),
    ('empty 200', () => http.Response('', 200)),
    ('422', () => http.Response('{"error":{"code":"x","message":"y"}}', 422)),
    ('500', () => http.Response('{"error":{"code":"x","message":"y"}}', 500)),
  ]) {
    test(
      'a $label response leaves every queued sale and session intact',
      () async {
        final session = await openSession();
        await sell(session);
        await sell(session);
        final before = await queue();
        expect(before, hasLength(3));

        final server = _PushServer()..respond = (_) => response();
        final report = await pusher(server).run();

        expect(server.requests, hasLength(1));
        expect(await queue(), before);
        expect(await DeadLetterStore.instance.count(), 0);
        expect(await db.query('orders'), hasLength(2));
        expect(report.accepted, 0);
        expect(report.needsRetry, isTrue);
      },
    );
  }

  test('results that do not name the row remove nothing', () async {
    final session = await openSession();
    await sell(session);
    final before = await queue();

    final shapes = <_Verdict>[
      // An acceptance without the id and revision the real server echoes.
      (_, _) => {'status': 'accepted', 'id': null, 'revision': null},
      (row, _) => {
        'status': 'accepted',
        'revision': (row['revision'] as int) + 1,
      },
      (_, _) => {
        'status': 'accepted',
        'id': '00000000-0000-4000-8000-000000000000',
      },
      (_, _) => {'status': 'accepted', 'entity': 'somewhere_else'},
      (_, _) => {'status': 'ok'},
      (_, _) => {'status': 'rejected', 'code': 'a_code_nobody_defined'},
    ];

    for (final shape in shapes) {
      final server = _PushServer()
        ..respond = (body) =>
            _PushServer.reply({'results': _PushServer.resultsFor(body, shape)});
      await pusher(server).run();
      expect(await queue(), before);
    }

    // No results at all, or the same position answered twice.
    for (final respond in <http.Response Function(Map<String, dynamic>)>[
      (_) => _PushServer.reply({}),
      (_) => _PushServer.reply({'results': 'accepted'}),
      (body) {
        final accepted = _PushServer.resultsFor(
          body,
          (_, _) => {'status': 'accepted'},
        );
        return _PushServer.reply({
          'results': [...accepted, ...accepted],
        });
      },
    ]) {
      await pusher(_PushServer()..respond = respond).run();
      expect(await queue(), before);
    }
    expect(await DeadLetterStore.instance.count(), 0);
  });

  test('accepted removes a row only for the revision that was sent', () async {
    final session = await openSession();
    final order = await sell(session);

    final server = _PushServer();
    server.duringRequest = () async {
      // A manager voids the sale while its first push is on the wire.
      if (server.requests.length == 1) {
        await OrderRepository.instance.voidOrder(
          orderId: order.id,
          authorizedBy: 'Siwi',
          reason: 'Salah input',
        );
      }
    };

    await pusher(server, maxRequests: 1).run();

    // The drawer is settled. The sale's accepted revision was 1; the void is
    // revision 2 and must still be owed.
    final left = await OutboxStore.instance.pending();
    expect(left, hasLength(1));
    expect(left.single.entity, OrderPush.entity);
    expect(left.single.revision, 2);
    expect(jsonDecode(left.single.payload!)['status'], 'cancelled');

    await pusher(server).run();
    final second = server.rowsOf(1).single;
    expect(second['revision'], 2);
    expect(second['status'], 'cancelled');
    expect(await OutboxStore.instance.count(), 0);
  });

  test(
    'rejected moves the exact payload that was sent to dead letter',
    () async {
      final session = await openSession();
      final order = await sell(session);

      final server = _PushServer()
        ..respond = (body) => _PushServer.reply({
          'results': _PushServer.resultsFor(
            body,
            (_, entity) => entity == OrderPush.entity
                ? {
                    'status': 'rejected',
                    'code': 'schema_rejected',
                    'message': 'Header amounts do not reconcile.',
                  }
                : {'status': 'accepted'},
          ),
        });
      final report = await pusher(server).run();

      expect(report.accepted, 1);
      expect(report.rejected, 1);
      expect(await OutboxStore.instance.count(), 0);
      // The sale itself is untouched on the device.
      expect(await db.query('orders'), hasLength(1));

      final letter = (await DeadLetterStore.instance.all()).single;
      expect(letter.entity, OrderPush.entity);
      expect(letter.entityId, order.id);
      expect(letter.code, 'schema_rejected');
      expect(
        jsonDecode(letter.payload),
        server.rowsOf(0).firstWhere((r) => r['id'] == order.id),
      );
    },
  );

  test('a busy register keeps who holds the till', () async {
    await openSession();
    final server = _PushServer()
      ..respond = (body) => _PushServer.reply({
        'results': _PushServer.resultsFor(
          body,
          (_, _) => {
            'status': 'rejected',
            'code': 'register_busy',
            'holder_session_id': 'held-by',
            'holder_employee_name': 'Dani',
          },
        ),
      });
    await pusher(server).run();

    final letter = (await DeadLetterStore.instance.all()).single;
    expect(letter.entity, SessionPush.entity);
    expect(letter.details['holder_employee_name'], 'Dani');
  });

  test(
    'late sale is quarantined once and marks its drawer for recovery',
    () async {
      final session = await openSession();
      final order = await sell(session);
      await db.insert('_till_sessions', {
        'id': session,
        'state': 'active_confirmed',
        'employee_id': 'cashier-1',
        'receipt_next': 1,
        'receipt_end': 100,
      });
      const recovery = '00000000-0000-4000-8000-000000000099';
      final server = _PushServer()
        ..respond = (body) => _PushServer.reply({
          'results': _PushServer.resultsFor(
            body,
            (_, entity) => entity == OrderPush.entity
                ? {
                    'status': 'rejected',
                    'code': 'recovery_required',
                    'message': 'Manager review is required.',
                    'recovery_id': recovery,
                  }
                : {'status': 'accepted'},
          ),
        });

      await pusher(server).run();

      final letter = (await DeadLetterStore.instance.all()).single;
      expect(letter.entityId, order.id);
      expect(letter.recoveryId, recovery);
      expect(letter.details['recovery_id'], recovery);
      final till = (await db.query(
        '_till_sessions',
        where: 'id = ?',
        whereArgs: [session],
      )).single;
      expect(till['state'], 'recovery_required');
      expect(till['recovery_id'], recovery);
    },
  );

  test(
    'incompatible refusal cannot be requeued by the recovery action',
    () async {
      final session = await openSession();
      await sell(session);
      final orderEntry = (await OutboxStore.instance.pending(
        entity: OrderPush.entity,
      )).single;
      await DeadLetterStore.instance.moveFromOutbox(
        orderEntry,
        code: 'schema_rejected',
      );

      final letter = (await DeadLetterStore.instance.all()).single;
      expect(await DeadLetterStore.instance.requeue(letter.id), isFalse);
      expect(await DeadLetterStore.instance.count(), 1);
      expect(
        await OutboxStore.instance.pending(entity: OrderPush.entity),
        isEmpty,
      );
    },
  );

  test('retry keeps the row and records why', () async {
    final session = await openSession();
    await sell(session);
    final server = _PushServer()
      ..respond = (body) => _PushServer.reply({
        'results': _PushServer.resultsFor(
          body,
          (_, _) => {'status': 'retry', 'code': 'dependency_pending'},
        ),
      });

    final report = await pusher(server).run();

    expect(report.remaining, 2);
    final left = await OutboxStore.instance.pending();
    expect(left.map((e) => e.attempts), everyElement(1));
    expect(left.map((e) => e.lastError), everyElement('dependency_pending'));
    expect(await DeadLetterStore.instance.count(), 0);
  });

  test(
    'rows go up batched, the session first, never more than 200 a request',
    () async {
      final session = await openSession();
      for (var i = 0; i < 205; i++) {
        await sell(session);
      }

      final server = _PushServer();
      final report = await pusher(server).run();

      expect(server.requests, hasLength(2));
      final first = server.requests[0]['batches'] as List;
      expect(first.first['entity'], SessionPush.entity);
      expect((first.first['rows'] as List), hasLength(1));
      expect(first.last['entity'], OrderPush.entity);
      for (var i = 0; i < server.requests.length; i++) {
        expect(server.rowsOf(i).length, lessThanOrEqualTo(200));
      }
      expect(server.rowsOf(0).length + server.rowsOf(1).length, 206);
      expect(report.accepted, 206);
      expect(await OutboxStore.instance.count(), 0);
    },
  );

  test('a retry after a failed request sends identical bytes', () async {
    final session = await openSession();
    await sell(session);

    final server = _PushServer();
    server.respond = (body) => server.requests.length == 1
        ? http.Response('{"error":{"code":"x","message":"y"}}', 503)
        : _PushServer.acceptAll(body);

    await pusher(server).run();
    await pusher(server).run();

    expect(server.rawBodies, hasLength(2));
    expect(server.rawBodies[1], server.rawBodies[0]);
    expect(await OutboxStore.instance.count(), 0);
  });

  test('a revoked token stops the run and keeps everything', () async {
    final session = await openSession();
    await sell(session);
    final before = await queue();

    final server = _PushServer()
      ..respond = (_) => http.Response('{"error":{"code":"x"}}', 401);

    await expectLater(
      pusher(server).run(),
      throwsA(
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.unauthorized,
        ),
      ),
    );
    expect(await queue(), before);
  });

  test(
    'an entry a v24 build queued is snapshotted before its first push',
    () async {
      final session = await openSession();
      final order = await sell(session);
      await db.update(OutboxStore.table, {'revision': null, 'payload': null});
      await db.update(
        'orders',
        {'business_date': null},
        where: 'id = ?',
        whereArgs: [order.id],
      );

      final server = _PushServer();
      await pusher(server).run();

      final rows = server.rowsOf(0);
      expect(rows, hasLength(2));
      expect(rows.map((r) => r['revision']), everyElement(isA<int>()));
      final sent = rows.firstWhere((r) => r['id'] == order.id);
      expect(sent['business_date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(await OutboxStore.instance.count(), 0);
    },
  );
}
