import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/product_modifier_config.dart';
import 'package:nti_pos/data/models/product.dart';
import 'package:nti_pos/data/repositories/modifier_repository.dart';
import 'package:nti_pos/data/repositories/product_repository.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/repositories/order_repository.dart';
import '../helpers/db_helper.dart';

void main() {
  late Database db;
  final repo = ModifierRepository.instance;
  setUp(() async {
    db = await openInMemoryAppDb(seed: true);
    await AppDatabase.instance.useTestDb(db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  test(
    'different modifier lines debit total SKU quantity and preserve snapshots',
    () async {
      const productId = 'p_nasi_goreng';
      final outlet = (await db.query('outlets')).first['id'] as String;
      await db.update(
        'products',
        {'stock': 20},
        where: 'id = ?',
        whereArgs: [productId],
      );
      await db.insert('outlet_stock', {
        'product_id': productId,
        'outlet_id': outlet,
        'stock': 20,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      final options = await repo.optionsFor('mg_spice');
      final order = await OrderRepository.instance.create(
        type: OrderType.takeaway,
        items: [
          for (var i = 0; i < 2; i++)
            OrderItemDraft(
              productId: productId,
              productName: 'Dish',
              unitPrice: 10000 + i * 1000,
              quantity: i + 1,
              modifiers: [
                (
                  groupName: 'Spice',
                  optionName: options[i].name,
                  priceDelta: i * 1000,
                ),
              ],
            ),
        ],
        subtotal: 32000,
        discount: 0,
        tax: 0,
        total: 32000,
        amountPaid: 32000,
        paymentMethod: PaymentMethod.cash,
        cashierId: 'emp_kasir_1',
        cashierName: 'Cashier',
        outletId: outlet,
      );
      expect(
        (await db.query(
          'outlet_stock',
          where: 'product_id = ? AND outlet_id = ?',
          whereArgs: [productId, outlet],
        )).single['stock'],
        17,
      );
      await repo.deleteGroup('mg_spice');
      final restored = (await OrderRepository.instance.byId(order.id))!;
      expect(
        restored.items.map((i) => i.modifiers.single.optionName).toSet(),
        options.take(2).map((o) => o.name).toSet(),
      );
      expect(restored.items.fold(0, (sum, i) => sum + i.lineTotal), 32000);
    },
  );

  test(
    'scopes/defaults persist per product and survive parent/option updates',
    () async {
      final group = (await repo.allGroups()).firstWhere(
        (g) => g.id == 'mg_spice',
      );
      final options = await repo.optionsFor(group.id);
      final config = ProductModifierConfig(
        groupIds: {group.id},
        optionIds: {options.first.id},
        defaultOptionIds: {options.first.id},
      );
      await repo.saveConfiguration('p_nasi_goreng', config);
      await repo.upsertGroup(group.copyWith(name: 'Renamed'));
      await repo.replaceOptions(
        group.id,
        options.map((o) => o.copyWith(priceDelta: 1000)).toList(),
      );
      final product = Product.fromMap(
        (await db.query(
          'products',
          where: 'id = ?',
          whereArgs: ['p_nasi_goreng'],
        )).single,
      );
      await ProductRepository.instance.upsert(
        product.copyWith(name: 'Renamed dish'),
      );
      final saved = await repo.configurationForProduct(product.id);
      expect(saved.groupIds, config.groupIds);
      expect(saved.optionIds, config.optionIds);
      expect(saved.defaultOptionIds, config.defaultOptionIds);
      expect(
        (await repo.defaultsByProduct())[product.id],
        config.defaultOptionIds,
      );
      expect(
        (await repo.configurationForProduct('p_mie_goreng')).defaultOptionIds,
        isEmpty,
      );
    },
  );

  test(
    'invalid defaults rollback; removing group clears both options and defaults',
    () async {
      final options = await repo.optionsFor('mg_spice');
      final valid = ProductModifierConfig(
        groupIds: {'mg_spice'},
        optionIds: {options.first.id},
        defaultOptionIds: {options.first.id},
      );
      await repo.saveConfiguration('p_nasi_goreng', valid);
      await expectLater(
        repo.saveConfiguration(
          'p_nasi_goreng',
          ProductModifierConfig(
            groupIds: {'mg_spice'},
            optionIds: options.map((o) => o.id).toSet(),
            defaultOptionIds: options.take(2).map((o) => o.id).toSet(),
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        repo.saveConfiguration(
          'p_nasi_goreng',
          ProductModifierConfig(groupIds: {}, optionIds: {options.first.id}),
        ),
        throwsArgumentError,
      );
      expect(
        (await repo.configurationForProduct('p_nasi_goreng')).defaultOptionIds,
        valid.defaultOptionIds,
      );
      await repo.saveConfiguration('p_nasi_goreng', ProductModifierConfig());
      expect(
        (await repo.configurationForProduct('p_nasi_goreng')).optionIds,
        isEmpty,
      );
      expect((await repo.defaultsByProduct())['p_nasi_goreng'], isNull);
    },
  );

  test(
    'v19 physical schema upgrades without assigning defaults or losing scope',
    () async {
      final dir = await Directory.systemTemp.createTemp('modifier_v20_');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/legacy.db';
      final legacy = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 19,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE product_modifier_options (product_id TEXT, option_id TEXT, PRIMARY KEY(product_id, option_id))',
            );
            await db.insert('product_modifier_options', {
              'product_id': 'p',
              'option_id': 'a',
            });
            // Every real pre-v20 install has had `tables` since v1 — this
            // stub only recreates what v20+ actually reads, but the v21 step
            // (tables.active) still runs against it and needs the table to
            // exist to ALTER.
            await db.execute('CREATE TABLE tables (id TEXT PRIMARY KEY)');
          },
        ),
      );
      await legacy.close();
      final migrated = await AppDatabase.openForTest(path: path, seed: false);
      try {
        expect((await migrated.query('product_modifier_options')).single, {
          'product_id': 'p',
          'option_id': 'a',
          'is_default': 0,
        });
      } finally {
        await migrated.close();
      }
    },
  );
}
