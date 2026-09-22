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
import '../../core/widgets/glass/glass_text_field.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../core/widgets/status_badge.dart';
import '../../data/models/enums.dart';
import '../../data/models/order.dart';
import '../../data/repositories/remote_order_repository.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/order_history_provider.dart';
import '../../providers/settings_provider.dart';

/// Transaction history: a period, a status, a receipt search, and one page at
/// a time.
///
/// The page never downloads the whole period up front. It asks for the next
/// slice when the list reaches its end, and every filter change starts again
/// from the first page — a cursor names a position in one ordering, so
/// carrying it across a filter change would page through a list nobody asked
/// for.
class OrdersPage extends ConsumerStatefulWidget {
  const OrdersPage({super.key});

  @override
  ConsumerState<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends ConsumerState<OrdersPage> {
  final _scroll = ScrollController();
  final _receipt = TextEditingController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _receipt.text = ref.read(orderHistoryFilterProvider).receipt;
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _receipt.dispose();
    super.dispose();
  }

  /// Asks for the next page while there is still a screen's worth to scroll,
  /// so the list grows before the person reaches the bottom of it.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 600) {
      ref.read(orderHistoryProvider.notifier).loadMore();
    }
  }

  void _setFilter(OrderHistoryFilter next) {
    ref.read(orderHistoryFilterProvider.notifier).state = next;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _pickRange() async {
    final filter = ref.read(orderHistoryFilterProvider);
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: DateTimeRange(start: filter.from, end: filter.to),
    );
    if (picked == null) return;
    _setFilter(filter.copyWith(from: picked.start, to: picked.end));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final history = ref.watch(orderHistoryProvider);
    final filter = ref.watch(orderHistoryFilterProvider);
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
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(orderHistoryProvider.notifier).refresh(),
        child: history.when(
          loading: () => ListView(
            padding: const EdgeInsets.all(AppDimensions.space16),
            children: [
              _Filters(
                filter: filter,
                receipt: _receipt,
                seesEverything: seesEverything,
                onChanged: _setFilter,
                onPickRange: _pickRange,
              ),
              const SizedBox(height: AppDimensions.space16),
              LoadingIndicator.skeleton(lines: 5),
            ],
          ),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: l10n.commonError,
            subtitle: '$e',
          ),
          data: (state) => _HistoryList(
            state: state,
            filter: filter,
            receipt: _receipt,
            scroll: _scroll,
            seesEverything: seesEverything,
            onChanged: _setFilter,
            onPickRange: _pickRange,
          ),
        ),
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.state,
    required this.filter,
    required this.receipt,
    required this.scroll,
    required this.seesEverything,
    required this.onChanged,
    required this.onPickRange,
  });

  final OrderHistoryState state;
  final OrderHistoryFilter filter;
  final TextEditingController receipt;
  final ScrollController scroll;
  final bool seesEverything;
  final ValueChanged<OrderHistoryFilter> onChanged;
  final VoidCallback onPickRange;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // One column on phones, two from the tablet breakpoint up. Rows rather
    // than a SliverGrid: every tile holds text whose height moves with the
    // user's textScaler, and a grid needs a fixed extent it would clip at.
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns =
            constraints.maxWidth >= AppDimensions.tabletWidth ? 2 : 1;
        // One row even when there is nothing, so the empty state has somewhere
        // to render and the filters above it stay on screen — an empty list
        // that also loses its filters gives nobody a way to widen the search.
        final rowCount = state.orders.isEmpty
            ? 1
            : (state.orders.length + columns - 1) ~/ columns;
        return ListView.builder(
          controller: scroll,
          padding: const EdgeInsets.all(AppDimensions.space16),
          // Header, notice, rows, footer.
          itemCount: rowCount + 3,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: AppDimensions.space12),
                child: _Filters(
                  filter: filter,
                  receipt: receipt,
                  seesEverything: seesEverything,
                  onChanged: onChanged,
                  onPickRange: onPickRange,
                ),
              );
            }
            if (index == 1) return _SourceNotice(state: state, filter: filter);
            if (index == rowCount + 2) return _Footer(state: state);

            final row = index - 2;
            if (state.orders.isEmpty) {
              return EmptyState(
                icon: Icons.receipt_long_rounded,
                title: state.rangeComplete
                    ? l10n.ordersEmpty
                    : l10n.historyOfflineMissing,
                subtitle: state.rangeComplete ? l10n.ordersEmptyHint : '',
              );
            }
            if (columns == 1) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _OrderTile(order: state.orders[row]),
              );
            }
            final first = row * columns;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var col = 0; col < columns; col++) ...[
                    if (col > 0) const SizedBox(width: 10),
                    Expanded(
                      // The last row can be short; an empty slot keeps the
                      // remaining tile at column width instead of letting it
                      // stretch across both.
                      child: first + col < state.orders.length
                          ? _OrderTile(order: state.orders[first + col])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.filter,
    required this.receipt,
    required this.seesEverything,
    required this.onChanged,
    required this.onPickRange,
  });

  final OrderHistoryFilter filter;
  final TextEditingController receipt;
  final bool seesEverything;
  final ValueChanged<OrderHistoryFilter> onChanged;
  final VoidCallback onPickRange;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              // Period presets. A cashier keeps them: the server holds them to
              // the current business day and says so, which is clearer than an
              // interface that pretends the choice does not exist.
              _chip(l10n.historyPeriodToday, filter.isToday, () {
                onChanged(filter.copyWith(from: today, to: today));
              }),
              _chip(
                l10n.historyPeriodYesterday,
                filter.from == today.subtract(const Duration(days: 1)) &&
                    filter.to == today.subtract(const Duration(days: 1)),
                () {
                  final d = today.subtract(const Duration(days: 1));
                  onChanged(filter.copyWith(from: d, to: d));
                },
              ),
              _chip(
                l10n.historyPeriodLast7,
                filter.from == today.subtract(const Duration(days: 6)) &&
                    filter.to == today,
                () => onChanged(
                  filter.copyWith(
                    from: today.subtract(const Duration(days: 6)),
                    to: today,
                  ),
                ),
              ),
              _chip(
                l10n.historyPeriodMonth,
                filter.from == DateTime(today.year, today.month, 1) &&
                    filter.to == today,
                () => onChanged(
                  filter.copyWith(
                    from: DateTime(today.year, today.month, 1),
                    to: today,
                  ),
                ),
              ),
              _chip(l10n.historyPeriodCustom, false, onPickRange),
            ],
          ),
        ),
        const SizedBox(height: AppDimensions.space8),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _statusChip(l10n.orderStatusAll, null),
              _statusChip(l10n.orderStatusPending, OrderStatus.pending),
              _statusChip(l10n.orderStatusPreparing, OrderStatus.preparing),
              _statusChip(l10n.orderStatusReady, OrderStatus.ready),
              _statusChip(l10n.orderStatusServed, OrderStatus.served),
              _statusChip(l10n.orderStatusPaid, OrderStatus.paid),
              _statusChip(l10n.orderStatusCancelled, OrderStatus.cancelled),
              _statusChip(l10n.orderStatusRefunded, OrderStatus.refunded),
            ],
          ),
        ),
        if (seesEverything) ...[
          const SizedBox(height: AppDimensions.space8),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _chip(l10n.historyScopeRegister, !filter.wholeOutlet, () {
                  onChanged(filter.copyWith(wholeOutlet: false));
                }),
                _chip(l10n.historyScopeOutlet, filter.wholeOutlet, () {
                  onChanged(filter.copyWith(wholeOutlet: true));
                }),
              ],
            ),
          ),
        ],
        const SizedBox(height: AppDimensions.space8),
        GlassTextField(
          controller: receipt,
          label: l10n.historyReceiptSearch,
          prefix: Icons.search_rounded,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) =>
              onChanged(filter.copyWith(receipt: value.trim())),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '${DateFormatter.day(filter.from)} – ${DateFormatter.day(filter.to)}',
                style: TextStyle(
                  fontSize: 12,
                  color: context.design.textMedium,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                receipt.clear();
                onChanged(OrderHistoryFilter.today());
              },
              child: Text(l10n.historyFilterReset),
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(right: AppDimensions.space8),
    child: GlassFilterChip(label: label, selected: selected, onTap: onTap),
  );

  Widget _statusChip(String label, OrderStatus? status) => _chip(
    label,
    filter.status == status,
    () => onChanged(filter.copyWith(status: status)),
  );
}

/// Says where the rows came from.
///
/// Silence here is the failure this exists to prevent: an offline list and a
/// live one look identical, and a period that was never downloaded looks
/// exactly like a period with no sales.
class _SourceNotice extends StatelessWidget {
  const _SourceNotice({required this.state, required this.filter});

  final OrderHistoryState state;
  final OrderHistoryFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final messages = <String>[
      if (state.localOnly) l10n.historyLocalOnly,
      if (!state.localOnly && state.fromCache)
        state.cachedAt == null
            ? l10n.historyOfflineMissing
            : l10n.historyOffline(DateFormatter.dateTime(state.cachedAt!)),
      if (!state.rangeComplete && state.cachedAt != null)
        l10n.historyRangeIncomplete,
      // The server narrows a scope it will not grant rather than refusing the
      // whole page, so the screen has to say which list this actually is.
      if (filter.wholeOutlet && state.scope == RemoteScope.register)
        l10n.historyScopeNarrowed,
    ];
    if (messages.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimensions.space12),
      child: GlassCard.solid(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final message in messages)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: design.textMedium,
                    ),
                    const SizedBox(width: AppDimensions.space8),
                    Expanded(
                      child: Text(
                        message,
                        style: TextStyle(
                          fontSize: 12,
                          color: design.textMedium,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.state});

  final OrderHistoryState state;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(AppDimensions.space16),
        child: Center(child: CircularProgressIndicator.adaptive()),
      );
    }
    if (state.hasMore || state.orders.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(AppDimensions.space16),
      child: Center(
        child: Text(
          l10n.historyEndOfList,
          style: TextStyle(fontSize: 12, color: context.design.textLow),
        ),
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
                  style: TextStyle(fontSize: 12, color: design.textMedium),
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
    // The day is worth showing now that the list can span a period: a receipt
    // number alone does not say which day it belongs to.
    return '${DateFormatter.day(order.createdAt)} '
        '${DateFormatter.time(order.createdAt)} · $typeLabel$table$customer';
  }
}
