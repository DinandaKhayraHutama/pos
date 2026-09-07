import 'enums.dart';
import 'modifier_group.dart';
import 'modifier_option.dart';

/// Product-specific configuration; empty defaults deliberately mean no picks.
class ProductModifierConfig {
  ProductModifierConfig({
    Set<String> groupIds = const {},
    Set<String> optionIds = const {},
    Set<String> defaultOptionIds = const {},
  }) : groupIds = Set.unmodifiable(groupIds),
       optionIds = Set.unmodifiable(optionIds),
       defaultOptionIds = Set.unmodifiable(defaultOptionIds);

  final Set<String> groupIds;
  final Set<String> optionIds;
  final Set<String> defaultOptionIds;
}

/// Resolve current catalogue rows, excluding removed/inactive options. A group
/// edited from multiple to single (or given a lower cap) cannot produce too
/// many defaults or leave stale selections in an edited cart.
List<ModifierOption> resolveModifierSelection(
  ModifierGroup group,
  List<ModifierOption> options,
  Set<String> selectedIds,
) {
  if (!group.active) return const [];
  final limit = group.selectionType == ModifierSelectionType.single
      ? 1
      : group.maxSelect;
  final seen = <String>{};
  final selected = options.where(
    (o) =>
        o.groupId == group.id &&
        o.active &&
        selectedIds.contains(o.id) &&
        seen.add(o.id),
  );
  return (limit == null ? selected : selected.take(limit < 1 ? 1 : limit))
      .toList();
}
