import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../device/till_binding.dart';
import '../models/modifier_group.dart';
import '../models/modifier_option.dart';
import '../models/product_modifier_config.dart';
import '../models/enums.dart';

/// Modifier groups (spice level, toppings, ...), their options, and which
/// products offer them. Mirrors the shape of the variant methods on
/// [ProductRepository] — bulk-fetch methods for the sell screen (one query
/// for the whole catalogue rather than one per product card), single-target
/// methods for the admin forms.
class ModifierRepository {
  static void _requireDemoWriter() {
    if (TillBinding.current != null) {
      throw StateError('Modifiers are managed in Backoffice.');
    }
  }

  ModifierRepository._();
  static final ModifierRepository instance = ModifierRepository._();

  // Groups ----------------------------------------------------------------

  Future<List<ModifierGroup>> allGroups({bool onlyActive = false}) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'modifier_groups',
      where: onlyActive ? 'active = 1' : null,
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(ModifierGroup.fromMap).toList();
  }

  Future<void> upsertGroup(ModifierGroup group) async {
    _requireDemoWriter();
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      final count = await txn.update(
        'modifier_groups',
        group.toMap(),
        where: 'id = ?',
        whereArgs: [group.id],
      );
      if (count == 0) await txn.insert('modifier_groups', group.toMap());
    });
  }

  /// How many products still carry [groupId] — shown in the delete
  /// confirmation so removing a group in heavy use is a decision made with
  /// the number in view, not a guess.
  Future<int> productCountForGroup(String groupId) async {
    final db = await AppDatabase.instance.db;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM product_modifier_groups WHERE group_id = ?',
            [groupId],
          ),
        ) ??
        0;
  }

  /// Deletes a group and, via `ON DELETE CASCADE`, its options and its
  /// product attachments. Past orders are untouched — `order_item_modifiers`
  /// has no foreign key back to this table, by design (see the schema doc
  /// comment), so a receipt already printed keeps reading exactly as it did.
  Future<void> deleteGroup(String id) async {
    _requireDemoWriter();
    final db = await AppDatabase.instance.db;
    await db.delete('modifier_groups', where: 'id = ?', whereArgs: [id]);
  }

  // Options -----------------------------------------------------------------

  /// Every option in the catalogue, grouped by group id — one query for the
  /// whole set, read once by the sell screen alongside [groupsByProduct]
  /// rather than fetched per group when a picker sheet opens.
  Future<Map<String, List<ModifierOption>>> optionsByGroup() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'modifier_options',
      orderBy: 'group_id ASC, sort_order ASC, name ASC',
    );
    final out = <String, List<ModifierOption>>{};
    for (final r in rows) {
      final o = ModifierOption.fromMap(r);
      (out[o.groupId] ??= []).add(o);
    }
    return out;
  }

  Future<List<ModifierOption>> optionsFor(String groupId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'modifier_options',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(ModifierOption.fromMap).toList();
  }

  /// Replaces a group's whole option list in one transaction — same
  /// replace-as-a-unit reasoning as `ProductRepository.replaceVariants`, but
  /// NOT a blanket delete-then-reinsert like [setGroupsForProduct] below: an
  /// option id is what `product_modifier_options` scopes against, so an
  /// option that survives this edit (same id, maybe a new price or name)
  /// must survive as an UPDATE, never a delete. `INSERT OR REPLACE` looks
  /// like it would be equivalent but is not — SQLite's REPLACE conflict
  /// resolution physically deletes the pre-existing row before reinserting,
  /// which fires `ON DELETE CASCADE` on `product_modifier_options` even
  /// though the same id comes right back a moment later, silently wiping
  /// every product's scoping for that option on the next unrelated edit
  /// (e.g. just tweaking a price). Only options genuinely removed by this
  /// save are deleted; everything else is a plain UPDATE.
  Future<void> replaceOptions(
    String groupId,
    List<ModifierOption> options,
  ) async {
    _requireDemoWriter();
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'modifier_options',
        columns: ['id'],
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
      final existingIds = existingRows.map((r) => r['id'] as String).toSet();
      final keepIds = options.map((o) => o.id).toSet();

      final removedIds = existingIds.difference(keepIds);
      if (removedIds.isNotEmpty) {
        final placeholders = List.filled(removedIds.length, '?').join(',');
        await txn.delete(
          'modifier_options',
          where: 'id IN ($placeholders)',
          whereArgs: removedIds.toList(),
        );
      }

      for (var i = 0; i < options.length; i++) {
        final o = options[i].copyWith(groupId: groupId, sortOrder: i);
        if (existingIds.contains(o.id)) {
          await txn.update(
            'modifier_options',
            o.toMap(),
            where: 'id = ?',
            whereArgs: [o.id],
          );
        } else {
          await txn.insert('modifier_options', o.toMap());
        }
      }
    });
  }

  // Product attachment ------------------------------------------------------

  /// Every group attached to every product, in one query — read by the sell
  /// screen alongside `variantsByProduct` so opening a picker sheet never
  /// waits on a query.
  Future<Map<String, List<ModifierGroup>>> groupsByProduct() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.rawQuery('''
      SELECT g.*, pmg.product_id AS product_id
      FROM product_modifier_groups pmg
      JOIN modifier_groups g ON g.id = pmg.group_id
      WHERE g.active = 1
      ORDER BY pmg.product_id ASC, g.sort_order ASC, g.name ASC
    ''');
    final out = <String, List<ModifierGroup>>{};
    for (final r in rows) {
      final productId = r['product_id'] as String;
      (out[productId] ??= []).add(ModifierGroup.fromMap(r));
    }
    return out;
  }

  /// The groups attached to one product — used by the product form, which
  /// only ever needs its own product's list rather than the whole catalogue.
  Future<List<ModifierGroup>> groupsForProduct(String productId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.rawQuery(
      '''
      SELECT g.*
      FROM product_modifier_groups pmg
      JOIN modifier_groups g ON g.id = pmg.group_id
      WHERE pmg.product_id = ?
      ORDER BY g.sort_order ASC, g.name ASC
      ''',
      [productId],
    );
    return rows.map(ModifierGroup.fromMap).toList();
  }

  /// Replaces which groups [productId] offers, as a unit — same reasoning as
  /// [replaceOptions]/`replaceVariants`: the form edits the whole set, and a
  /// half-applied save is worse than either full outcome.
  Future<void> setGroupsForProduct(
    String productId,
    List<String> groupIds,
  ) async {
    _requireDemoWriter();
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      await txn.delete(
        'product_modifier_groups',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
      for (final groupId in groupIds) {
        await txn.insert('product_modifier_groups', {
          'product_id': productId,
          'group_id': groupId,
        });
      }
    });
  }

  // Product option scope -----------------------------------------------------
  Future<ProductModifierConfig> configurationForProduct(
    String productId,
  ) async {
    final db = await AppDatabase.instance.db;
    return db.transaction((txn) async {
      final groups = await txn.query(
        'product_modifier_groups',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
      final options = await txn.query(
        'product_modifier_options',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
      return ProductModifierConfig(
        groupIds: groups.map((r) => r['group_id'] as String).toSet(),
        optionIds: options.map((r) => r['option_id'] as String).toSet(),
        defaultOptionIds: options
            .where((r) => r['is_default'] == 1)
            .map((r) => r['option_id'] as String)
            .toSet(),
      );
    });
  }

  Future<Map<String, Set<String>>> defaultsByProduct() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'product_modifier_options',
      where: 'is_default = 1',
    );
    final result = <String, Set<String>>{};
    for (final row in rows) {
      (result[row['product_id'] as String] ??= {}).add(
        row['option_id'] as String,
      );
    }
    return result;
  }

  /// Group attachment, allowed options and defaults commit together. Validation
  /// runs before deletion, so a stale/invalid form cannot erase saved settings.
  Future<void> saveConfiguration(
    String productId,
    ProductModifierConfig config,
  ) async {
    _requireDemoWriter();
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      final groups = (await txn.query(
        'modifier_groups',
      )).map(ModifierGroup.fromMap).toList();
      final options = (await txn.query(
        'modifier_options',
      )).map(ModifierOption.fromMap).toList();
      if (!groups.map((g) => g.id).toSet().containsAll(config.groupIds) ||
          !options
              .where((o) => config.groupIds.contains(o.groupId))
              .map((o) => o.id)
              .toSet()
              .containsAll(config.optionIds) ||
          !config.optionIds.containsAll(config.defaultOptionIds)) {
        throw ArgumentError('Modifier options must belong to attached groups');
      }
      for (final group in groups.where((g) => config.groupIds.contains(g.id))) {
        final defaults = options
            .where(
              (o) =>
                  o.groupId == group.id &&
                  config.defaultOptionIds.contains(o.id),
            )
            .toList();
        final limit = group.selectionType == ModifierSelectionType.single
            ? 1
            : group.maxSelect;
        if (defaults.any((o) => !o.active) ||
            (limit != null && (limit < 1 || defaults.length > limit))) {
          throw ArgumentError('Invalid modifier defaults');
        }
      }
      await txn.delete(
        'product_modifier_options',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
      await txn.delete(
        'product_modifier_groups',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
      for (final groupId in config.groupIds) {
        await txn.insert('product_modifier_groups', {
          'product_id': productId,
          'group_id': groupId,
        });
      }
      for (final optionId in config.optionIds) {
        await txn.insert('product_modifier_options', {
          'product_id': productId,
          'option_id': optionId,
          'is_default': config.defaultOptionIds.contains(optionId) ? 1 : 0,
        });
      }
    });
  }
  //
  // A further narrowing UNDER product attachment: attaching "Topping" gets a
  // product the GROUP, but which of that group's options it actually shows
  // is a separate, per-product set — a food item and a coffee can both
  // attach "Topping" and each offer a different subset (or, for a
  // single-select group like "Level Pedas", a different NUMBER of choices).
  // Deleting/reinserting `product_modifier_groups` above never touches this
  // table — it has no FK to it, only to `products` and `modifier_options`
  // directly — so that write stays exactly as cheap as before this existed.

  /// Every product's option scope, in one query — read alongside
  /// [groupsByProduct]/`optionsByGroup` so the sell screen can filter each
  /// product's offer down to just what it's scoped to without a query per
  /// card.
  Future<Map<String, Set<String>>> optionScopeByProduct() async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query('product_modifier_options');
    final out = <String, Set<String>>{};
    for (final r in rows) {
      (out[r['product_id'] as String] ??= {}).add(r['option_id'] as String);
    }
    return out;
  }

  /// The option scope for one product — for the product form, which only
  /// ever needs its own product's set.
  Future<Set<String>> optionScopeForProduct(String productId) async {
    final db = await AppDatabase.instance.db;
    final rows = await db.query(
      'product_modifier_options',
      columns: ['option_id'],
      where: 'product_id = ?',
      whereArgs: [productId],
    );
    return rows.map((r) => r['option_id'] as String).toSet();
  }

  /// Replaces which options [productId] offers, across every attached group
  /// at once, as a unit — same reasoning as [setGroupsForProduct]. A flat
  /// set rather than one call per group: an option id is already unique to
  /// one group, and the form edits the whole scope in a single sitting.
  Future<void> setOptionScopeForProduct(
    String productId,
    Set<String> optionIds,
  ) async {
    _requireDemoWriter();
    final db = await AppDatabase.instance.db;
    await db.transaction((txn) async {
      await txn.delete(
        'product_modifier_options',
        where: 'product_id = ?',
        whereArgs: [productId],
      );
      for (final optionId in optionIds) {
        await txn.insert('product_modifier_options', {
          'product_id': productId,
          'option_id': optionId,
        });
      }
    });
  }
}
