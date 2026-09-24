import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../data/models/enums.dart';
import '../../data/models/table.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/bill_provider.dart';
import '../../providers/cart_provider.dart';
import '../../providers/order_provider.dart';
import '../bills/bill_ui.dart';

/// Lets the cashier pick a dine-in table for the active cart.
///
/// Renders inside a [GlassSheet] (via `showGlassSheet`), which supplies the
/// grabber + frosted blur. This widget only paints the title row + grid of
/// [_TableChip]s.
class TablePickerSheet extends ConsumerWidget {
  const TablePickerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    // Active tables only — a deactivated table must never be offered for a
    // NEW dine-in order, even while it is still visible on the floor board
    // because a previous order is still open on it.
    final tables = ref.watch(activeTablesProvider);
    final selected = ref.watch(cartProvider.select((c) => c.table?.id));

    final floors = tables.maybeWhen(
      data: (t) => _groupByFloor(t),
      orElse: () => <String, List<RestaurantTable>>{},
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimensions.space16,
          AppDimensions.space4,
          AppDimensions.space16,
          AppDimensions.space16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  l10n.posSelectTable,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: design.textHigh,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space8),
            Flexible(
              child: tables.when(
                loading: () => const SizedBox(
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: l10n.commonError,
                  subtitle: '$e',
                ),
                data: (all) {
                  if (all.isEmpty) {
                    return EmptyState(
                      icon: Icons.table_restaurant_rounded,
                      title: l10n.tablesEmpty,
                      subtitle: l10n.tablesEmptyHint,
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      for (final entry in floors.entries) ...[
                        Padding(
                          padding: const EdgeInsets.only(
                            top: AppDimensions.space8,
                            bottom: AppDimensions.space8,
                          ),
                          child: Text(
                            _floorLabel(entry.key, l10n),
                            style: TextStyle(
                              color: design.textMedium,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Wrap(
                          spacing: AppDimensions.space10,
                          runSpacing: AppDimensions.space10,
                          children: entry.value
                              .map(
                                (t) => _TableChip(
                                  table: t,
                                  selected: selected == t.id,
                                  onTap: () async {
                                    // Where saved bills run, picking a table
                                    // seats it: online, so two tills cannot
                                    // seat one table (paritas F4).
                                    if (ref.read(billsEnabledProvider)) {
                                      final ok = await runBillAction(
                                        context,
                                        () => seatTable(
                                          read: ref.read,
                                          invalidate: ref.invalidate,
                                          table: t,
                                        ),
                                      );
                                      if (ok && context.mounted) {
                                        Navigator.of(context).pop();
                                      }
                                      return;
                                    }
                                    ref.read(cartProvider.notifier).setTable(t);
                                    Navigator.of(context).pop();
                                  },
                                ),
                              )
                              .toList(),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, List<RestaurantTable>> _groupByFloor(
    List<RestaurantTable> tables,
  ) {
    final m = <String, List<RestaurantTable>>{};
    for (final t in tables) {
      m.putIfAbsent(t.floor, () => []).add(t);
    }
    final keys = m.keys.toList()..sort();
    return {for (final k in keys) k: m[k]!};
  }

  String _floorLabel(String floor, AppLocalizations l10n) => switch (floor) {
    'floor_1' => l10n.tablesFloor1,
    'floor_2' => l10n.tablesFloor2,
    'floor_3' => l10n.tablesFloor3,
    _ => floor,
  };
}

class _TableChip extends StatelessWidget {
  const _TableChip({
    required this.table,
    required this.selected,
    required this.onTap,
  });
  final RestaurantTable table;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final occupied = table.status != TableStatus.available;

    final statusColor = switch (table.status) {
      TableStatus.available => design.success,
      TableStatus.occupied => design.error,
      TableStatus.reserved => design.warning,
    };
    final statusContainer = switch (table.status) {
      TableStatus.available => design.successContainer,
      TableStatus.occupied => design.errorContainer,
      TableStatus.reserved => design.warningContainer,
    };

    return GlassCard(
      tint: selected ? design.primary : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space14,
        vertical: AppDimensions.space10,
      ),
      radius: AppDimensions.radiusLg,
      onTap: occupied ? null : onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: selected
                      ? design.onPrimary.withValues(alpha: 0.18)
                      : statusContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.table_restaurant_rounded,
                  size: 16,
                  color: selected ? design.onPrimary : statusColor,
                ),
              ),
              const SizedBox(width: AppDimensions.space8),
              Text(
                table.name,
                style: TextStyle(
                  color: selected ? design.onPrimary : design.textHigh,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimensions.space6),
          Text(
            occupied
                ? (table.status == TableStatus.occupied
                      ? l10n.tableStatusOccupied
                      : l10n.tableStatusReserved)
                : l10n.tablesCapacity(table.capacity),
            style: TextStyle(
              color: selected
                  ? design.onPrimary.withValues(alpha: 0.85)
                  : design.textMedium,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
