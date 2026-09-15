import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/permissions.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/icon_map.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../data/models/order.dart';
import '../../data/models/product.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/catalog_provider.dart';
import '../../providers/order_provider.dart';
import '../../providers/outlet_provider.dart';
import '../../providers/settings_provider.dart';

/// Sales summary dashboard.
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider).valueOrNull;
    final summary = ref.watch(dashboardSummaryProvider);
    final topProducts = ref.watch(topProductsProvider);
    final orders = ref.watch(ordersProvider(null));

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(
        title: l10n.dashboardTitle,
        actions: [
          // Only for whoever may read the money view. A manager gets the
          // day's summary below but not the ranged financial report, so
          // leaving the button here would take them to a redirect.
          if (settings?.can(AppPermission.viewFinancialReports) ?? false)
            IconButton(
              tooltip: l10n.reportTitle,
              onPressed: () => context.push('/report'),
              icon: const Icon(Icons.insert_chart_outlined_rounded),
            ),
          IconButton(
            onPressed: () {
              ref.invalidate(dashboardSummaryProvider);
              ref.invalidate(topProductsProvider);
              ref.invalidate(ordersProvider);
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dashboardSummaryProvider);
          ref.invalidate(topProductsProvider);
          ref.invalidate(ordersProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(AppDimensions.space16),
          children: [
            _HeaderCard(
              greeting: l10n.dashboardGreeting(settings?.cashierName ?? ''),
              // The chain, then the branch. Without the branch this card reports
        // one shop's takings under the whole business's name.
        storeName: [
          settings?.storeName ?? '',
          ref.watch(activeOutletProvider).valueOrNull?.name,
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
            ),
            const SizedBox(height: AppDimensions.space14),
            summary.when<Widget>(
              loading: () => SizedBox(
                height: 130,
                child: LoadingIndicator.skeleton(lines: 3),
              ),
              error: (e, _) => Text('$e'),
              data: (data) => _statsRow(context, l10n, data),
            ),
            // Only for someone who can act on it. Telling a cashier that
            // three items are low is noise: they cannot book stock in.
            if (settings?.can(AppPermission.adjustStock) ?? false) ...[
              const SizedBox(height: AppDimensions.space14),
              _LowStockBanner(low: ref.watch(lowStockProvider)),
            ],
            const SizedBox(height: AppDimensions.space20),
            // Tablet (>=900dp) splits top-products + recent-orders into two
            // columns; phone stays single-column. Header + stats stay full
            // width on both.
            LayoutBuilder(
              builder: (context, constraints) {
                final isTablet =
                    constraints.maxWidth >= AppDimensions.tabletWidth;
                final lower = isTablet
                    ? <Widget>[
                        Expanded(
                          child: _topProductsSection(
                            context,
                            l10n,
                            topProducts,
                          ),
                        ),
                        const SizedBox(width: AppDimensions.space20),
                        Expanded(
                          child: _recentOrdersSection(context, l10n, orders),
                        ),
                      ]
                    : <Widget>[
                        _topProductsSection(context, l10n, topProducts),
                        const SizedBox(height: AppDimensions.space20),
                        _recentOrdersSection(context, l10n, orders),
                      ];
                return isTablet
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: lower,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: lower,
                      );
              },
            ),
            const SizedBox(height: AppDimensions.space16),
          ],
        ),
      ),
    );
  }

  Widget _statsRow(
    BuildContext context,
    AppLocalizations l10n,
    ({int revenue, int count, int itemsSold}) data,
  ) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: _BigStat(
              label: l10n.dashboardRevenue,
              value: MoneyFormatter.format(data.revenue),
              icon: Icons.payments_rounded,
            ),
          ),
          const SizedBox(width: AppDimensions.space10),
          Expanded(
            child: Column(
              children: [
                _SmallStat(
                  label: l10n.dashboardOrders,
                  value: '${data.count}',
                  icon: Icons.receipt_long_rounded,
                ),
                const SizedBox(height: AppDimensions.space10),
                _SmallStat(
                  label: l10n.dashboardAvgOrder,
                  value: MoneyFormatter.compact(
                    data.count > 0 ? data.revenue ~/ data.count : 0,
                  ),
                  icon: Icons.trending_up_rounded,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topProductsSection(
    BuildContext context,
    AppLocalizations l10n,
    AsyncValue<List<({String name, String? iconKey, int qty, int revenue})>>
    topProducts,
  ) {
    final design = context.design;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: l10n.dashboardTopProducts,
          trailing: Text(
            l10n.dashboardThisWeek,
            style: TextStyle(color: design.textMedium, fontSize: 12),
          ),
        ),
        const SizedBox(height: AppDimensions.space10),
        topProducts.when<Widget>(
          loading: () =>
              SizedBox(height: 68, child: LoadingIndicator.skeleton(lines: 3)),
          error: (e, _) => Text('$e'),
          data: (list) {
            if (list.isEmpty) {
              return _EmptyInline(label: l10n.dashboardNoSales);
            }
            final max = list.first.qty;
            return Column(
              children: list.asMap().entries.map((entry) {
                final p = entry.value;
                final ratio = max == 0 ? 0.0 : p.qty / max;
                return Padding(
                  padding: const EdgeInsets.only(bottom: AppDimensions.space10),
                  child: _TopProductBar(
                    iconKey: p.iconKey,
                    name: p.name,
                    qty: p.qty,
                    revenue: p.revenue,
                    ratio: ratio,
                    itemsLabel: l10n.dashboardItemsSold,
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _recentOrdersSection(
    BuildContext context,
    AppLocalizations l10n,
    AsyncValue<List<Order>> orders,
  ) {
    final design = context.design;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: l10n.dashboardRecentOrders,
          trailing: GestureDetector(
            onTap: () => context.go('/orders'),
            child: Text(
              l10n.dashboardViewAll,
              style: TextStyle(
                color: design.primary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppDimensions.space10),
        orders.when<Widget>(
          loading: () =>
              SizedBox(height: 68, child: LoadingIndicator.skeleton(lines: 3)),
          error: (e, _) => Text('$e'),
          data: (list) {
            if (list.isEmpty) {
              return _EmptyInline(label: l10n.dashboardNoSales);
            }
            // Five rows barely filled a phone and left most of a desktop
            // window empty, which read as "there is nothing here" next to a
            // seven-day sales history. Show more where there is room.
            final take =
                MediaQuery.sizeOf(context).width >= AppDimensions.tabletWidth
                ? 9
                : 5;
            return Column(
              children: list
                  .take(take)
                  .map(
                    (o) => Padding(
                      padding: const EdgeInsets.only(
                        bottom: AppDimensions.space8,
                      ),
                      child: _RecentOrderTile(order: o),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}

/// "Three items running low" with a way to act on it.
///
/// Collapses to nothing when the shelves are fine. A permanent panel reading
/// "0 low" is a panel the eye learns to skip, and the one morning it says 4
/// is the morning it gets skipped too.
class _LowStockBanner extends StatelessWidget {
  const _LowStockBanner({required this.low});
  final AsyncValue<List<Product>> low;

  @override
  Widget build(BuildContext context) {
    final items = low.valueOrNull ?? const <Product>[];
    if (items.isEmpty) return const SizedBox.shrink();

    final design = context.design;
    final l10n = context.l10n;
    final outOfStock = items.where((p) => p.isOutOfStock).length;
    final accent = outOfStock > 0 ? design.error : design.warning;

    return GlassCard.solid(
      onTap: () => context.push('/inventory'),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: AppDimensions.radiusMd,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.warning_amber_rounded, color: accent, size: 20),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${items.length} · ${l10n.inventoryLowStock}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: design.textHigh,
                  ),
                ),
                Text(
                  // Names them, up to three. "3 running low" makes the owner
                  // open a screen to find out which; the names often make the
                  // decision on the spot.
                  items.take(3).map((p) => p.name).join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: design.textMedium),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: design.textLow),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.trailing});
  final String title;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            title,
            style: TextStyle(
              color: design.textHigh,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        trailing,
      ],
    );
  }
}

/// Hero greeting card. Glass shell with a `design.primary`-tinted gradient
/// overlay painted over the glass tint; `design.onPrimary` text keeps contrast
/// on every brand.
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.greeting, required this.storeName});
  final String greeting;
  final String storeName;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    // Neutral, not a brand-filled banner. A greeting carries no data a cashier
    // acts on, so it has no claim on the loudest colour on the screen — that
    // belongs to the primary action and to money. The brand stays present as
    // the icon.
    return GlassCard.solid(
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.all(AppDimensions.space16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      greeting,
                      style: TextStyle(
                        color: design.textHigh,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppDimensions.space4),
                    Text(
                      storeName,
                      style: TextStyle(
                        color: design.textMedium,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppDimensions.space8),
              Icon(Icons.bar_chart_rounded, size: 32, color: design.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  const _BigStat({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    // Neutral card, brand only on the icon. The number is the subject, so it
    // gets the contrast; a filled brand tile made three equal blocks of colour
    // shout at once and left the figures competing with their own background.
    return GlassCard.solid(
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.all(AppDimensions.space14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: design.primary),
              const Spacer(),
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
              const SizedBox(height: AppDimensions.space2),
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
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallStat extends StatelessWidget {
  const _SmallStat({
    required this.label,
    required this.value,
    required this.icon,
  });
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      radius: BorderRadius.circular(AppDimensions.radius14),
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimensions.space10,
            vertical: AppDimensions.space10,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: design.primary),
                  const SizedBox(width: AppDimensions.space4),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: design.textHigh,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppDimensions.space2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: design.textMedium,
                  fontWeight: FontWeight.w500,
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

class _TopProductBar extends StatelessWidget {
  const _TopProductBar({
    required this.iconKey,
    required this.name,
    required this.qty,
    required this.revenue,
    required this.ratio,
    required this.itemsLabel,
  });
  final String? iconKey;
  final String name;
  final int qty;
  final int revenue;
  final double ratio;
  final String itemsLabel;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space12,
        vertical: AppDimensions.space10,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: design.primaryContainer,
              borderRadius: BorderRadius.circular(AppDimensions.radius8),
            ),
            alignment: Alignment.center,
            child: Icon(
              iconFromKey(iconKey),
              size: 18,
              color: design.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: AppDimensions.space10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: design.textHigh,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppDimensions.space8),
                    Text(
                      '$qty $itemsLabel',
                      style: TextStyle(
                        fontSize: 11,
                        color: design.textMedium,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppDimensions.space6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppDimensions.radius4),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 6,
                    backgroundColor: design.surfaceOverlay,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppDimensions.space10),
          Text(
            MoneyFormatter.compact(revenue),
            style: TextStyle(
              fontSize: 12,
              color: design.primary,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentOrderTile extends StatelessWidget {
  const _RecentOrderTile({required this.order});
  final Order order;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      // `push`, not `go`. `/orders/:id` lives outside the ShellRoute, so `go`
      // replaced the whole stack: the detail page opened with no back button
      // and no nav, stranding the user (browser Back is the only way out on
      // web, and on desktop/tablet there is none). Same bug aab9708 fixed for
      // the orders list, missed on this path. The "View all" tap above stays
      // `go` — that one is a tab switch inside the shell.
      onTap: () => context.push('/orders/${order.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space12,
        vertical: AppDimensions.space10,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  order.number,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: design.textHigh,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  DateFormatter.time(order.createdAt),
                  style: TextStyle(fontSize: 11, color: design.textMedium),
                ),
              ],
            ),
          ),
          Text(
            MoneyFormatter.format(order.total),
            style: TextStyle(
              fontSize: 13,
              color: design.primary,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyInline extends StatelessWidget {
  const _EmptyInline({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      child: Center(
        child: Text(
          label,
          style: TextStyle(color: design.textMedium, fontSize: 13),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
