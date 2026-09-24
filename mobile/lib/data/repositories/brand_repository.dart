import '../database/app_database.dart';
import '../models/catalogue_brand.dart';

/// Read-only access to the brand master delivered by [CatalogueSync].
///
/// Brand editing belongs to Backoffice in F2; the till only needs a stable
/// lookup for catalogue and future filters.
class BrandRepository {
  BrandRepository._();
  static final instance = BrandRepository._();

  Future<List<CatalogueBrand>> all() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query('brands', orderBy: 'name COLLATE NOCASE, id');
    return rows.map(CatalogueBrand.fromMap).toList();
  }

  Future<CatalogueBrand?> find(String id) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'brands',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : CatalogueBrand.fromMap(rows.single);
  }
}
