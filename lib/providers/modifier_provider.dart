import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/modifier_group.dart';
import '../data/models/modifier_option.dart';
import '../data/repositories/modifier_repository.dart';

/// Every modifier group in the catalogue, active or not — the admin screen's
/// list, and the source [productModifierGroupsProvider] filters against.
final modifierGroupsProvider =
    AsyncNotifierProvider.autoDispose<
      ModifierGroupsNotifier,
      List<ModifierGroup>
    >(ModifierGroupsNotifier.new);

class ModifierGroupsNotifier
    extends AutoDisposeAsyncNotifier<List<ModifierGroup>> {
  @override
  Future<List<ModifierGroup>> build() =>
      ModifierRepository.instance.allGroups();

  Future<void> refresh() async {
    ref.invalidate(productModifierGroupsProvider);
    ref.invalidate(modifierOptionsByGroupProvider);
    ref.invalidate(productModifierOptionScopeProvider);
    ref.invalidate(productModifierDefaultsProvider);
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ModifierRepository.instance.allGroups(),
    );
  }

  Future<void> upsertGroup(ModifierGroup group) async {
    await ModifierRepository.instance.upsertGroup(group);
    await refresh();
  }

  Future<void> deleteGroup(String id) async {
    await ModifierRepository.instance.deleteGroup(id);
    await refresh();
  }

  Future<void> replaceOptions(
    String groupId,
    List<ModifierOption> options,
  ) async {
    await ModifierRepository.instance.replaceOptions(groupId, options);
    // Options aren't part of this provider's own list, but a caller
    // re-reading `optionsByGroupProvider` right after needs it invalidated.
  }

  Future<void> setGroupsForProduct(
    String productId,
    List<String> groupIds,
  ) async {
    await ModifierRepository.instance.setGroupsForProduct(productId, groupIds);
  }

  Future<void> setOptionScopeForProduct(
    String productId,
    Set<String> optionIds,
  ) async {
    await ModifierRepository.instance.setOptionScopeForProduct(
      productId,
      optionIds,
    );
  }
}

/// Every group attached to every product, keyed by product id — one provider
/// for the whole map rather than a family per product, mirroring
/// `productVariantsProvider`: the sell grid renders every card at once, and
/// each one has to know whether it opens a modifier sheet.
final productModifierGroupsProvider =
    FutureProvider.autoDispose<Map<String, List<ModifierGroup>>>((ref) {
      return ModifierRepository.instance.groupsByProduct();
    });

/// Every option in the catalogue, keyed by group id — read alongside
/// [productModifierGroupsProvider] so `ModifierPickerSheet` opens with fully
/// resolved data and never fires a query of its own.
final modifierOptionsByGroupProvider =
    FutureProvider.autoDispose<Map<String, List<ModifierOption>>>((ref) {
      return ModifierRepository.instance.optionsByGroup();
    });

/// The groups attached to one product — for the product form, which only
/// ever needs its own product's list.
final productModifierGroupsForProvider = FutureProvider.autoDispose
    .family<List<ModifierGroup>, String>((ref, productId) {
      return ModifierRepository.instance.groupsForProduct(productId);
    });

/// The options within one group — for the group-editing form.
final modifierOptionsForProvider = FutureProvider.autoDispose
    .family<List<ModifierOption>, String>((ref, groupId) {
      return ModifierRepository.instance.optionsFor(groupId);
    });

/// Every product's option scope, keyed by product id — read alongside
/// [productModifierGroupsProvider] / [modifierOptionsByGroupProvider] so the
/// sell screen and the cart's edit flow can narrow each product's offer down
/// to just the options it's scoped to, with no query of their own.
final productModifierOptionScopeProvider =
    FutureProvider.autoDispose<Map<String, Set<String>>>((ref) {
      return ModifierRepository.instance.optionScopeByProduct();
    });

final productModifierDefaultsProvider =
    FutureProvider.autoDispose<Map<String, Set<String>>>((ref) {
      return ModifierRepository.instance.defaultsByProduct();
    });

/// The option scope for one product — for the product form.
final productModifierOptionScopeForProvider = FutureProvider.autoDispose
    .family<Set<String>, String>((ref, productId) {
      return ModifierRepository.instance.optionScopeForProduct(productId);
    });
