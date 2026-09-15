import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/sync/catalogue_sync.dart';
import 'package:nti_pos/data/sync/sync_client.dart';
import 'package:nti_pos/data/sync/sync_state_store.dart';
import 'package:nti_pos/core/router/app_router.dart';
import 'package:nti_pos/providers/cart_provider.dart';
import 'package:nti_pos/providers/catalog_provider.dart';
import 'package:nti_pos/providers/employee_provider.dart';
import 'package:nti_pos/providers/settings_provider.dart';
import 'package:nti_pos/providers/outlet_provider.dart';
import 'package:nti_pos/providers/synced_data.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

/// A fake server that answers the two v2 pull endpoints from canned pages.
///
/// Preferred over mocking the repository: what is worth testing here is the
/// paging and transaction behaviour against a real SQLite, and a fake at the
/// HTTP boundary leaves all of that in the test's path.
class _FakeServer {
  _FakeServer(this.pages);

  /// entity -> list of pages, each `{rows, next_seq, has_more}`. Manifest
  /// order follows the map's insertion order.
  final Map<String, List<Map<String, dynamic>>> pages;
  final List<Uri> requests = [];
  int? forcedStatus;

  /// Extra manifest entries, for feeds this build must not pull.
  List<Map<String, dynamic>> extraManifest = [];

  static Map<String, dynamic> manifestEntry(
    String name, {
    bool pull = true,
    String apply = 'upsert',
  }) => {
    'name': name,
    'scope': 'company',
    'key': ['id'],
    'depends_on': <String>[],
    'pull': pull,
    'push': false,
    'apply': apply,
  };

  http.Client get client => MockClient((request) async {
    requests.add(request.url);

    if (forcedStatus != null) {
      return http.Response('{}', forcedStatus!);
    }

    expect(request.headers['X-Schema-Version'], '$kClientSchemaVersion');

    if (request.url.path == '/api/v2/sync/manifest') {
      return http.Response(
        jsonEncode({
          'schema_version': 1,
          'entities': [
            for (final name in pages.keys) manifestEntry(name),
            ...extraManifest,
          ],
        }),
        200,
      );
    }

    if (request.url.path != '/api/v2/sync/pull') {
      return http.Response('{}', 404);
    }
    final entity = request.url.queryParameters['entity']!;
    final after = int.parse(request.url.queryParameters['after_seq'] ?? '0');
    final entityPages = pages[entity] ?? const [];

    // Serve the first page whose contents sit above the requested cursor,
    // exactly as the real endpoint does.
    for (final page in entityPages) {
      if ((page['next_seq'] as int) > after) {
        return http.Response(
          jsonEncode({'entity': entity, 'schema_version': 1, ...page}),
          200,
        );
      }
    }

    return http.Response(
      jsonEncode({
        'entity': entity,
        'rows': [],
        'next_seq': after,
        'has_more': false,
        'schema_version': 1,
      }),
      200,
    );
  });
}

Map<String, dynamic> _category(String id, String name, int seq) => {
  'id': id,
  'name': name,
  'icon_key': 'set_meal',
  'sort_order': 0,
  'is_popular': false,
  'sync_seq': seq,
  'deleted_at_ms': null,
};

Map<String, dynamic> _product(
  String id,
  String categoryId,
  String name,
  int seq, {
  int price = 15000,
  int? deletedAtMs,
}) => {
  'id': id,
  'category_id': categoryId,
  'name': name,
  'price': price,
  'cost': null,
  'sku': null,
  'tax_rate': null,
  'description': null,
  'image_url': null,
  'icon_key': 'restaurant',
  'available': true,
  'is_popular': false,
  'sort_order': 0,
  'sync_seq': seq,
  'deleted_at_ms': deletedAtMs,
};

void main() {
  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<SyncReport> sync(
    _FakeServer server, {
    int pageLimit = 200,
    Map<String, int>? hints,
  }) {
    final client = SyncClient(
      // Same API root as DeviceActivationRepository and the persisted binding.
      baseUrl: 'https://api.test/api/v2/',
      token: 'tok',
      client: server.client,
    );
    addTearDown(client.close);
    final s = CatalogueSync(client);
    return s.run(pageLimit: pageLimit, hints: hints);
  }

  test('pulls a catalogue into an empty device', () async {
    final server = _FakeServer({
      'categories': [
        {
          'rows': [_category('c1', 'Makanan', 1)],
          'next_seq': 1,
          'has_more': false,
        },
      ],
      'products': [
        {
          'rows': [_product('p1', 'c1', 'Nasi Goreng', 2)],
          'next_seq': 2,
          'has_more': false,
        },
      ],
    });

    final report = await sync(server);

    final products = await db.query('products');
    expect(report.totalApplied, 2);
    expect(products, hasLength(1));
    expect(products.first['name'], 'Nasi Goreng');
    expect(products.first['price'], 15000);
  });

  test('applies categories before products so the foreign key holds', () async {
    // Manifest order is what must win. Without it the product insert fails
    // with SQLite error 787.
    final server = _FakeServer({
      'categories': [
        {
          'rows': [_category('c1', 'Makanan', 5)],
          'next_seq': 5,
          'has_more': false,
        },
      ],
      'products': [
        {
          'rows': [_product('p1', 'c1', 'Nasi Goreng', 6)],
          'next_seq': 6,
          'has_more': false,
        },
      ],
    });

    await sync(server);

    expect(await db.query('products'), hasLength(1));
  });

  test('remembers the cursor so a second run pulls nothing', () async {
    final server = _FakeServer({
      'categories': [
        {
          'rows': [_category('c1', 'Makanan', 1)],
          'next_seq': 1,
          'has_more': false,
        },
      ],
      'products': [
        {
          'rows': [_product('p1', 'c1', 'Nasi Goreng', 2)],
          'next_seq': 2,
          'has_more': false,
        },
      ],
    });

    await sync(server);
    final second = await sync(server);

    expect(second.totalApplied, 0);
    expect(await SyncStateStore.instance.lastSeq('products'), 2);
  });

  test('pages through a long tail without losing a row', () async {
    final server = _FakeServer({
      'categories': [
        {
          'rows': [_category('c1', 'Makanan', 1)],
          'next_seq': 1,
          'has_more': false,
        },
      ],
      'products': [
        {
          'rows': [_product('p1', 'c1', 'A', 2), _product('p2', 'c1', 'B', 3)],
          'next_seq': 3,
          'has_more': true,
        },
        {
          'rows': [_product('p3', 'c1', 'C', 4)],
          'next_seq': 4,
          'has_more': false,
        },
      ],
    });

    await sync(server, pageLimit: 2);

    expect(await db.query('products'), hasLength(3));
    expect(await SyncStateStore.instance.lastSeq('products'), 4);
  });

  test('applies a tombstone by deleting the row', () async {
    final server = _FakeServer({
      'categories': [
        {
          'rows': [_category('c1', 'Makanan', 1)],
          'next_seq': 1,
          'has_more': false,
        },
      ],
      'products': [
        {
          'rows': [_product('p1', 'c1', 'Nasi Goreng', 2)],
          'next_seq': 2,
          'has_more': false,
        },
        {
          'rows': [
            _product('p1', 'c1', 'Nasi Goreng', 3, deletedAtMs: 1757325600000),
          ],
          'next_seq': 3,
          'has_more': false,
        },
      ],
    });

    await sync(server);
    expect(await db.query('products'), hasLength(1));

    final second = await sync(server);

    expect(second.totalDeleted, 1);
    expect(await db.query('products'), isEmpty);
  });

  test('overwrites a changed row rather than duplicating it', () async {
    final server = _FakeServer({
      'categories': [
        {
          'rows': [_category('c1', 'Makanan', 1)],
          'next_seq': 1,
          'has_more': false,
        },
      ],
      'products': [
        {
          'rows': [_product('p1', 'c1', 'Nasi Goreng', 2)],
          'next_seq': 2,
          'has_more': false,
        },
        {
          'rows': [_product('p1', 'c1', 'Nasi Goreng', 3, price: 18000)],
          'next_seq': 3,
          'has_more': false,
        },
      ],
    });

    await sync(server);
    await sync(server);

    final rows = await db.query('products');
    expect(rows, hasLength(1));
    expect(rows.first['price'], 18000);
  });

  test('ignores keys the local schema does not have', () async {
    // A column the server adds tomorrow must not be a SQLite error that stops
    // the whole page today.
    final server = _FakeServer({
      'categories': [
        {
          'rows': [
            {
              ..._category('c1', 'Makanan', 1),
              'colour_hex': '#ff0000',
              'nested': {'anything': true},
            },
          ],
          'next_seq': 1,
          'has_more': false,
        },
      ],
    });

    await sync(server);

    expect((await db.query('categories')).single['name'], 'Makanan');
  });

  test('does not pull feeds this build cannot store yet', () async {
    // Future entities, push-only feeds and unsafe replace semantics stay out.
    // Promos/modifiers now have full coverage in promo_modifier_table_pull_test.
    final server =
        _FakeServer({
            'categories': [
              {
                'rows': [_category('c1', 'Makanan', 1)],
                'next_seq': 1,
                'has_more': false,
              },
            ],
          })
          ..extraManifest = [
            _FakeServer.manifestEntry('future_entity'),
            _FakeServer.manifestEntry('orders', pull: false),
            _FakeServer.manifestEntry('products', apply: 'replace'),
          ];

    await sync(server);

    final pulled = {
      for (final uri in server.requests)
        if (uri.path == '/api/v2/sync/pull') uri.queryParameters['entity'],
    };
    expect(pulled, {'categories'});
  });

  test('change hints skip feeds whose cursor has not moved', () async {
    final server = _FakeServer({
      'categories': [
        {
          'rows': [_category('c1', 'Makanan', 1)],
          'next_seq': 1,
          'has_more': false,
        },
      ],
      'products': [
        {
          'rows': [_product('p1', 'c1', 'Nasi Goreng', 2)],
          'next_seq': 2,
          'has_more': false,
        },
      ],
    });
    await sync(server);
    server.requests.clear();

    // Nothing moved: not even the manifest is requested.
    await sync(server, hints: {'categories': 1, 'products': 2});
    expect(server.requests, isEmpty);

    // Only products moved.
    server.pages['products'] = [
      {
        'rows': [_product('p1', 'c1', 'Nasi Goreng', 3, price: 17000)],
        'next_seq': 3,
        'has_more': false,
      },
    ];
    await sync(server, hints: {'categories': 1, 'products': 3});
    final pulled = [
      for (final uri in server.requests)
        if (uri.path == '/api/v2/sync/pull') uri.queryParameters['entity'],
    ];
    expect(pulled, ['products']);
    expect((await db.query('products')).single['price'], 17000);
  });

  test('a page that is not the contract shape moves no cursor', () async {
    final server = _FakeServer({
      'categories': [
        {'rows': 'not a list', 'next_seq': 9, 'has_more': false},
      ],
    });

    await expectLater(
      sync(server),
      throwsA(
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.malformed,
        ),
      ),
    );
    expect(await SyncStateStore.instance.lastSeq('categories'), 0);
  });

  test(
    'category and product deltas preserve unchanged children and local stock',
    () async {
      final server = _FakeServer({
        'categories': [
          {
            'rows': [_category('c1', 'Makanan', 1)],
            'next_seq': 1,
            'has_more': false,
          },
        ],
        'products': [
          {
            'rows': [_product('p1', 'c1', 'Nasi', 2)],
            'next_seq': 2,
            'has_more': false,
          },
        ],
        'product_variants': [
          {
            'rows': [
              {
                'id': 'v1',
                'product_id': 'p1',
                'name': 'Besar',
                'price_delta': 2000,
                'sort_order': 0,
                'sync_seq': 3,
                'deleted_at_ms': null,
              },
            ],
            'next_seq': 3,
            'has_more': false,
          },
        ],
      });
      await sync(server);
      await db.update(
        'products',
        {'stock': 7},
        where: 'id = ?',
        whereArgs: ['p1'],
      );

      server.pages['categories'] = [
        {
          'rows': [_category('c1', 'Menu baru', 4)],
          'next_seq': 4,
          'has_more': false,
        },
      ];
      await sync(server);
      expect(await db.query('products'), hasLength(1));
      expect(await db.query('product_variants'), hasLength(1));

      server.pages['products'] = [
        {
          'rows': [_product('p1', 'c1', 'Nasi baru', 5, price: 18000)],
          'next_seq': 5,
          'has_more': false,
        },
      ];
      await sync(server);
      expect((await db.query('products')).single['price'], 18000);
      expect((await db.query('products')).single['stock'], 7);
      expect(await db.query('product_variants'), hasLength(1));
      expect(await SyncStateStore.instance.lastSeq('product_variants'), 3);
    },
  );

  test(
    'refreshes mounted catalogue caches without resetting cart or session',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final settings = await container.read(settingsProvider.future);
      container.listen(activeOutletProvider, (_, _) {});
      await container.read(activeOutletProvider.future);
      container.listen(productsProvider, (_, _) {});
      container.listen(categoriesProvider, (_, _) {});
      container.listen(productVariantsProvider, (_, _) {});
      container.listen(employeesProvider, (_, _) {});
      expect(await container.read(productsProvider.future), isEmpty);
      expect(await container.read(categoriesProvider.future), isEmpty);
      expect(await container.read(productVariantsProvider.future), isEmpty);
      expect(await container.read(employeesProvider.future), isEmpty);
      final router = container.read(routerProvider);

      final server = _FakeServer({
        'employees': [
          {
            'rows': [
              {
                'id': 'e1',
                'name': 'Kasir',
                'pin_hash': null,
                'role': 'cashier',
                'active': true,
                'sort_order': 0,
                'sync_seq': 1,
                'deleted_at_ms': null,
              },
            ],
            'next_seq': 1,
            'has_more': false,
          },
        ],
        'categories': [
          {
            'rows': [_category('c1', 'Minuman', 2)],
            'next_seq': 2,
            'has_more': false,
          },
        ],
        'products': [
          {
            'rows': [_product('p1', 'c1', 'Es Teh', 3)],
            'next_seq': 3,
            'has_more': false,
          },
        ],
        'product_variants': [
          {
            'rows': [
              {
                'id': 'v1',
                'product_id': 'p1',
                'name': 'Besar',
                'price_delta': 2000,
                'sort_order': 0,
                'sync_seq': 4,
                'deleted_at_ms': null,
              },
            ],
            'next_seq': 4,
            'has_more': false,
          },
        ],
      });
      await sync(server);
      // SQLite changed while the page was still mounted: its cache is stale.
      expect(await container.read(productsProvider.future), isEmpty);
      invalidateSyncedData(container);
      final product = (await container.read(productsProvider.future)).single;
      expect(product.name, 'Es Teh');
      expect(
        (await container.read(categoriesProvider.future)).single.name,
        'Minuman',
      );
      expect(
        (await container.read(employeesProvider.future)).single.name,
        'Kasir',
      );
      expect(
        (await container.read(
          productVariantsProvider.future,
        ))['p1']!.single.name,
        'Besar',
      );
      container.read(cartProvider.notifier).add(product);
      final cart = container.read(cartProvider);

      server.pages['products'] = [
        {
          'rows': [_product('p1', 'c1', 'Es Teh Baru', 5, price: 19000)],
          'next_seq': 5,
          'has_more': false,
        },
      ];
      await sync(server);
      invalidateSyncedData(container);
      expect(
        (await container.read(productsProvider.future)).single.price,
        19000,
      );
      expect(container.read(cartProvider), same(cart));
      expect(container.read(routerProvider), same(router));
      expect(await container.read(settingsProvider.future), same(settings));
    },
  );

  test('leaves the cursor untouched when a page fails to apply', () async {
    // A product whose category was never delivered violates the foreign key,
    // so the page must roll back — cursor included. Moving the cursor anyway
    // would skip these rows forever.
    final server = _FakeServer({
      'products': [
        {
          'rows': [_product('p1', 'missing-category', 'Orphan', 9)],
          'next_seq': 9,
          'has_more': false,
        },
      ],
    });

    await expectLater(sync(server), throwsA(isA<DatabaseException>()));

    expect(await SyncStateStore.instance.lastSeq('products'), 0);
    expect(await db.query('products'), isEmpty);
  });

  test('reports a revoked device distinctly from a network blip', () async {
    final server = _FakeServer({})..forcedStatus = 401;

    await expectLater(
      sync(server),
      throwsA(
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.unauthorized,
        ),
      ),
    );
  });

  test('reports a server error as retryable', () async {
    final server = _FakeServer({})..forcedStatus = 500;

    await expectLater(
      sync(server),
      throwsA(
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.server,
        ),
      ),
    );
  });
}
