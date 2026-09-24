import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../data/device/bill_coordinator.dart';
import '../../data/models/bill.dart';
import '../../providers/bill_provider.dart';
import 'bill_ui.dart';

/// Every open bill this till can act on (paritas F4): its own — tap to edit —
/// the ones it parked, and on an activated till the other tills' bills from
/// the server's board, where a parked one can be taken over.
///
/// A bill held by another till is shown, never opened for editing: only its
/// owner may change it, and the way to move it is that till parking it.
class OpenBillsSheet extends ConsumerWidget {
  const OpenBillsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final local = ref.watch(openBillsProvider);
    final connected = BillCoordinator.current != null;
    final board = connected ? ref.watch(billBoardProvider) : null;
    final localIds = {
      for (final b in local.valueOrNull ?? const <Bill>[]) b.id,
    };

    final others = [
      for (final b in board?.valueOrNull?.bills ?? const <RemoteBillSummary>[])
        if (!b.ownedByThisDevice && !localIds.contains(b.id)) b,
      // A bill this till parked is on the board as parked, and is listed
      // under this till already.
    ];

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
                  l10n.billOpenBills,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: design.textHigh,
                  ),
                ),
                const Spacer(),
                if (connected)
                  IconButton(
                    onPressed: () => ref.invalidate(billBoardProvider),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  _Heading(l10n.billThisTill),
                  ...local.when(
                    loading: () => const [
                      Padding(
                        padding: EdgeInsets.all(AppDimensions.space16),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ],
                    error: (e, _) => [Text('$e')],
                    data: (bills) => bills.isEmpty
                        ? [
                            EmptyState(
                              icon: Icons.receipt_long_rounded,
                              title: l10n.billNoOpenBills,
                            ),
                          ]
                        : [for (final b in bills) _LocalBillTile(bill: b)],
                  ),
                  if (connected) ...[
                    _Heading(l10n.billOtherTills),
                    if (board!.valueOrNull?.fromCache == true)
                      _Notice(
                        l10n.billBoardCached(
                          TimeOfDay.fromDateTime(
                            board.valueOrNull!.fetchedAt,
                          ).format(context),
                        ),
                      ),
                    if (board.hasError && board.valueOrNull == null)
                      _Notice(l10n.billBoardUnavailable),
                    if (board.isLoading && board.valueOrNull == null)
                      const Padding(
                        padding: EdgeInsets.all(AppDimensions.space16),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (board.valueOrNull != null && others.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(AppDimensions.space12),
                        child: Text(
                          l10n.billNoOpenBills,
                          style: TextStyle(color: design.textMedium),
                        ),
                      ),
                    for (final b in others)
                      _RemoteBillTile(
                        bill: b,
                        fromCache: board.valueOrNull?.fromCache ?? true,
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(
      top: AppDimensions.space12,
      bottom: AppDimensions.space8,
    ),
    child: Text(
      text,
      style: TextStyle(
        color: context.design.textMedium,
        fontWeight: FontWeight.w700,
        fontSize: 13,
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppDimensions.space8),
    child: Row(
      children: [
        Icon(Icons.cloud_off_rounded, size: 16, color: context.design.warning),
        const SizedBox(width: AppDimensions.space8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: context.design.textMedium),
          ),
        ),
      ],
    ),
  );
}

class _LocalBillTile extends ConsumerWidget {
  const _LocalBillTile({required this.bill});
  final Bill bill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final parked = bill.ownership == BillOwnership.parked;
    final active = bill.dispatches.where((d) => d.status.isActive).length;
    final connected = BillCoordinator.current != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimensions.space8),
      child: GlassCard.solid(
        radius: AppDimensions.radiusMd,
        padding: const EdgeInsets.all(AppDimensions.space12),
        onTap: parked
            ? null
            : () async {
                final ok = await runBillAction(
                  context,
                  () => openBillInCart(read: ref.read, billId: bill.id),
                );
                if (ok && context.mounted) Navigator.of(context).maybePop();
              },
        child: Row(
          children: [
            Icon(
              parked ? Icons.local_parking_rounded : Icons.receipt_long_rounded,
              color: parked ? design.textMedium : design.primary,
            ),
            const SizedBox(width: AppDimensions.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bill.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: design.textHigh,
                    ),
                  ),
                  Text(
                    [
                      bill.number,
                      l10n.billItems(bill.itemCount),
                      if (active > 0) l10n.billLineInKitchen,
                      if (parked) l10n.billParkedWaiting,
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: design.textMedium),
                  ),
                ],
              ),
            ),
            Text(
              MoneyFormatter.format(bill.subtotal),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: design.textHigh,
              ),
            ),
            if (parked && connected)
              Padding(
                padding: const EdgeInsets.only(left: AppDimensions.space8),
                child: FilledButton.tonal(
                  onPressed: () async {
                    final ok = await runBillAction(
                      context,
                      () => claimBill(
                        read: ref.read,
                        invalidate: ref.invalidate,
                        billId: bill.id,
                      ),
                      success: l10n.billClaimed(bill.number),
                    );
                    if (ok && context.mounted) Navigator.of(context).maybePop();
                  },
                  child: Text(l10n.billClaim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RemoteBillTile extends ConsumerWidget {
  const _RemoteBillTile({required this.bill, required this.fromCache});
  final RemoteBillSummary bill;
  final bool fromCache;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimensions.space8),
      child: GlassCard.solid(
        radius: AppDimensions.radiusMd,
        padding: const EdgeInsets.all(AppDimensions.space12),
        child: Row(
          children: [
            Icon(
              bill.parked
                  ? Icons.local_parking_rounded
                  : Icons.point_of_sale_rounded,
              color: design.textMedium,
            ),
            const SizedBox(width: AppDimensions.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bill.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: design.textHigh,
                    ),
                  ),
                  Text(
                    [
                      bill.number,
                      l10n.billItems(bill.lineCount),
                      bill.parked
                          ? l10n.billParkedWaiting
                          : l10n.billHeldBy(bill.ownerRegisterName ?? '—'),
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: design.textMedium),
                  ),
                ],
              ),
            ),
            Text(
              MoneyFormatter.format(bill.subtotal),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: design.textHigh,
              ),
            ),
            // Taking over needs the live server answer: a stale board could
            // show as parked a bill another till has since claimed.
            if (bill.parked && !fromCache)
              Padding(
                padding: const EdgeInsets.only(left: AppDimensions.space8),
                child: FilledButton.tonal(
                  onPressed: () async {
                    final ok = await runBillAction(
                      context,
                      () => claimBill(
                        read: ref.read,
                        invalidate: ref.invalidate,
                        billId: bill.id,
                      ),
                      success: l10n.billClaimed(bill.number),
                    );
                    if (ok && context.mounted) Navigator.of(context).maybePop();
                  },
                  child: Text(l10n.billClaim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
