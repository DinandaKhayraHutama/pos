import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/category.dart';

class CategoryRepository {
  CategoryRepository._();
  static final CategoryRepository instance = CategoryRepository._();

  Future<List<Category>> all() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'categories',
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(Category.fromMap).toList();
  }

  Future<Category> byId(String id) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query('categories', where: 'id = ?', whereArgs: [id]);
    return Category.fromMap(rows.first);
  }

  Future<void> upsert(Category c) async {
    final db = await AppDatabase.instance.db;
    await db.insert(
      'categories',
      c.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String id) async {
    final db = await AppDatabase.instance.db;
    await db.delete('categories', where: 'id = ?', whereArgs: [id]);
  }
}
