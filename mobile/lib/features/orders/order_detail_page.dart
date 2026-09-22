import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/authorize_sheet.dart';
import '../../core/auth/permissions.dart';
import '../../core/localization/l10n.dart';
import '../../core/print/print_receipt.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../core/widgets/status_badge.dart';
import '../../data/models/enums.dart';
import '../../data/models/order.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/catalog_provider.dart';
import '../../providers/order_provider.dart';
import '../../providers/settings_provider.dart';
import '../../core/widgets/app_snack_bar.dart';

class OrderDetailPage extends ConsumerWidget {
  const OrderDetailPage({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final detail = ref.watch(orderDetailProvider(orderId));

    // AppBackground wraps the whole Scaffold (not just the body) so the
    // frosted GlassAppBar has the brand substrate to blur behind it — the same
    // way MainShell provides the substrate behind the tab pages' app bars. When
    // it only wrapped the body, the app bar blurred empty space and read as a
    // flat, inconsistent bar (and clipped its title under the status bar).
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(title: l10n.ordersDetail),
        body: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(orderDetailProvider(orderId));
          },
          child: detail.when(
            loading: () => Center(child: LoadingIndicator.skeleton(lines: 6)),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline_rounded,
              title: l10n.commonError,
              subtitle: '$e',
            ),
            data: (order) {
              if (order == null) {
                return ListView(
                  children: [
                    EmptyState(
                      icon: Icons.search_off_rounded,
                      title: l10n.commonNoResults,
                    ),
                  ],
                );
              }
              return ListView(
                padding: const EdgeInsets.all(AppDimensions.space16),
                children: [
                  _headerCard(context, order),
                  const SizedBox(height: AppDimensions.space12),
                  _itemsCard(context, order),
                  const SizedBox(height: AppDimensions.space12),
                  _summaryCard(context, order),
                  const SizedBox(height: AppDimensions.space16),
                  _statusActions(context, ref, order),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _headerCard(BuildContext context, Order order) {
    final design = context.design;
    return GlassCard.solid(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                order.number,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: design.textHigh,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              StatusBadge(status: order.status),
            ],
          ),
          const SizedBox(height: AppDimensions.space4),
          Text(
            DateFormatter.dateTime(order.createdAt),
            style: TextStyle(color: design.textMedium),
          ),
          const SizedBox(height: AppDimensions.space8),
          Wrap(
            spacing: AppDimensions.space8,
            runSpacing: AppDimensions.space8,
            children: [
              _infoChip(
                context,
                Icons.person_outline_rounded,
                order.customerName?.isNotEmpty == true
                    ? order.customerName!
                    : '-',
              ),
              if (order.table != null)
                _infoChip(
                  context,
                  Icons.table_restaurant_rounded,
                  order.table!.tableName,
                ),
              // Who rang it up. With several cashiers sharing one till this is
              // the field the whole per-employee attribution exists for, and
              // it belonged on the order rather than only on the receipt.
              _infoChip(
                context,
                Icons.badge_outlined,
                order.cashierName,
              ),
              // And which till they were standing at. Two registers at one
              // counter are indistinguishable on a receipt otherwise, and this
              // is the field that says which drawer the money went into.
              // Absent on sales that predate registers rather than shown
              // blank — an empty chip reads as a missing value, not as history.
              if (order.posName?.isNotEmpty == true)
                _infoChip(
                  context,
                  Icons.point_of_sale_outlined,
                  order.posName!,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _itemsCard(BuildContext context, Order order) {
    final design = context.design;
    return GlassCard.solid(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final it in order.items) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Text(
                    '${it.quantity}x',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: design.textHigh,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          it.displayName,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: design.textHigh,
                          ),
                        ),
                        for (final m in it.modifiers)
                          Text(
                            m.priceDelta > 0
                                ? '${m.optionName} (+${MoneyFormatter.format(m.priceDelta)})'
                                : m.optionName,
                            style: TextStyle(
                              fontSize: 12,
                              color: design.textMedium,
                            ),
                          ),
                        if (it.note != null && it.note!.isNotEmpty)
                          Text(
                            it.note!,
                            style: TextStyle(
                              fontSize: 12,
                              color: design.textMedium,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    MoneyFormatter.format(it.lineTotal),
                    style: TextStyle(
                      color: design.primary,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryCard(BuildContext context, Order order) {
    final design = context.design;
    final l10n = context.l10n;
    return GlassCard(
      child: Column(
        children: [
          _row(
            l10n.posSubtotal,
            MoneyFormatter.format(order.subtotal),
            design.textMedium,
          ),
          if (order.discount > 0)
            _row(
              l10n.posDiscount,
              '- ${MoneyFormatter.format(order.discount)}',
              design.textMedium,
            ),
          if (order.serviceChargeAmount > 0)
            _row(
              l10n.posServiceCharge,
              MoneyFormatter.format(order.serviceChargeAmount),
              design.textMedium,
            ),
          if (order.tax > 0)
            _row(
              l10n.posTax,
              MoneyFormatter.format(order.tax),
              design.textMedium,
            ),
          const Divider(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.posTotal,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: design.textMedium,
                ),
              ),
              Text(
                MoneyFormatter.format(order.total),
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  color: design.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          // The audit trail. Shown on the order itself rather than buried in a
          // log, because the person who needs it — the owner, next morning —
          // is looking at the order, not at a log.
          if (order.authorizedBy != null) ...[
            const Divider(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  size: 16,
                  color: design.textMedium,
                ),
                const SizedBox(width: AppDimensions.space8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.ordersAuthorizedBy(order.authorizedBy!),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: design.textMedium,
                        ),
                      ),
                      if (order.voidReason?.isNotEmpty == true)
                        Text(
                          order.voidReason!,
                          style: TextStyle(
                            fontSize: 12,
                            color: design.textMedium,
                          ),
                        ),
                      if (order.refundedAmount != null)
                        Text(
                          l10n.ordersRefundedAmount(
                            MoneyFormatter.format(order.refundedAmount!),
                          ),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: design.warning,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String a, String b, Color valueColor) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(a, style: TextStyle(fontSize: 13, color: valueColor)),
        Text(
          b,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: valueColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );

  Widget _infoChip(BuildContext context, IconData icon, String label) {
    final design = context.design;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space10,
        vertical: AppDimensions.space4,
      ),
      decoration: BoxDecoration(
        color: design.glassTint.withValues(alpha: design.glassOpacity * 0.9),
        borderRadius: BorderRadius.circular(AppDimensions.radius20),
        border: Border.all(color: design.glassBorder.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: design.textMedium),
          const SizedBox(width: AppDimensions.space4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: design.textMedium,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusActions(BuildContext context, WidgetRef ref, Order order) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider).valueOrNull;

    // Reprinting is available for any order that was not struck out, not just
    // `paid` ones. Payment is taken at checkout, so every live order has a
    // receipt worth reprinting — and gating on `paid` meant that in practice
    // (orders are created as `preparing`) the button was almost never there.
    final printButton = order.status.returnsStock
        ? null
        : OutlinedButton.icon(
            onPressed: settings == null
                ? null
                : () => printOrderReceipt(context, order, settings),
            icon: const Icon(Icons.print_rounded),
            label: Text(l10n.ordersPrintReceipt),
          );

    // A voided or refunded order is finished: there is nothing left to
    // advance, and offering to void it again is how stock gets credited twice.
    if (order.status.returnsStock) return const SizedBox.shrink();

    if (order.readOnly) return Text(context.l10n.remoteReceiptReadOnly);
    final next = _nextStatus(order.status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (printButton != null) ...[
          printButton,
          const SizedBox(height: 8),
        ],
        if (next != null)
          FilledButton.icon(
            onPressed: () async {
              await ref
                  .read(ordersProvider(null).notifier)
                  .setStatus(order.id, next);
              ref.invalidate(orderDetailProvider(order.id));
            },
            icon: const Icon(Icons.arrow_forward_rounded),
            label: Text(l10n.ordersMarkAs(_statusLabel(next, l10n))),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: () => _settle(context, ref, order, refund: false),
                icon: Icon(
                  Icons.cancel_outlined,
                  color: Theme.of(context).colorScheme.error,
                ),
                label: Text(
                  l10n.ordersVoid,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                onPressed: () => _settle(context, ref, order, refund: true),
                icon: Icon(
                  Icons.undo_rounded,
                  color: context.design.warning,
                ),
                label: Text(
                  l10n.ordersRefund,
                  style: TextStyle(color: context.design.warning),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Voids or refunds [order], asking for approval when the signed-in person
  /// does not have it themselves.
  ///
  /// The manager path and the cashier path converge: both end with a named
  /// approver written onto the order. A manager approving their own action
  /// still puts their name on it — the record should not be able to tell
  /// whether someone reached over to type a PIN.
  Future<void> _settle(
    BuildContext context,
    WidgetRef ref,
    Order order, {
    required bool refund,
  }) async {
    final l10n = context.l10n;
    final settings = ref.read(settingsProvider).valueOrNull;
    final permission = refund
        ? AppPermission.refundOrder
        : AppPermission.voidOrder;

    String approverName;
    String approverId;
    if (settings?.can(permission) == true) {
      approverName = settings!.cashierName;
      approverId = settings.employeeId;
    } else {
      final approver = await requestAuthorization(
        context,
        permission: permission,
        reason: refund
            ? l10n.authorizeReasonRefund
            : l10n.authorizeReasonVoid,
      );
      if (approver == null) return;
      approverName = approver.name;
      approverId = approver.id;
    }

    if (!context.mounted) return;
    final reason = await _askReason(context, refund: refund);
    if (reason == null || !context.mounted) return;

    final notifier = ref.read(ordersProvider(null).notifier);
    if (refund) {
      await notifier.refundOrder(
        id: order.id,
        authorizedBy: approverName,
        authorizedById: approverId,
        reason: reason,
      );
    } else {
      await notifier.voidOrder(
        id: order.id,
        authorizedBy: approverName,
        authorizedById: approverId,
        reason: reason,
      );
    }

    // Stock came back and the money left the totals, so every screen that
    // counts either is stale.
    ref.invalidate(orderDetailProvider(order.id));
    ref.invalidate(dashboardSummaryProvider);
    ref.invalidate(topProductsProvider);
    ref.invalidate(productsProvider);
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      refund ? l10n.ordersRefunded : l10n.ordersVoided,
      success: true,
    );
  }

  /// Collects the reason. Required, not optional: a report that says three
  /// orders were voided and cannot say why is a report nobody can act on.
  Future<String?> _askReason(BuildContext context, {required bool refund}) {
    final l10n = context.l10n;
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(refund ? l10n.ordersRefundTitle : l10n.ordersVoidTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(refund ? l10n.ordersRefundBody : l10n.ordersVoidBody),
            const SizedBox(height: AppDimensions.space12),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: l10n.ordersVoidReason,
                hintText: l10n.ordersVoidReasonHint,
              ),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) Navigator.of(ctx).pop(v.trim());
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isEmpty) return;
              Navigator.of(ctx).pop(v);
            },
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  OrderStatus? _nextStatus(OrderStatus s) => switch (s) {
    OrderStatus.pending => OrderStatus.preparing,
    OrderStatus.preparing => OrderStatus.ready,
    OrderStatus.ready => OrderStatus.served,
    OrderStatus.served => OrderStatus.paid,
    _ => null,
  };

  String _statusLabel(OrderStatus s, AppLocalizations l10n) => switch (s) {
    OrderStatus.pending => l10n.orderStatusPending,
    OrderStatus.preparing => l10n.orderStatusPreparing,
    OrderStatus.ready => l10n.orderStatusReady,
    OrderStatus.served => l10n.orderStatusServed,
    OrderStatus.paid => l10n.orderStatusPaid,
    OrderStatus.cancelled => l10n.orderStatusCancelled,
    OrderStatus.refunded => l10n.orderStatusRefunded,
  };
}
