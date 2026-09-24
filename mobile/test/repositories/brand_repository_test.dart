import 'package:flutter_test/flutter_test.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/repositories/brand_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/db_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;

  setUp(() async {
    db = await openInMemoryAppDb();
    await AppDatabase.instance.useTestDb(db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  test(
    'lists brands in stable case-insensitive name order and finds by id',
    () async {
      await db.insert('brands', {'id': 'brand-z', 'name': 'zeta'});
      await db.insert('brands', {'id': 'brand-a', 'name': 'Alpha'});

      final rows = await BrandRepository.instance.all();
      expect(rows.map((row) => row.id), ['brand-a', 'brand-z']);
      expect((await BrandRepository.instance.find('brand-z'))?.name, 'zeta');
      expect(await BrandRepository.instance.find('missing'), isNull);
    },
  );
}
