import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/device/till_binding.dart';
import 'package:nti_pos/data/repositories/promo_repository.dart';
import 'package:nti_pos/data/sync/catalogue_sync.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

const _outletA = '11111111-1111-4111-8111-111111111111';
const _outletB = '11111111-1111-4111-8111-222222222222';
const _register = '22222222-2222-4222-8222-222222222222';

const _keys = {
  'product_modifier_groups': ['product_id', 'group_id'],
  'product_modifier_options': ['product_id', 'option_id'],
  'promo_outlets': ['promo_id', 'outlet_id'],
  'table_status': ['table_id'],
};

/// Serves each feed in insertion (manifest) order, one page, every row above
/// the requested cursor.
class _Feeds {
  final feeds = <String, List<Map<String, Object?>>>{};

  void add(String entity, Map<String, Object?> row) =>
      feeds.putIfAbsent(entity, () => []).add(row);

  http.Client get client => MockClient((request) async {
    if (request.url.path == '/api/v2/sync/manifest') {
      return http.Response(
        jsonEncode({
          'schema_version': 1,
          'entities': [
            for (final name in feeds.keys)
              {
                'name': name,
                'scope': 'company',
                'key': _keys[name] ?? ['id'],
                'depends_on': <String>[],
                'pull': true,
                'push': false,
                'apply': 'upsert',
              },
          ],
        }),
        200,
      );
    }
    final entity = request.url.queryParameters['entity']!;
    final after = int.parse(request.url.queryParameters['after_seq']!);
    final rows = [
      for (final r in feeds[entity] ?? const <Map<String, Object?>>[])
        if ((r['sync_seq'] as int) > after) r,
    ];
    final next = rows.fold<int>(
      after,
      (m, r) => (r['sync_seq'] as int) > m ? r['sync_seq'] as int : m,
    );
    return http.Response(
      jsonEncode({
        'entity': entity,
        'rows': rows,
        'next_seq': next,
        'has_more': false,
        'schema_version': 1,
      }),
      200,
    );
  });
}

Map<String, Object?> _row(int seq, Map<String, Object?> fields) => {
  ...fields,
  'sync_seq': seq,
  'deleted_at_ms': null,
};

Map<String, Object?> _tombstone(int seq, Map<String, Object?> key) => {
  ...key,
  'sync_seq': seq,
  'deleted_at_ms': 1757800000000,
};

/// Fase 6 on the pull side: the modifier, promo and floor-plan feeds reach an
/// activated till whole, and a promo narrowed to other branches stays out of
/// this one.
void main() {
  late Database db;
  late _Feeds server;
  late SyncClient client;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
    TillBinding.configure(
      const TillBinding(outletId: _outletA, registerId: _register),
    );
    server = _Feeds();
    client = SyncClient(
      baseUrl: 'https://api.test/api/v2',
      token: 'tok',
      client: server.client,
    );
  });

  tearDown(() async {
    client.close();
    TillBinding.configure(null);
    if (db.isOpen) await db.close();
  });

  Future<void> pull() => CatalogueSync(client).run();

  test(
    'modifiers arrive whole: groups, options and each product\'s scope',
    () async {
      server
        ..add('categories', _row(1, {'id': 'c1', 'name': 'Minuman'}))
        ..add(
          'products',
          _row(1, {
            'id': 'p1',
            'category_id': 'c1',
            'name': 'Kopi Susu',
            'price': 18000,
          }),
        )
        ..add(
          'modifier_groups',
          _row(1, {
            'id': 'g1',
            'name': 'Gula',
            'selection_type': 'single',
            'required': true,
            'max_select': null,
            'sort_order': 0,
            'active': true,
          }),
        )
        ..add(
          'modifier_options',
          _row(1, {
            'id': 'o1',
            'group_id': 'g1',
            'name': 'Normal',
            'price_delta': 0,
            'sort_order': 0,
            'active': true,
          }),
        )
        ..add(
          'modifier_options',
          _row(2, {
            'id': 'o2',
            'group_id': 'g1',
            'name': 'Extra',
            'price_delta': 2000,
            'sort_order': 1,
            'active': true,
          }),
        )
        ..add(
          'product_modifier_groups',
          _row(1, {'product_id': 'p1', 'group_id': 'g1'}),
        )
        ..add(
          'product_modifier_options',
          _row(1, {'product_id': 'p1', 'option_id': 'o1', 'is_default': true}),
        )
        ..add(
          'product_modifier_options',
          _row(2, {'product_id': 'p1', 'option_id': 'o2', 'is_default': false}),
        );

      await pull();

      final group = (await db.query('modifier_groups')).single;
      expect(group['required'], 1);
      expect(group['max_select'], isNull);
      expect(await db.query('modifier_options'), hasLength(2));
      expect(await db.query('product_modifier_groups'), hasLength(1));
      final scope = await db.query(
        'product_modifier_options',
        orderBy: 'option_id',
      );
      expect([for (final r in scope) r['is_default']], [1, 0]);

      // An option retired upstream takes its scoping with it; the others stay.
      server.add('modifier_options', _tombstone(3, {'id': 'o2'}));
      await pull();
      expect(await db.query('modifier_options'), hasLength(1));
      expect(
        [for (final r in await db.query('product_modifier_options')) r['option_id']],
        ['o1'],
      );
    },
  );

  test('a promo narrowed to other branches is not offered here', () async {
    Map<String, Object?> promo(String id, String name, bool all) => {
      'id': id,
      'name': name,
      'kind': 'percent',
      'value': 10,
      'min_spend': 0,
      'active': true,
      'sort_order': 0,
      'all_outlets': all,
    };
    server
      ..add('outlets', _row(1, {'id': _outletA, 'name': 'Kemang'}))
      ..add('outlets', _row(2, {'id': _outletB, 'name': 'Bintaro'}))
      ..add('promos', _row(1, promo('p1', 'A Semua', true)))
      ..add('promos', _row(2, promo('p2', 'B Kemang', false)))
      ..add('promos', _row(3, promo('p3', 'C Bintaro', false)))
      ..add('promos', _row(4, promo('p4', 'D Nowhere', false)))
      ..add('promo_outlets', _row(1, {'promo_id': 'p2', 'outlet_id': _outletA}))
      ..add('promo_outlets', _row(2, {'promo_id': 'p3', 'outlet_id': _outletB}));

    await pull();

    Future<List<String>> offered(String outlet) async => [
      for (final p in await PromoRepository.instance.all(
        onlyActive: true,
        outletId: outlet,
      ))
        p.name,
    ];
    expect(await offered(_outletA), ['A Semua', 'B Kemang']);
    expect(await offered(_outletB), ['A Semua', 'C Bintaro']);

    // The owner takes Kemang out of the promo: a tombstone on the scope row.
    server.add(
      'promo_outlets',
      _tombstone(3, {'promo_id': 'p2', 'outlet_id': _outletA}),
    );
    await pull();
    expect(await offered(_outletA), ['A Semua']);

    // A deleted promo takes its scope rows with it.
    server.add('promos', _tombstone(5, {'id': 'p3'}));
    await pull();
    expect(await db.query('promo_outlets'), isEmpty);
  });

  test(
    'a table arrives with its area as the floor, and its status lands on it',
    () async {
      const table = '44444444-4444-4444-8444-444444444444';
      server
        ..add('outlets', _row(1, {'id': _outletA, 'name': 'Kemang'}))
        ..add(
          'tables',
          _row(1, {
            'id': table,
            'outlet_id': _outletA,
            'name': 'Meja 1',
            'area': 'Teras',
            'capacity': 4,
            'pos_x': 3,
            'pos_y': null,
            'sort_order': 1,
            'active': true,
          }),
        )
        ..add(
          'table_status',
          _row(7, {
            'table_id': table,
            'outlet_id': _outletA,
            'status': 'occupied',
            'occurred_at_ms': 1757800000000,
            'employee_name': 'Siti',
            'contested': true,
          }),
        );

      await pull();

      final row = (await db.query('tables')).single;
      expect(row['floor'], 'Teras');
      expect(row['capacity'], 4);
      expect(row['status'], 'occupied');
      expect(row['server_status'], 'occupied');
      expect(row['server_seq'], 7);
      expect(row['contested'], 1);

      // A rename keeps the status the table already has.
      server.add(
        'tables',
        _row(2, {
          'id': table,
          'outlet_id': _outletA,
          'name': 'Meja Teras',
          'area': 'Teras',
          'capacity': 4,
          'sort_order': 1,
          'active': true,
        }),
      );
      await pull();
      final renamed = (await db.query('tables')).single;
      expect(renamed['name'], 'Meja Teras');
      expect(renamed['status'], 'occupied');

      // Deleted upstream: both tombstones arrive, and the table is gone.
      server
        ..add('tables', _tombstone(3, {'id': table}))
        ..add('table_status', _tombstone(8, {'table_id': table}));
      await pull();
      expect(await db.query('tables'), isEmpty);
    },
  );
}
