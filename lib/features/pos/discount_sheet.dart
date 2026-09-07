import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/authorize_sheet.dart';
import '../../core/auth/permissions.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../data/models/promo.dart';
import '../../providers/cart_provider.dart';
import '../../providers/promo_provider.dart';
import '../../providers/settings_provider.dart';
import '../promos/promo_management_page.dart' show promoValueLabel;

/// Picks the discount for the current cart.
///
/// Two routes to the same field, split by who is trusted with what. A promo
/// the owner configured needs nobody's approval — the decision was already
/// made. A free-form number is the one a cashier could quietly hand to a
/// friend, so it costs a manager PIN and keeps that manager's name.
class DiscountSheet extends ConsumerStatefulWidget {
  const DiscountSheet({super.key});

  @override
  ConsumerState<DiscountSheet> createState() => _DiscountSheetState();
}

class _DiscountSheetState extends ConsumerState<DiscountSheet> {
  final _valueCtrl = TextEditingController();
  bool _asPercent = true;
  bool _busy = false;

  @override
  void dispose() {
    _valueCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final cart = ref.watch(cartProvider);
    final promos = ref.watch(activePromosProvider).valueOrNull ?? const <Promo>[];
    final settings = ref.watch(settingsProvider).valueOrNull;
    final canDiscountFreely =
        settings?.can(AppPermission.applyManualDiscount) ?? false;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppDimensions.space16,
          right: AppDimensions.space16,
          top: AppDimensions.space8,
          bottom:
              MediaQuery.of(context).viewInsets.bottom + AppDimensions.space16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  l10n.posDiscountTitle,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: design.textHigh,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.close_rounded, color: design.textMedium),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space8),

            if (cart.discountSource != DiscountSource.none) ...[
              GlassCard.solid(
                tint: design.primary,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            cart.discountLabel ?? l10n.posDiscountManual,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: design.onPrimary,
                            ),
                          ),
                          Text(
                            '- ${MoneyFormatter.format(cart.discountAmount)}'
                            '${cart.discountAuthorizedBy == null ? '' : ' · ${l10n.posDiscountApprovedBy(cart.discountAuthorizedBy!)}'}',
                            style: TextStyle(
                              fontSize: 12,
                              color: design.onPrimary.withValues(
                                alpha: 0.8,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        ref.read(cartProvider.notifier).clearDiscount();
                        Navigator.of(context).pop();
                      },
                      // Sitting on a primary fill, so the label follows the
                      // fill's foreground. A TextButton defaults to
                      // `colorScheme.primary`, which here is the colour it is
                      // standing on.
                      style: TextButton.styleFrom(
                        foregroundColor: design.onPrimary,
                      ),
                      child: Text(l10n.posDiscountRemove),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppDimensions.space16),
            ],

            Text(
              l10n.promosTitle,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: design.textMedium,
              ),
            ),
            const SizedBox(height: 6),
            if (promos.isEmpty)
              Text(
                l10n.promoEmptyHint,
                style: TextStyle(fontSize: 12, color: design.textLow),
              )
            else
              for (final p in promos)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PromoOption(
                    promo: p,
                    subtotal: cart.subtotal,
                    onTap: () {
                      ref.read(cartProvider.notifier).applyPromo(p);
                      Navigator.of(context).pop();
                    },
                  ),
                ),

            const SizedBox(height: AppDimensions.space16),
            Row(
              children: [
                Text(
                  l10n.posDiscountManual,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: design.textMedium,
                  ),
                ),
                if (!canDiscountFreely) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.lock_outline_rounded, size: 13, color: design.textLow),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    selected: _asPercent,
                    onSelected: (_) => setState(() => _asPercent = true),
                    label: Text(l10n.posDiscountPercent),
                  ),
                ),
                const SizedBox(width: AppDimensions.space8),
                Expanded(
                  child: ChoiceChip(
                    selected: !_asPercent,
                    onSelected: (_) => setState(() => _asPercent = false),
                    label: Text(l10n.posDiscountAmount),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space10),
            GlassTextField(
              controller: _valueCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              hint: _asPercent ? '10' : '5000',
              prefixText: _asPercent ? null : '${settings?.currency ?? 'Rp'} ',
              onChanged: (_) => setState(() {}),
            ),
            if (!canDiscountFreely)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  l10n.posDiscountLocked,
                  style: TextStyle(fontSize: 11, color: design.textLow),
                ),
              ),
            const SizedBox(height: AppDimensions.space16),
            FilledButton(
              onPressed: _busy || (int.tryParse(_valueCtrl.text) ?? 0) <= 0
                  ? null
                  : _applyManual,
              child: Text(l10n.posDiscountTitle),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyManual() async {
    final l10n = context.l10n;
    final value = int.tryParse(_valueCtrl.text) ?? 0;
    if (value <= 0) return;

    final settings = ref.read(settingsProvider).valueOrNull;
    String approver;
    if (settings?.can(AppPermission.applyManualDiscount) == true) {
      approver = settings!.cashierName;
    } else {
      setState(() => _busy = true);
      final employee = await requestAuthorization(
        context,
        permission: AppPermission.applyManualDiscount,
        reason: l10n.authorizeReasonDiscount,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      if (employee == null) return;
      approver = employee.name;
    }

    ref
        .read(cartProvider.notifier)
        .applyManualDiscount(
          authorizedBy: approver,
          percent: _asPercent ? value : 0,
          amount: _asPercent ? 0 : value,
        );
    if (mounted) Navigator.of(context).pop();
  }
}

class _PromoOption extends StatelessWidget {
  const _PromoOption({
    required this.promo,
    required this.subtotal,
    required this.onTap,
  });

  final Promo promo;
  final int subtotal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final eligible = promo.isEligible(subtotal);

    return Opacity(
      // Shown but disabled rather than hidden: "Hemat Rp 10.000 — minimum
      // Rp 75.000" tells the cashier something they can act on (upsell), where
      // an absent row just looks like the promo does not exist.
      opacity: eligible ? 1 : 0.5,
      child: GlassCard.solid(
        onTap: eligible ? onTap : null,
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimensions.space14,
          vertical: AppDimensions.space12,
        ),
        child: Row(
          children: [
            Icon(
              promo.kind == PromoKind.percent
                  ? Icons.percent_rounded
                  : Icons.local_offer_rounded,
              size: 18,
              color: design.primary,
            ),
            const SizedBox(width: AppDimensions.space10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    promo.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: design.textHigh,
                    ),
                  ),
                  Text(
                    eligible
                        ? promoValueLabel(promo)
                        : l10n.promoRequiresMin(
                            MoneyFormatter.format(promo.minSpend),
                          ),
                    style: TextStyle(fontSize: 12, color: design.textMedium),
                  ),
                ],
              ),
            ),
            if (eligible)
              Text(
                '- ${MoneyFormatter.format(promo.discountFor(subtotal))}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: design.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
