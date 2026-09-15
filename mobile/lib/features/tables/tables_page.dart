import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_buttons.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_chip.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../core/widgets/status_badge.dart';
import '../../data/models/enums.dart';
import '../../data/models/table.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/order_provider.dart';

// Geometry of a [_TableTile]. The tables grid derives its tile height from
// these via [tableTileExtent] instead of guessing a childAspectRatio, so the
// card can never be clipped - at any tile width, on any screen, at any text
// scale. Same approach as productCardExtent in features/pos/product_card.dart.
const double _tilePadding = AppDimensions.space12;
const double _iconRowHeight = 32;
const double _gapAfterIconRow = AppDimensions.space8;
const double _nameFontSize = 15;
const double _nameLineHeight = 1.25;
const double _capacityFontSize = 12;
const double _capacityLineHeight = 1.25;
const double _gapAfterName = AppDimensions.space2;

/// Height a [_TableTile] needs, independent of tile width (both text rows are
/// capped at one line, so the extent only scales with the user's text scale).
double tableTileExtent(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  return _tilePadding * 2 +
      _iconRowHeight +
      _gapAfterIconRow +
      _lineHeight(scaler, _nameFontSize, _nameLineHeight) +
      _gapAfterName +
      _lineHeight(scaler, _capacityFontSize, _capacityLineHeight);
}

// Text line heights round up when a paragraph is laid out, so each block
// reserves whole pixels per line - reserving the exact fractional height
// overflowed by a fraction of a pixel.
double _lineHeight(TextScaler scaler, double fontSize, double height) =>
    (scaler.scale(fontSize) * height).ceilToDouble();

class TablesPage extends ConsumerWidget {
  const TablesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tables = ref.watch(tablesProvider);

    final floors = tables.maybeWhen(
      data: (data) {
        final m = <String, List<RestaurantTable>>{};
        for (final t in data) {
          m.putIfAbsent(t.floor, () => []).add(t);
        }
        final keys = m.keys.toList()..sort();
        return {for (final k in keys) k: m[k]!};
      },
      orElse: () => <String, List<RestaurantTable>>{},
    );

    final counts = tables.maybeWhen(
      data: (data) {
        final available = data
            .where((t) => t.status == TableStatus.available)
            .length;
        final occupied = data
            .where((t) => t.status == TableStatus.occupied)
            .length;
        return (total: data.length, available: available, occupied: occupied);
      },
      orElse: () => (total: 0, available: 0, occupied: 0),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(
        title: l10n.tablesTitle,
        actions: [
          IconButton(
            onPressed: () => ref.invalidate(tablesProvider),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(tablesProvider);
        },
        child: tables.when(
          loading: () => ListView(
            children: [
              const SizedBox(height: AppDimensions.space24),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimensions.space16,
                ),
                child: LoadingIndicator.skeleton(lines: 4),
              ),
            ],
          ),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: l10n.commonError,
            subtitle: '$e',
          ),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: [
                  EmptyState(
                    icon: Icons.table_restaurant_rounded,
                    title: l10n.tablesEmpty,
                    subtitle: l10n.tablesEmptyHint,
                  ),
                ],
              );
            }
            return CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppDimensions.space16,
                      AppDimensions.space8,
                      AppDimensions.space16,
                      AppDimensions.space16,
                    ),
                    child: _SummaryRow(counts: counts),
                  ),
                ),
                for (final entry in floors.entries) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppDimensions.space16,
                        AppDimensions.space4,
                        AppDimensions.space16,
                        AppDimensions.space8,
                      ),
                      child: _FloorLabel(label: _floorLabel(entry.key, l10n)),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      AppDimensions.space16,
                      0,
                      AppDimensions.space16,
                      0,
                    ),
                    sliver: SliverGrid(
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 170,
                        mainAxisSpacing: AppDimensions.space10,
                        crossAxisSpacing: AppDimensions.space10,
                        // Computed from the text scale - a childAspectRatio
                        // guess would clip the capacity row at textScaler
                        // 1.15 (see CLAUDE.md rule #5).
                        mainAxisExtent: tableTileExtent(context),
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _TableTile(table: entry.value[i]),
                        childCount: entry.value.length,
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                ],
                const SliverToBoxAdapter(
                  child: SizedBox(height: AppDimensions.space24),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  String _floorLabel(String floor, AppLocalizations l10n) => switch (floor) {
    'floor_1' => l10n.tablesFloor1,
    'floor_2' => l10n.tablesFloor2,
    'floor_3' => l10n.tablesFloor3,
    'floor_4' => l10n.tablesFloor4,
    _ => floor,
  };
}

class _FloorLabel extends StatelessWidget {
  const _FloorLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Text(
      label,
      style: TextStyle(
        color: design.textMedium,
        fontWeight: FontWeight.w800,
        fontSize: 13,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.counts});
  final ({int total, int available, int occupied}) counts;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            label: context.l10n.tablesTotal,
            value: '${counts.total}',
          ),
        ),
        const SizedBox(width: AppDimensions.space8),
        Expanded(
          child: _StatTile(
            label: context.l10n.tableStatusAvailable,
            value: '${counts.available}',
          ),
        ),
        const SizedBox(width: AppDimensions.space8),
        Expanded(
          child: _StatTile(
            label: context.l10n.tableStatusOccupied,
            value: '${counts.occupied}',
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    // Neutral card; the count is what matters, so it carries the contrast.
    // Matches the Dashboard stat tiles — three brand-filled blocks across the
    // top of a page is decoration, not information.
    return GlassCard.solid(
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.all(AppDimensions.space12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: TextStyle(
                    color: design.textHigh,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: AppDimensions.space2),
              Text(
                label,
                style: TextStyle(
                  color: design.textMedium,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TableTile extends ConsumerWidget {
  const _TableTile({required this.table});
  final RestaurantTable table;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final design = context.design;
    final occupied = table.status == TableStatus.occupied;
    final reserved = table.status == TableStatus.reserved;

    final iconFg = occupied
        ? design.warning
        : reserved
        ? design.info
        : design.primary;
    final iconBg = occupied
        ? design.warningContainer
        : reserved
        ? design.infoContainer
        : design.primaryContainer;

    return GlassCard.solid(
      onTap: () => _showActions(context, ref),
      padding: const EdgeInsets.all(_tilePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: _iconRowHeight,
                height: _iconRowHeight,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(AppDimensions.radius8),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.table_restaurant_rounded,
                  size: 18,
                  color: iconFg,
                ),
              ),
              const Spacer(),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // A deactivated table only ever reaches this board while
                      // it is still mid-service (see TableRepository.operational) —
                      // this marks that it will disappear once cleared, rather
                      // than looking like a table anyone can still be sat at.
                      if (!table.active) ...[
                        Icon(
                          Icons.visibility_off_rounded,
                          size: 14,
                          color: design.textLow,
                        ),
                        const SizedBox(width: 4),
                      ],
                      if (table.contested) ...[
                        Tooltip(
                          message: context.l10n.tableContested,
                          child: Icon(
                            Icons.warning_amber_rounded,
                            size: 18,
                            color: design.warning,
                          ),
                        ),
                        const SizedBox(width: AppDimensions.space4),
                      ],
                      StatusBadge(status: table.status, compact: true),
                    ],
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: _gapAfterIconRow),
          Text(
            table.name,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: _nameFontSize,
              height: _nameLineHeight,
              color: design.textHigh,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: _gapAfterName),
          Text(
            context.l10n.tablesCapacity(table.capacity),
            style: TextStyle(
              color: design.textMedium,
              fontSize: _capacityFontSize,
              height: _capacityLineHeight,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    showGlassSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppDimensions.space16,
            0,
            AppDimensions.space16,
            AppDimensions.space16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.table_restaurant_rounded, color: design.primary),
                  const SizedBox(width: AppDimensions.space8),
                  Expanded(
                    child: Text(
                      table.name,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: design.textHigh,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  StatusBadge(status: table.status),
                ],
              ),
              const SizedBox(height: AppDimensions.space4),
              Text(
                l10n.tablesCapacity(table.capacity),
                style: TextStyle(color: design.textMedium),
              ),
              const SizedBox(height: AppDimensions.space16),
              if (table.contested) ...[
                Text(
                  l10n.tableContestedHelp,
                  style: TextStyle(color: design.warning),
                ),
                const SizedBox(height: AppDimensions.space8),
              ],
              Text(
                l10n.tablesSetStatus,
                style: TextStyle(
                  color: design.textMedium,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppDimensions.space8),
              Wrap(
                spacing: AppDimensions.space8,
                runSpacing: AppDimensions.space8,
                children: [
                  _statusChip(
                    context,
                    ref,
                    TableStatus.available,
                    l10n.tableStatusAvailable,
                  ),
                  _statusChip(
                    context,
                    ref,
                    TableStatus.occupied,
                    l10n.tableStatusOccupied,
                  ),
                  _statusChip(
                    context,
                    ref,
                    TableStatus.reserved,
                    l10n.tableStatusReserved,
                  ),
                ],
              ),
              const SizedBox(height: AppDimensions.space16),
              if (table.status == TableStatus.available)
                PrimaryButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    context.go('/');
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add_shopping_cart_rounded),
                      const SizedBox(width: AppDimensions.space8),
                      Text(l10n.tablesStartOrder),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusChip(
    BuildContext context,
    WidgetRef ref,
    TableStatus s,
    String label,
  ) {
    final selected = table.status == s;
    return GlassFilterChip(
      label: label,
      selected: selected,
      onTap: () async {
        await ref.read(tablesProvider.notifier).setStatus(table.id, s);
        if (context.mounted) Navigator.of(context).pop();
      },
    );
  }
}
