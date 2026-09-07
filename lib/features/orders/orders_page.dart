import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/permissions.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_chip.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../core/widgets/status_badge.dart';
import '../../data/models/enums.dart';
import '../../data/models/order.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/order_provider.dart';
import '../../providers/settings_provider.dart';

/// Order history page with status filter.
class OrdersPage extends ConsumerStatefulWidget {
  const OrdersPage({super.key});

  @override
  ConsumerState<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends ConsumerState<OrdersPage> {
  OrderStatus? _filter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(ordersProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final orders = ref.watch(ordersProvider(_filter));
    final seesEverything =
        ref.watch(settingsProvider).valueOrNull?.can(
          AppPermission.viewAllOrders,
        ) ??
        true;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(
        // Says which list this is. A cashier who sees four orders when the
        // shop did forty should know the list is scoped, not broken.
        title: seesEverything ? l10n.ordersTitle : l10n.ordersScopeOwnToday,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimensions.space16,
              0,
              AppDimensions.space16,
              AppDimensions.space12,
            ),
            child: _FilterBar(
              value: _filter,
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(ordersProvider);
        },
        child: orders.when(
          loading: () => Center(child: LoadingIndicator.skeleton(lines: 5)),
          error: (e, _) =>
              EmptyState(icon: Icons.error_outline_rounded, title: l10n.commonError, subtitle: '$e'),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: [
                  EmptyState(
                    icon: Icons.receipt_long_rounded,
                    title: l10n.ordersEmpty,
                    subtitle: l10n.ordersEmptyHint,
                  ),
                ],
              );
            }
            // One column on phones, two from the tablet breakpoint up. A single
            // column stretched across a desktop window gave each order a
            // 1200px-wide row holding one short line of text, which is most of
            // why the app read as thin on a wide screen; two columns double
            // what is on screen and cut the dead space.
            //
            // Rows rather than a SliverGrid on purpose: a grid needs a fixed
            // mainAxisExtent, and every tile here contains text whose height
            // moves with the user's textScaler (see CLAUDE.md rule 5). A Row of
            // Expanded tiles sizes to its own content, so it cannot clip.
            return LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    constraints.maxWidth >= AppDimensions.tabletWidth ? 2 : 1;
                final rowCount = (list.length + columns - 1) ~/ columns;
                return ListView.separated(
                  padding: const EdgeInsets.all(AppDimensions.space16),
                  itemCount: rowCount,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, row) {
                    if (columns == 1) return _OrderTile(order: list[row]);
                    final first = row * columns;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var col = 0; col < columns; col++) ...[
                          if (col > 0) const SizedBox(width: 10),
                          Expanded(
                            // The last row can be short; an empty slot keeps
                            // the remaining tile at column width instead of
                            // letting it stretch across both.
                            child: first + col < list.length
                                ? _OrderTile(order: list[first + col])
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.value, required this.onChanged});
  final OrderStatus? value;
  final ValueChanged<OrderStatus?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _item(l10n.orderStatusAll, () => onChanged(null), value == null),
          _item(l10n.orderStatusPending, () => onChanged(OrderStatus.pending),
              value == OrderStatus.pending),
          _item(l10n.orderStatusPreparing, () => onChanged(OrderStatus.preparing),
              value == OrderStatus.preparing),
          _item(l10n.orderStatusReady, () => onChanged(OrderStatus.ready),
              value == OrderStatus.ready),
          _item(l10n.orderStatusServed, () => onChanged(OrderStatus.served),
              value == OrderStatus.served),
          _item(l10n.orderStatusPaid, () => onChanged(OrderStatus.paid),
              value == OrderStatus.paid),
          _item(l10n.orderStatusCancelled, () => onChanged(OrderStatus.cancelled),
              value == OrderStatus.cancelled),
          _item(l10n.orderStatusRefunded, () => onChanged(OrderStatus.refunded),
              value == OrderStatus.refunded),
        ],
      ),
    );
  }

  Widget _item(String label, VoidCallback onTap, bool selected) {
    return Padding(
      padding: const EdgeInsets.only(right: AppDimensions.space8),
      child: GlassFilterChip(
        label: label,
        selected: selected,
        onTap: onTap,
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order});
  final Order order;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    return GlassCard.solid(
      // push (not go) so the detail stacks ON TOP of the Orders list: this
      // keeps the list underneath to pop back to, and lets GlassAppBar's
      // implied leading render a back button. `go` replaces the whole stack,
      // leaving the detail with nothing to return to and no back affordance.
      onTap: () => context.push('/orders/${order.id}'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: design.primaryContainer,
              borderRadius: BorderRadius.circular(AppDimensions.radius12),
            ),
            alignment: Alignment.center,
            child: Icon(
              _typeIcon(order.type),
              color: design.onPrimaryContainer,
              size: 22,
            ),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        order.number,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: design.textHigh,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppDimensions.space8),
                    StatusBadge(status: order.status, compact: true),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle(order, l10n),
                  style: TextStyle(
                    fontSize: 12,
                    color: design.textMedium,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  MoneyFormatter.format(order.total),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: design.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _typeIcon(OrderType t) => switch (t) {
    OrderType.dineIn => Icons.table_restaurant_rounded,
    OrderType.takeaway => Icons.shopping_bag_rounded,
    OrderType.delivery => Icons.two_wheeler_rounded,
  };

  String _subtitle(Order order, AppLocalizations l10n) {
    final typeLabel = switch (order.type) {
      OrderType.dineIn => l10n.posDineIn,
      OrderType.takeaway => l10n.posTakeaway,
      OrderType.delivery => l10n.posDelivery,
    };
    final customer = order.customerName?.isNotEmpty == true
        ? ' · ${order.customerName}'
        : '';
    final table = order.table != null ? ' · ${order.table!.tableName}' : '';
    return '${DateFormatter.time(order.createdAt)} · $typeLabel$table$customer';
  }
}
