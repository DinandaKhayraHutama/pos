import '../database/app_database.dart';
import '../models/product.dart';
import '../models/product_variant.dart';

/// Reads the catalogue, with each product's count taken from ONE branch.
///
/// Every read takes an [outletId] because a product's price is the chain's but
/// its stock is one shop's. Passing the wrong branch here is the mistake that
/// shows a cashier a shelf they cannot reach, so the parameter is required
/// rather than defaulted — there is no sensible "any outlet" answer.
class ProductRepository {
  ProductRepository._();
  static final ProductRepository instance = ProductRepository._();

  /// `products` joined to one branch's counts.
  ///
  /// `COALESCE` rather than a plain join: a branch that has never counted an
  /// item inherits the catalogue's opening figure, so adding a product does
  /// not make it read as untracked everywhere until someone books it in.
  static const String _from =
      'FROM products p '
      'LEFT JOIN outlet_stock os '
      '  ON os.product_id = p.id AND os.outlet_id = ?';
  static const String _select =
      'SELECT p.*, COALESCE(os.stock, p.stock) AS outlet_stock $_from';

  /// The join aliases the branch count so it cannot collide with `p.stock`;
  /// this puts it back under the name the model reads.
  static List<Product> _mapRows(List<Map<String, Object?>> rows) => [
    for (final r in rows) Product.fromMap({...r, 'stock': r['outlet_stock']}),
  ];

  Future<List<Product>> all({
    required String outletId,
    bool onlyAvailable = false,
  }) async {
    final db = await AppDatabase.instance.db;
    return _mapRows(
      await db.rawQuery(
        '$_select ${onlyAvailable ? 'WHERE p.available = 1' : ''} '
        'ORDER BY p.is_popular DESC, p.sort_order ASC, p.name ASC',
        [outletId],
      ),
    );
  }

  Future<List<Product>> byCategory(
    String categoryId, {
    required String outletId,
    bool onlyAvailable = true,
  }) async {
    final db = await AppDatabase.instance.db;
    return _mapRows(
      await db.rawQuery(
        '$_select WHERE p.category_id = ? '
        '${onlyAvailable ? 'AND p.available = 1' : ''} '
        'ORDER BY p.is_popular DESC, p.sort_order ASC, p.name ASC',
        [outletId, categoryId],
      ),
    );
  }

  Future<List<Product>> popular({
    required String outletId,
    bool onlyAvailable = true,
  }) async {
    final db = await AppDatabase.instance.db;
    return _mapRows(
      await db.rawQuery(
        '$_select WHERE p.is_popular = 1 '
        '${onlyAvailable ? 'AND p.available = 1' : ''} '
        'ORDER BY p.sort_order ASC, p.name ASC',
        [outletId],
      ),
    );
  }

  Future<List<Product>> search(String query, {required String outletId}) async {
    final db = await AppDatabase.instance.db;
    return _mapRows(
      await db.rawQuery(
        '$_select WHERE p.name LIKE ? AND p.available = 1 '
        'ORDER BY p.is_popular DESC, p.name ASC LIMIT 30',
        [outletId, '%$query%'],
      ),
    );
  }

  Future<void> upsert(Product p) async {
    final db = await AppDatabase.instance.db;
    // REPLACE deletes the parent row and cascades modifier/variant relations.
    await db.transaction((txn) async {
      final count = await txn.update(
        'products',
        p.toMap(),
        where: 'id = ?',
        whereArgs: [p.id],
      );
      if (count == 0) await txn.insert('products', p.toMap());
    });
  }

  Future<void> delete(String id) async {
    final db = await AppDatabase.instance.db;
    await db.delete('products', where: 'id = ?', whereArgs: [id]);
  }

  /// Products whose tracked count has fallen to [threshold] or below.
  ///
  /// Untracked products are excluded by the `IS NOT NULL` — a kitchen item
  /// cooked to order is not "0 in stock", it simply is not counted, and
  /// listing it as an alert would bury the ones that matter.
  Future<List<Product>> lowStock({
    required String outletId,
    int threshold = Product.lowStockThreshold,
  }) async {
    final db = await AppDatabase.instance.db;
    return _mapRows(
      await db.rawQuery(
        '$_select WHERE COALESCE(os.stock, p.stock) IS NOT NULL '
        '  AND COALESCE(os.stock, p.stock) <= ? '
        'ORDER BY outlet_stock ASC, p.name ASC',
        [outletId, threshold],
      ),
    );
  }

  // Variants ------------------------------------------------------------

  /// Every variant in the catalogue, grouped by product id.
  ///
  /// One query for the whole catalogue rather than one per product: the sell
  /// screen shows 26 products at once, and 26 round trips to decide which
  /// cards need a picker is the kind of thing that makes a grid feel slow for
  /// no visible reason.
  Future<Map<String, List<ProductVariant>>> variantsByProduct() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'product_variants',
      orderBy: 'product_id ASC, sort_order ASC, name ASC',
    );
    final out = <String, List<ProductVariant>>{};
    for (final r in rows) {
      final v = ProductVariant.fromMap(r);
      (out[v.productId] ??= []).add(v);
    }
    return out;
  }

  Future<List<ProductVariant>> variantsFor(String productId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'product_variants',
      where: 'product_id = ?',
      whereArgs: [productId],
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(ProductVariant.fromMap).toList();
  }

  /// Replaces a product's whole variant list in one transaction.
  ///
  /// Replace rather than diff: the form edits the list as a unit, and a
  /// half-applied edit — the renamed row saved, the deleted one still there —
  /// is worse than either outcome.
  Future<void> replaceVariants(
    String productId,
    List<ProductVariant> variants,
  ) async {
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      await txn.delete(
        'product_variants',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
      for (var i = 0; i < variants.length; i++) {
        await txn.insert(
          'product_variants',
          variants[i].copyWith(productId: productId, sortOrder: i).toMap(),
        );
      }
    });
  }
}
