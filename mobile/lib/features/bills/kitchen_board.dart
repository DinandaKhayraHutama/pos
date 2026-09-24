import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../data/models/bill.dart';
import '../../data/repositories/bill_repository.dart';
import '../../providers/bill_provider.dart';
import '../../providers/device_sync_provider.dart';
import 'bill_ui.dart';

/// The kitchen board (paritas F4): every batch sent to the kitchen that is
/// not served yet, oldest first, with the one button that moves it on.
///
/// Kitchen progress is not payment progression: a paid bill's batch still
/// shows here until it is served, and moving it changes no money and no
/// stock. Only the till holding the bill moves its batches.
class KitchenBoard extends ConsumerWidget {
  const KitchenBoard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tickets = ref.watch(kitchenBoardProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(kitchenBoardProvider),
      child: tickets.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: l10n.commonError,
          subtitle: '$e',
        ),
        data: (all) => all.isEmpty
            ? ListView(
                children: [
                  EmptyState(
                    icon: Icons.soup_kitchen_rounded,
                    title: l10n.kitchenEmpty,
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.all(AppDimensions.space16),
                itemCount: all.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppDimensions.space10),
                itemBuilder: (context, i) => _Ticket(ticket: all[i]),
              ),
      ),
    );
  }
}

class _Ticket extends ConsumerWidget {
  const _Ticket({required this.ticket});
  final KitchenTicket ticket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final dispatch = ticket.dispatch;
    final next = dispatch.status.next;
    final advance = dispatchAdvanceLabel(l10n, dispatch.status);
    final owned = ticket.bill.ownership == BillOwnership.owned;
    final waited = DateTime.now().difference(dispatch.occurredAt).inMinutes;
    return GlassCard.solid(
      radius: AppDimensions.radiusMd,
      padding: const EdgeInsets.all(AppDimensions.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${ticket.bill.label} · ${ticket.bill.number}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: design.textHigh,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimensions.space8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: dispatch.status == DispatchStatus.ready
                      ? design.successContainer
                      : design.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${dispatchStatusLabel(l10n, dispatch.status)} · ${waited}m',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: dispatch.status == DispatchStatus.ready
                        ? design.success
                        : design.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            l10n.kitchenSentAt(
              TimeOfDay.fromDateTime(dispatch.occurredAt).format(context),
              dispatch.employeeName,
            ),
            style: TextStyle(fontSize: 12, color: design.textMedium),
          ),
          const SizedBox(height: AppDimensions.space8),
          for (final line in ticket.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${line.quantity} × ${line.displayName}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: design.textHigh,
                    ),
                  ),
                  if (line.modifiers.isNotEmpty)
                    Text(
                      line.modifiers.map((m) => m.optionName).join(', '),
                      style: TextStyle(fontSize: 12, color: design.textMedium),
                    ),
                  if (line.note?.isNotEmpty == true)
                    Text(
                      line.note!,
                      style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: design.primary,
                      ),
                    ),
                ],
              ),
            ),
          if (next != null && advance != null && owned) ...[
            const SizedBox(height: AppDimensions.space8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () async {
                  final ok = await runBillAction(
                    context,
                    () => BillRepository.instance.setDispatchStatus(
                      dispatch.id,
                      next,
                    ),
                  );
                  if (ok) {
                    ref.invalidate(kitchenBoardProvider);
                    ref.invalidate(openBillsProvider);
                    ref.read(deviceSyncControllerProvider)?.nudge();
                  }
                },
                icon: const Icon(Icons.arrow_forward_rounded),
                label: Text(advance),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
