import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../data/models/promo.dart';
import '../../providers/promo_provider.dart';

/// Promotions the owner configures once and any cashier can apply.
///
/// The counterpart to the manager-gated manual discount: a discount the owner
/// has already decided on does not need a manager standing at the till to
/// approve it a second time.
class PromoManagementPage extends ConsumerWidget {
  const PromoManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final promos = ref.watch(promosProvider);

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(title: l10n.promosTitle),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openForm(context, null),
          icon: const Icon(Icons.add_rounded),
          label: Text(l10n.promoAdd),
        ),
        body: promos.when(
          loading: () => const LoadingIndicator(),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: l10n.commonError,
            subtitle: '$e',
          ),
          data: (list) {
            if (list.isEmpty) {
              return EmptyState(
                icon: Icons.local_offer_outlined,
                title: l10n.promoEmpty,
                subtitle: l10n.promoEmptyHint,
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                AppDimensions.space16,
                AppDimensions.space16,
                AppDimensions.space16,
                96, // clears the FAB
              ),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _PromoTile(
                promo: list[i],
                onTap: () => _openForm(context, list[i]),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openForm(BuildContext context, Promo? existing) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => _PromoFormSheet(existing: existing),
    );
  }
}

/// The value of a promo, written the way a person would say it.
String promoValueLabel(Promo promo) => promo.kind == PromoKind.percent
    ? '${promo.value}%'
    : MoneyFormatter.format(promo.value);

class _PromoTile extends StatelessWidget {
  const _PromoTile({required this.promo, required this.onTap});

  final Promo promo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final accent = promo.active ? design.primary : design.textLow;

    return GlassCard.solid(
      onTap: onTap,
      padding: const EdgeInsets.all(AppDimensions.space12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: AppDimensions.radiusMd,
            ),
            alignment: Alignment.center,
            child: Icon(
              promo.kind == PromoKind.percent
                  ? Icons.percent_rounded
                  : Icons.local_offer_rounded,
              color: accent,
              size: 20,
            ),
          ),
          const SizedBox(width: AppDimensions.space12),
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
                    fontSize: 14,
                    color: design.textHigh,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  promo.minSpend > 0
                      ? '${promoValueLabel(promo)} · '
                            '${l10n.promoRequiresMin(MoneyFormatter.format(promo.minSpend))}'
                      : promoValueLabel(promo),
                  style: TextStyle(fontSize: 12, color: design.textMedium),
                ),
              ],
            ),
          ),
          Text(
            promo.active ? l10n.promoActive : l10n.promoInactive,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: promo.active ? design.success : design.textLow,
            ),
          ),
          const SizedBox(width: AppDimensions.space4),
          Icon(Icons.chevron_right_rounded, color: design.textLow),
        ],
      ),
    );
  }
}

class _PromoFormSheet extends ConsumerStatefulWidget {
  const _PromoFormSheet({this.existing});
  final Promo? existing;

  @override
  ConsumerState<_PromoFormSheet> createState() => _PromoFormSheetState();
}

class _PromoFormSheetState extends ConsumerState<_PromoFormSheet> {
  late final _nameCtrl = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final _valueCtrl = TextEditingController(
    text: widget.existing?.value.toString() ?? '',
  );
  late final _minCtrl = TextEditingController(
    text: (widget.existing?.minSpend ?? 0).toString(),
  );
  late PromoKind _kind = widget.existing?.kind ?? PromoKind.percent;
  late bool _active = widget.existing?.active ?? true;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _valueCtrl.dispose();
    _minCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final isEdit = widget.existing != null;

    return Padding(
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
                isEdit ? l10n.promoEdit : l10n.promoAdd,
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
          GlassTextField(
            controller: _nameCtrl,
            label: l10n.promoName,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: AppDimensions.space12),
          Row(
            children: [
              Expanded(
                child: ChoiceChip(
                  selected: _kind == PromoKind.percent,
                  onSelected: (_) => setState(() => _kind = PromoKind.percent),
                  label: Text(l10n.promoKindPercent),
                ),
              ),
              const SizedBox(width: AppDimensions.space8),
              Expanded(
                child: ChoiceChip(
                  selected: _kind == PromoKind.amount,
                  onSelected: (_) => setState(() => _kind = PromoKind.amount),
                  label: Text(l10n.promoKindAmount),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimensions.space12),
          GlassTextField(
            controller: _valueCtrl,
            label: l10n.promoValue,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            prefixText: _kind == PromoKind.amount ? 'Rp ' : null,
            suffix: _kind == PromoKind.percent
                ? Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      '%',
                      style: TextStyle(
                        color: design.textMedium,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: AppDimensions.space12),
          GlassTextField(
            controller: _minCtrl,
            label: l10n.promoMinSpend,
            hint: l10n.promoMinSpendHint,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            prefixText: 'Rp ',
          ),
          const SizedBox(height: AppDimensions.space12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _active ? l10n.promoActive : l10n.promoInactive,
                  style: TextStyle(color: design.textHigh, fontSize: 14),
                ),
              ),
              Switch(
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: AppDimensions.space10),
            Text(_error!, style: TextStyle(color: design.error, fontSize: 12)),
          ],
          const SizedBox(height: AppDimensions.space16),
          FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
          if (isEdit) ...[
            const SizedBox(height: AppDimensions.space8),
            TextButton.icon(
              onPressed: _confirmDelete,
              icon: Icon(Icons.delete_outline_rounded, color: design.error),
              label: Text(
                l10n.commonDelete,
                style: TextStyle(color: design.error),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final name = _nameCtrl.text.trim();
    final value = int.tryParse(_valueCtrl.text) ?? 0;

    if (name.isEmpty) {
      setState(() => _error = l10n.commonRequired);
      return;
    }
    // A promo worth nothing is a trap: it appears in the cashier's picker,
    // gets applied, and takes nothing off — which reads as a broken till
    // rather than as a misconfigured promo.
    if (value <= 0 || (_kind == PromoKind.percent && value > 100)) {
      setState(() => _error = l10n.commonRequired);
      return;
    }

    final existing = widget.existing;
    await ref
        .read(promosProvider.notifier)
        .upsert(
          Promo(
            id:
                existing?.id ??
                'promo_${DateTime.now().millisecondsSinceEpoch}',
            name: name,
            kind: _kind,
            value: value,
            minSpend: int.tryParse(_minCtrl.text) ?? 0,
            active: _active,
            sortOrder: existing?.sortOrder ?? 100,
          ),
        );
    ref.invalidate(activePromosProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.promoDeleteConfirm),
        content: Text(l10n.promoDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(promosProvider.notifier).delete(widget.existing!.id);
    ref.invalidate(activePromosProvider);
    if (mounted) Navigator.of(context).pop();
  }
}
