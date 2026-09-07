import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:nti_pos/data/database/app_database.dart';
import 'package:nti_pos/data/models/enums.dart';
import 'package:nti_pos/data/models/modifier_group.dart';
import 'package:nti_pos/data/models/modifier_option.dart';
import 'package:nti_pos/data/repositories/modifier_repository.dart';

import '../helpers/db_helper.dart';

void main() {
  setUpAll(() async {
    await initFfi();
  });

  late Database db;
  final repo = ModifierRepository.instance;

  setUp(() async {
    db = await openInMemoryAppDb(seed: true);
    await AppDatabase.instance.useTestDb(db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  group('ModifierRepository — seeded chain', () {
    test('the demo seeds all four groups', () async {
      final groups = await repo.allGroups();
      expect(groups.map((g) => g.id), containsAll(<String>[
        'mg_spice',
        'mg_sugar',
        'mg_ice',
        'mg_topping',
      ]));
    });

    test('each group has at least one option', () async {
      final byGroup = await repo.optionsByGroup();
      for (final id in ['mg_spice', 'mg_sugar', 'mg_ice', 'mg_topping']) {
        expect(byGroup[id], isNotNull, reason: '$id must have seeded options');
        expect(byGroup[id], isNotEmpty);
      }
    });

    test('seeding only attaches a group to a product that actually exists',
        () async {
      // Every product id the seed names is real (mirrors seedVariants), so
      // this is the positive case of the FK-safety test in
      // migration_test.dart's "v1 -> v17" case, which covers the negative
      // one (a catalogue with none of the target products).
      final byProduct = await repo.groupsByProduct();
      expect(byProduct['p_kopi_susu']?.map((g) => g.id),
          contains('mg_topping'));
    });

    test('groupsForProduct matches the bulk groupsByProduct for the same id',
        () async {
      final bulk = (await repo.groupsByProduct())['p_kopi_susu'] ?? const [];
      final single = await repo.groupsForProduct('p_kopi_susu');
      expect(single.map((g) => g.id).toSet(), bulk.map((g) => g.id).toSet());
    });

    test('a product with no attached groups reads as an empty list, not null',
        () async {
      // Plain food with no seeded modifier, per _seedModifierGroups.
      expect(await repo.groupsForProduct('p_air_mineral'), isEmpty);
    });
  });

  group('ModifierRepository — group CRUD', () {
    test('upsertGroup then allGroups round-trips it', () async {
      const group = ModifierGroup(
        id: 'mg_test',
        name: 'Test Group',
        selectionType: ModifierSelectionType.multiple,
        maxSelect: 2,
      );
      await repo.upsertGroup(group);

      final found = (await repo.allGroups()).firstWhere((g) => g.id == 'mg_test');
      expect(found.name, 'Test Group');
      expect(found.selectionType, ModifierSelectionType.multiple);
      expect(found.maxSelect, 2);
    });

    test('upsertGroup replaces rather than duplicating', () async {
      const group = ModifierGroup(id: 'mg_test', name: 'Test Group');
      await repo.upsertGroup(group);
      final before = (await repo.allGroups()).length;

      await repo.upsertGroup(group.copyWith(name: 'Renamed'));
      final after = await repo.allGroups();

      expect(after.length, before);
      expect(after.firstWhere((g) => g.id == 'mg_test').name, 'Renamed');
    });

    test('productCountForGroup counts attachments, zero for an unattached group',
        () async {
      const group = ModifierGroup(id: 'mg_test', name: 'Test Group');
      await repo.upsertGroup(group);
      expect(await repo.productCountForGroup('mg_test'), 0);

      await repo.setGroupsForProduct('p_air_mineral', ['mg_test']);
      expect(await repo.productCountForGroup('mg_test'), 1);
    });

    test(
      'deleteGroup cascades to its options and product attachments, but '
      'leaves past order lines untouched (no FK to them at all)',
      () async {
        const group = ModifierGroup(id: 'mg_test', name: 'Test Group');
        await repo.upsertGroup(group);
        await repo.replaceOptions(
          'mg_test',
          const [ModifierOption(id: 'o1', groupId: 'mg_test', name: 'A')],
        );
        await repo.setGroupsForProduct('p_air_mineral', ['mg_test']);

        // A past sale that used this group, snapshotted — nothing points
        // back at modifier_groups/modifier_options from here.
        await db.insert('order_item_modifiers', {
          'id': 'oim_1',
          'order_item_id': (await db.query('order_items', limit: 1)).first['id'],
          'group_name': 'Test Group',
          'option_name': 'A',
          'price_delta': 0,
          'sort_order': 0,
        });

        await repo.deleteGroup('mg_test');

        expect(await repo.optionsFor('mg_test'), isEmpty);
        expect(await repo.groupsForProduct('p_air_mineral'), isEmpty);
        final survivingSnapshot = await db.query(
          'order_item_modifiers',
          where: 'id = ?',
          whereArgs: ['oim_1'],
        );
        expect(survivingSnapshot, hasLength(1),
            reason: 'a snapshot on a past order must survive the group it '
                'was copied from being deleted');
      },
    );
  });

  group('ModifierRepository — options', () {
    test('replaceOptions is a whole-list swap, not a merge', () async {
      const group = ModifierGroup(id: 'mg_test', name: 'Test Group');
      await repo.upsertGroup(group);
      await repo.replaceOptions('mg_test', const [
        ModifierOption(id: 'o1', groupId: 'mg_test', name: 'A'),
        ModifierOption(id: 'o2', groupId: 'mg_test', name: 'B'),
      ]);
      await repo.replaceOptions('mg_test', const [
        ModifierOption(id: 'o3', groupId: 'mg_test', name: 'C'),
      ]);

      final options = await repo.optionsFor('mg_test');
      expect(options.map((o) => o.name), ['C']);
    });

    test('replaceOptions assigns sortOrder from list position', () async {
      const group = ModifierGroup(id: 'mg_test', name: 'Test Group');
      await repo.upsertGroup(group);
      await repo.replaceOptions('mg_test', const [
        ModifierOption(id: 'o1', groupId: '', name: 'First'),
        ModifierOption(id: 'o2', groupId: '', name: 'Second'),
      ]);

      final options = await repo.optionsFor('mg_test');
      expect(options[0].name, 'First');
      expect(options[0].sortOrder, 0);
      expect(options[1].name, 'Second');
      expect(options[1].sortOrder, 1);
    });
  });

  group('ModifierRepository — product attachment', () {
    test('setGroupsForProduct is a whole-set swap, not a merge', () async {
      await repo.setGroupsForProduct('p_air_mineral', ['mg_spice', 'mg_sugar']);
      await repo.setGroupsForProduct('p_air_mineral', ['mg_ice']);

      final groups = await repo.groupsForProduct('p_air_mineral');
      expect(groups.map((g) => g.id), ['mg_ice']);
    });

    test('setGroupsForProduct([]) detaches every group', () async {
      await repo.setGroupsForProduct('p_air_mineral', ['mg_spice']);
      await repo.setGroupsForProduct('p_air_mineral', []);

      expect(await repo.groupsForProduct('p_air_mineral'), isEmpty);
    });

    test('the same group can attach to more than one product — reusable, not '
        'redefined per product', () async {
      await repo.setGroupsForProduct('p_air_mineral', ['mg_spice']);
      await repo.setGroupsForProduct('p_es_jeruk', ['mg_spice']);

      final byProduct = await repo.groupsByProduct();
      expect(byProduct['p_air_mineral']?.map((g) => g.id), contains('mg_spice'));
      expect(byProduct['p_es_jeruk']?.map((g) => g.id), contains('mg_spice'));
    });
  });

  group('ModifierRepository — product option scope', () {
    Future<void> setUpGroupWithOptions() async {
      const group = ModifierGroup(id: 'mg_test', name: 'Test Group');
      await repo.upsertGroup(group);
      await repo.replaceOptions('mg_test', const [
        ModifierOption(id: 'o1', groupId: 'mg_test', name: 'A'),
        ModifierOption(id: 'o2', groupId: 'mg_test', name: 'B'),
        ModifierOption(id: 'o3', groupId: 'mg_test', name: 'C'),
      ]);
    }

    test('a newly-attached group has no scope until one is set — attaching '
        'the GROUP is not attaching its options', () async {
      await setUpGroupWithOptions();
      await repo.setGroupsForProduct('p_air_mineral', ['mg_test']);

      expect(await repo.optionScopeForProduct('p_air_mineral'), isEmpty);
    });

    test('setOptionScopeForProduct is a whole-set swap, not a merge',
        () async {
      await setUpGroupWithOptions();
      await repo.setOptionScopeForProduct('p_air_mineral', {'o1', 'o2'});
      await repo.setOptionScopeForProduct('p_air_mineral', {'o3'});

      expect(await repo.optionScopeForProduct('p_air_mineral'), {'o3'});
    });

    test('a food item and a coffee attached to the SAME group can offer '
        'different subsets of its options', () async {
      await setUpGroupWithOptions();
      await repo.setGroupsForProduct('p_air_mineral', ['mg_test']);
      await repo.setGroupsForProduct('p_es_jeruk', ['mg_test']);
      await repo.setOptionScopeForProduct('p_air_mineral', {'o1'});
      await repo.setOptionScopeForProduct('p_es_jeruk', {'o1', 'o2', 'o3'});

      final byProduct = await repo.optionScopeByProduct();
      expect(byProduct['p_air_mineral'], {'o1'});
      expect(byProduct['p_es_jeruk'], {'o1', 'o2', 'o3'});
    });

    test(
      'replaceOptions on the group PRESERVES scoping for an option that '
      'survives the edit (same id) and only drops scoping for one that is '
      'genuinely removed',
      () async {
        await setUpGroupWithOptions();
        await repo.setOptionScopeForProduct('p_air_mineral', {'o1', 'o2'});

        // Edit the group: keep o1 (renamed) and o2 untouched, drop o3,
        // add a brand-new o4 — exactly what the admin form sends on Save.
        await repo.replaceOptions('mg_test', const [
          ModifierOption(id: 'o1', groupId: 'mg_test', name: 'A renamed'),
          ModifierOption(id: 'o2', groupId: 'mg_test', name: 'B'),
          ModifierOption(id: 'o4', groupId: 'mg_test', name: 'D'),
        ]);

        expect(
          await repo.optionScopeForProduct('p_air_mineral'),
          {'o1', 'o2'},
          reason: 'o1 and o2 kept their ids across the edit, so a product '
              'scoped to them must not silently lose that scoping just '
              'because an unrelated option in the same group changed',
        );
      },
    );

    test(
      'deleting an option from its group (by leaving it out of '
      'replaceOptions) DOES remove it from every product scoped to it',
      () async {
        await setUpGroupWithOptions();
        await repo.setOptionScopeForProduct('p_air_mineral', {'o1', 'o2', 'o3'});

        await repo.replaceOptions('mg_test', const [
          ModifierOption(id: 'o1', groupId: 'mg_test', name: 'A'),
        ]);

        expect(await repo.optionScopeForProduct('p_air_mineral'), {'o1'});
      },
    );

    test('deleteGroup cascades to product_modifier_options via its options',
        () async {
      await setUpGroupWithOptions();
      await repo.setOptionScopeForProduct('p_air_mineral', {'o1'});

      await repo.deleteGroup('mg_test');

      expect(await repo.optionScopeForProduct('p_air_mineral'), isEmpty);
    });
  });
}
