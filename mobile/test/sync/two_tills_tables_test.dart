import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/device_registration.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/table_repository.dart';
import 'package:nti_pos/data/sync/device_sync_runner.dart';
import 'package:nti_pos/data/sync/outbox_store.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:nti_pos/data/sync/table_status_push.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _outlet = '11111111-1111-4111-8111-111111111111';
const _table = '44444444-4444-4444-8444-444444444444';

/// A server with the floor plan's semantics (backend-go
/// internal/domain/tables): an event made against the current status
/// sequence, or following the same device's own latest write, applies; one
/// that raced another till is applied or superseded by time and marks the
/// table contested. Exact retries answer with what was first recorded.
class _FloorServer {
  String status = 'available';
  int statusSeq = 1;
  int? appliedAtMs;
  String? appliedEvent;
  String? appliedDevice;
  bool contested = false;
  final answers = <String, Map<String, Object?>>{};
  final lastClientSeq = <String, int>{};

  http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

  http.Client get client => MockClient((request) async {
    final device = request.headers['Authorization'] ?? '';
    switch (request.url.path) {
      case '/api/v2/sync/manifest':
        return _json({
          'schema_version': 1,
          'entities': [
            {
              'name': 'tables',
              'scope': 'outlet',
              'key': ['id'],
              'depends_on': <String>[],
              'pull': true,
              'push': false,
              'apply': 'upsert',
            },
            {
              'name': 'table_status',
              'scope': 'outlet',
              'key': ['table_id'],
              'depends_on': ['tables'],
              'pull': true,
              'push': false,
              'apply': 'upsert',
            },
            {
              'name': 'table_status_events',
              'scope': 'outlet',
              'key': ['id'],
              'depends_on': ['table_status'],
              'pull': false,
              'push': true,
              'apply': 'upsert',
            },
          ],
        });
      case '/api/v2/sync/pull':
        final entity = request.url.queryParameters['entity']!;
        final after = int.parse(request.url.queryParameters['after_seq']!);
        if (entity == 'tables') {
          return _json({
            'entity': entity,
            'rows': [
              if (after < 1)
                {
                  'id': _table,
                  'outlet_id': _outlet,
                  'name': 'Meja 1',
                  'area': 'Lantai 1',
                  'capacity': 4,
                  'pos_x': null,
                  'pos_y': null,
                  'sort_order': 0,
                  'active': true,
                  'sync_seq': 1,
                  'deleted_at_ms': null,
                },
            ],
            'next_seq': 1,
            'has_more': false,
            'schema_version': 1,
          });
        }
        return _json({
          'entity': entity,
          'rows': [
            if (statusSeq > after)
              {
                'table_id': _table,
                'outlet_id': _outlet,
                'status': status,
                'occurred_at_ms': appliedAtMs ?? 0,
                'employee_name': '',
                'contested': contested,
                'sync_seq': statusSeq,
                'deleted_at_ms': null,
              },
          ],
          'next_seq': statusSeq > after ? statusSeq : after,
          'has_more': false,
          'schema_version': 1,
        });
      case '/api/v2/sync/push':
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final results = <Map<String, Object?>>[];
        final batches = body['batches'] as List;
        for (var b = 0; b < batches.length; b++) {
          final batch = batches[b] as Map<String, dynamic>;
          final rows = batch['rows'] as List;
          for (var r = 0; r < rows.length; r++) {
            final row = rows[r] as Map<String, dynamic>;
            results.add({
              'batch_index': b,
              'row_index': r,
              'entity': batch['entity'],
              'id': row['id'],
              'revision': row['revision'],
              'status': 'accepted',
              ..._apply(row, device),
            });
          }
        }
        return _json({'results': results, 'server_time_ms': 1757800000000});
    }
    return http.Response('{"error":{"code":"not_found"}}', 404);
  });

  Map<String, Object?> _apply(Map<String, dynamic> row, String device) {
    final id = row['id'] as String;
    final seen = answers[id];
    if (seen != null) return seen;

    final basis = row['basis_seq'] as int;
    final at = row['occurred_at_ms'] as int;
    final clientSeq = row['client_seq'] as int;
    var outcome = 'applied';
    var mark = false;
    if (clientSeq <= (lastClientSeq[device] ?? 0)) {
      outcome = 'superseded';
      mark = contested;
    } else if (basis == statusSeq || appliedEvent == null) {
      // Made against what the table shows, or nothing to race.
    } else if (appliedDevice == device) {
      mark = contested;
    } else {
      mark = true;
      final later =
          at > appliedAtMs! ||
          (at == appliedAtMs && id.compareTo(appliedEvent!) > 0);
      if (!later) outcome = 'superseded';
    }

    statusSeq++;
    if (outcome == 'applied') {
      status = row['status'] as String;
      appliedAtMs = at;
      appliedEvent = id;
      appliedDevice = device;
      contested = mark;
    } else {
      contested = mark;
    }
    if (clientSeq > (lastClientSeq[device] ?? 0))
      lastClientSeq[device] = clientSeq;
    return answers[id] = {'status_seq': statusSeq, 'outcome': outcome};
  }
}

class _Till {
  _Till(this.name, this.path, this.registerId);
  final String name;
  final String path;
  final String registerId;

  TillBinding get binding =>
      TillBinding(outletId: _outlet, registerId: registerId);
}

/// The Fase 6 gate, on the client side: two tills in one branch change the
/// same table offline and both end up showing the same answer, contested,
/// until someone acts on what the table now says.
void main() {
  late Directory dir;
  late _FloorServer server;
  late _Till tillA;
  late _Till tillB;

  setUpAll(initFfi);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('two_tills_tables_');
    server = _FloorServer();
    tillA = _Till(
      'a',
      '${dir.path}/a.db',
      '66666666-6666-4666-8666-666666666666',
    );
    tillB = _Till(
      'b',
      '${dir.path}/b.db',
      '77777777-7777-4777-8777-777777777777',
    );
  });

  // sqflite hands back the SAME connection for a path that is already open,
  // so switching to the till already in use must not reopen it.
  _Till? current;
  Database? open;

  tearDown(() async {
    TillBinding.configure(null);
    if (open != null && open!.isOpen) await open!.close();
    open = null;
    current = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> use(_Till till) async {
    TillBinding.configure(till.binding);
    if (identical(current, till) && open != null && open!.isOpen) return;
    if (open != null && open!.isOpen) await open!.close();
    open = await AppDatabase.openForTest(path: till.path, seed: false);
    await AppDatabase.instance.useTestDb(open!);
    current = till;
  }

  Future<void> sync(_Till till) async {
    await use(till);
    final client = SyncClient(
      baseUrl: 'https://api.test/api/v2',
      token: 'tok-${till.name}',
      client: server.client,
    );
    final runner = DeviceSyncRunner(
      binding: DeviceRegistration(
        baseUrl: 'https://api.test/api/v2',
        token: 'tok-${till.name}',
        expiresAt: DateTime.utc(2030),
        device: {'id': 'device-${till.name}'},
        tenant: {'id': 'tenant', 'name': 'Warung'},
        outlet: {'id': _outlet, 'name': 'Kemang'},
        register: {
          'id': till.registerId,
          'outlet_id': _outlet,
          'name': 'Kasir ${till.name}',
          'table_service': true,
        },
      ),
      client: client,
    );
    await runner.syncNow(full: true);
    runner.close();
  }

  Future<Map<String, Object?>> tableAt(_Till till) async {
    await use(till);
    final db = await AppDatabase.instance.db;
    return (await db.query(
      'tables',
      where: 'id = ?',
      whereArgs: [_table],
    )).single;
  }

  Future<void> change(_Till till, TableStatus status) async {
    await use(till);
    await TableRepository.instance.setStatus(
      _table,
      status,
      employeeName: 'Kasir ${till.name}',
    );
  }

  Future<void> expectBoth(String status, {required bool contested}) async {
    for (final till in [tillA, tillB]) {
      final row = await tableAt(till);
      expect(row['status'], status, reason: 'till ${till.name}');
      expect(row['contested'], contested ? 1 : 0, reason: 'till ${till.name}');
      expect(
        await OutboxStore.instance.pending(entity: TableStatusPush.entity),
        isEmpty,
        reason: 'till ${till.name}',
      );
    }
  }

  test(
    'two tills racing on one table show the same contested answer',
    () async {
      await sync(tillA);
      await sync(tillB);
      expect((await tableAt(tillA))['status'], 'available');
      expect((await tableAt(tillA))['floor'], 'Lantai 1');

      // Offline, A seats a guest; a moment later B reserves the same table.
      await change(tillA, TableStatus.occupied);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await change(tillB, TableStatus.reserved);

      await sync(tillA);
      expect(server.status, 'occupied');
      expect((await tableAt(tillA))['status'], 'occupied');

      await sync(tillB);
      expect(server.status, 'reserved', reason: 'B changed it later');
      expect(server.contested, isTrue);

      await sync(tillA);
      await sync(tillB);
      await expectBoth('reserved', contested: true);

      // Staff look at the table; A clears it against what it now shows.
      await change(tillA, TableStatus.available);
      await sync(tillA);
      await sync(tillB);
      await expectBoth('available', contested: false);
      expect(server.contested, isFalse);
    },
  );

  test(
    'a till whose change lost shows the winner once it hears back',
    () async {
      await sync(tillA);
      await sync(tillB);

      // B's change is made first but reaches the server last.
      await change(tillB, TableStatus.reserved);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await change(tillA, TableStatus.occupied);

      await sync(tillA);
      await sync(tillB);
      expect(server.status, 'occupied');
      expect(
        (await tableAt(tillB))['status'],
        'occupied',
        reason: 'the superseded answer stops B showing its own change',
      );

      await sync(tillA);
      await sync(tillB);
      await expectBoth('occupied', contested: true);
    },
  );
}
