import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/authorize_sheet.dart';
import '../../core/auth/permissions.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../data/models/bill.dart';
import '../../providers/bill_provider.dart';
import '../../providers/settings_provider.dart';
import 'bill_ui.dart';

/// Cancels an unpaid bill (paritas F4).
///
/// Every line the kitchen already received needs its own decision: it came
/// back to the shelf (restock), or it was made and thrown away (waste). Waste
/// moves nothing — the stock was consumed when the line was sent — so the
/// default is waste, which can never create stock out of nothing. Cancelling
/// needs someone allowed to void; their name goes on the bill.
class CancelBillSheet extends ConsumerStatefulWidget {
  const CancelBillSheet({super.key, required this.bill});
  final Bill bill;

  @override
  ConsumerState<CancelBillSheet> createState() => _CancelBillSheetState();
}

class _CancelBillSheetState extends ConsumerState<CancelBillSheet> {
  final _reason = TextEditingController();
  late final Map<String, bool> _restock = {
    for (final l in widget.bill.lines)
      if (l.dispatched) l.id: false,
  };
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final l10n = context.l10n;
    final settings = ref.read(settingsProvider).valueOrNull;
    String name;
    String? id;
    if (settings?.can(AppPermission.voidOrder) == true) {
      name = settings!.cashierName;
      id = settings.employeeId;
    } else {
      final approver = await requestAuthorization(
        context,
        permission: AppPermission.voidOrder,
        reason: l10n.authorizeReasonVoid,
      );
      if (approver == null) return;
      name = approver.name;
      id = approver.id;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final ok = await runBillAction(
      context,
      () => cancelBill(
        read: ref.read,
        invalidate: ref.invalidate,
        billId: widget.bill.id,
        reason: _reason.text.trim(),
        authorizedBy: name,
        authorizedById: id,
        restock: _restock,
      ),
      success: l10n.billCancelled,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final sent = [
      for (final l in widget.bill.lines)
        if (l.dispatched) l,
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppDimensions.space16,
          AppDimensions.space4,
          AppDimensions.space16,
          AppDimensions.space16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${l10n.billCancel} · ${widget.bill.number}',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: design.textHigh,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space8),
            GlassTextField(
              controller: _reason,
              label: l10n.billCancelReason,
              onChanged: (_) => setState(() {}),
            ),
            if (sent.isNotEmpty) ...[
              const SizedBox(height: AppDimensions.space16),
              Text(
                l10n.billCancelInKitchen,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: design.textMedium,
                ),
              ),
              const SizedBox(height: AppDimensions.space8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final line in sent)
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: AppDimensions.space8,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${line.quantity} × ${line.displayName}',
                                style: TextStyle(color: design.textHigh),
                              ),
                            ),
                            SegmentedButton<bool>(
                              segments: [
                                ButtonSegment(
                                  value: true,
                                  label: Text(l10n.billCancelRestock),
                                ),
                                ButtonSegment(
                                  value: false,
                                  label: Text(l10n.billCancelWaste),
                                ),
                              ],
                              selected: {_restock[line.id] ?? false},
                              onSelectionChanged: (v) =>
                                  setState(() => _restock[line.id] = v.first),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppDimensions.space16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: design.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: _busy || _reason.text.trim().isEmpty ? null : _confirm,
              icon: const Icon(Icons.cancel_outlined),
              label: Text(l10n.billCancel),
            ),
          ],
        ),
      ),
    );
  }
}
