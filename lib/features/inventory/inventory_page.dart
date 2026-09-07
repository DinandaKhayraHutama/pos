import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/icon_map.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../data/models/product.dart';
import '../../data/models/stock_movement.dart';
import '../../data/repositories/stock_repository.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/catalog_provider.dart';
import '../../providers/outlet_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/stock_provider.dart';
import '../../core/widgets/app_snack_bar.dart';

/// Stock control: what is running out, and the ledger of why.
///
/// Deliberately separate from the product form. Editing a product is a
/// catalogue decision ("we now sell this for 18k"); booking stock is an
/// operational one ("twelve arrived, two were dropped"), it happens far more
/// often, and it is a manager's job rather than the owner's. Putting them on
/// the same screen would mean a manager needs catalogue rights to count a
/// delivery.
class InventoryPage extends ConsumerWidget {
  const InventoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final products = ref.watch(productsProvider);
    final history = ref.watch(stockHistoryProvider(null));

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(title: l10n.inventoryTitle),
        body: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(productsProvider);
            ref.invalidate(stockHistoryProvider(null));
            ref.invalidate(lowStockProvider);
          },
          child: products.when(
            loading: () => Center(child: LoadingIndicator.skeleton(lines: 6)),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline_rounded,
              title: l10n.commonError,
              subtitle: '$e',
            ),
            data: (all) {
              final tracked = all.where((p) => p.tracksStock).toList()
                ..sort((a, b) => a.stock!.compareTo(b.stock!));
              final low = tracked
                  .where((p) => p.isLowStock || p.isOutOfStock)
                  .toList();

              return ListView(
                padding: const EdgeInsets.all(AppDimensions.space16),
                children: [
                  _SectionTitle(
                    icon: Icons.warning_amber_rounded,
                    text: l10n.inventoryLowStock,
                    trailing: low.isEmpty ? null : '${low.length}',
                  ),
                  const SizedBox(height: AppDimensions.space8),
                  if (low.isEmpty)
                    GlassCard.solid(
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_outline_rounded,
                            color: context.design.success,
                          ),
                          const SizedBox(width: AppDimensions.space12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.inventoryAllStocked,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: context.design.textHigh,
                                  ),
                                ),
                                Text(
                                  l10n.inventoryAllStockedHint,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.design.textMedium,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    for (final p in low)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _StockTile(
                          product: p,
                          onTap: () => _openAdjust(context, ref, p),
                        ),
                      ),

                  const SizedBox(height: AppDimensions.space20),
                  _SectionTitle(
                    icon: Icons.inventory_2_outlined,
                    text: l10n.productStock,
                    trailing: '${tracked.length}',
                  ),
                  const SizedBox(height: AppDimensions.space8),
                  if (tracked.isEmpty)
                    Text(
                      l10n.inventoryTrackedOnly,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.design.textMedium,
                      ),
                    )
                  else
                    for (final p in tracked)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _StockTile(
                          product: p,
                          onTap: () => _openAdjust(context, ref, p),
                        ),
                      ),

                  const SizedBox(height: AppDimensions.space20),
                  _SectionTitle(
                    icon: Icons.history_rounded,
                    text: l10n.inventoryHistory,
                  ),
                  const SizedBox(height: AppDimensions.space8),
                  history.when(
                    loading: () => LoadingIndicator.skeleton(lines: 3),
                    error: (e, _) => Text('$e'),
                    data: (rows) => rows.isEmpty
                        ? Text(
                            l10n.inventoryHistoryEmpty,
                            style: TextStyle(
                              fontSize: 12,
                              color: context.design.textMedium,
                            ),
                          )
                        : GlassCard.solid(
                            child: Column(
                              children: [
                                for (var i = 0; i < rows.length; i++) ...[
                                  if (i > 0) const Divider(height: 16),
                                  _MovementRow(movement: rows[i]),
                                ],
                              ],
                            ),
                          ),
                  ),
                  const SizedBox(height: AppDimensions.space20),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _openAdjust(BuildContext context, WidgetRef ref, Product product) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => _AdjustSheet(product: product),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.text, this.trailing});

  final IconData icon;
  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Row(
      children: [
        Icon(icon, size: 18, color: design.textMedium),
        const SizedBox(width: AppDimensions.space8),
        Text(
          text,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13,
            color: design.textHigh,
            letterSpacing: 0.2,
          ),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: design.textMedium,
            ),
          ),
        ],
      ],
    );
  }
}

class _StockTile extends StatelessWidget {
  const _StockTile({required this.product, required this.onTap});

  final Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final out = product.isOutOfStock;
    final low = product.isLowStock;
    final accent = out
        ? design.error
        : low
        ? design.warning
        : design.textMedium;

    return GlassCard.solid(
      onTap: onTap,
      padding: const EdgeInsets.all(AppDimensions.space12),
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
            child: Icon(iconFromKey(product.iconKey), size: 20, color: accent),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: design.textHigh,
                  ),
                ),
                Text(
                  product.sku?.isNotEmpty == true
                      ? product.sku!
                      : MoneyFormatter.format(product.price),
                  style: TextStyle(fontSize: 12, color: design.textMedium),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppDimensions.space8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${product.stock}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: accent,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (out)
                Text(
                  l10n.posOutOfStock,
                  style: TextStyle(fontSize: 10, color: design.error),
                )
              else if (low)
                Text(
                  l10n.inventoryLowStock,
                  style: TextStyle(fontSize: 10, color: design.warning),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.movement});

  final StockMovement movement;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final up = movement.isIncrease;
    return Row(
      children: [
        Icon(
          up ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
          size: 16,
          color: up ? design.success : design.textMedium,
        ),
        const SizedBox(width: AppDimensions.space10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                movement.productName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: design.textHigh,
                ),
              ),
              Text(
                '${stockReasonLabel(l10n, movement.reason)}'
                ' · ${DateFormatter.dateTime(movement.createdAt)}'
                '${movement.employeeName.isEmpty ? '' : ' · ${movement.employeeName}'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: design.textMedium),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppDimensions.space8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              // Signed and explicit: "+12" and "-2" read as a ledger, where a
              // bare "12" would need the arrow to be understood.
              '${up ? '+' : ''}${movement.delta}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: up ? design.success : design.textHigh,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              l10n.inventoryBalance(movement.balanceAfter),
              style: TextStyle(fontSize: 10, color: design.textLow),
            ),
          ],
        ),
      ],
    );
  }
}

/// Label for a movement reason. Public so the product form can reuse it.
String stockReasonLabel(AppLocalizations l10n, StockReason reason) =>
    switch (reason) {
      StockReason.sale => l10n.stockReasonSale,
      StockReason.voidReturn => l10n.stockReasonVoidReturn,
      StockReason.received => l10n.stockReasonReceived,
      StockReason.waste => l10n.stockReasonWaste,
      StockReason.correction => l10n.stockReasonCorrection,
      StockReason.opening => l10n.stockReasonOpening,
    };

class _AdjustSheet extends ConsumerStatefulWidget {
  const _AdjustSheet({required this.product});
  final Product product;

  @override
  ConsumerState<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends ConsumerState<_AdjustSheet> {
  final _qtyCtrl = TextEditingController(text: '1');
  final _noteCtrl = TextEditingController();
  StockReason _reason = StockReason.received;
  bool _busy = false;

  /// Whether this books goods in or out.
  ///
  /// Derived from the reason rather than asked separately: "Received" is
  /// always in and "Waste" is always out, so a direction toggle would only
  /// ever create the chance to contradict the reason. A recount is the one
  /// case that goes either way, so it gets its own toggle.
  bool get _isIncrease => switch (_reason) {
    StockReason.received => true,
    StockReason.waste => false,
    _ => _correctionUp,
  };
  bool _correctionUp = true;

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final qty = int.tryParse(_qtyCtrl.text) ?? 0;
    final current = widget.product.stock ?? 0;
    final next = (current + (_isIncrease ? qty : -qty)).clamp(0, 1 << 31);

    return Padding(
      padding: EdgeInsets.only(
        left: AppDimensions.space16,
        right: AppDimensions.space16,
        top: AppDimensions.space8,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppDimensions.space16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: design.textHigh,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.close_rounded, color: design.textMedium),
              ),
            ],
          ),
          Text(
            l10n.inventoryAdjust,
            style: TextStyle(color: design.textMedium, fontSize: 13),
          ),
          const SizedBox(height: AppDimensions.space16),

          // Current → next, shown live. The cashier is typing a delta but
          // thinking in balances, so the balance is what has to be on screen.
          GlassCard.solid(
            tint: design.primary,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$current',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: design.onPrimary.withValues(alpha: 0.6),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    color: design.onPrimary,
                  ),
                ),
                Text(
                  '$next',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    color: design.onPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppDimensions.space16),

          Text(
            l10n.inventoryReason,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: design.textMedium,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: AppDimensions.space8,
            runSpacing: AppDimensions.space8,
            children: [
              for (final r in StockReasonX.manual)
                ChoiceChip(
                  selected: _reason == r,
                  onSelected: (_) => setState(() => _reason = r),
                  label: Text(stockReasonLabel(l10n, r)),
                ),
            ],
          ),
          if (_reason == StockReason.correction) ...[
            const SizedBox(height: AppDimensions.space10),
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    selected: _correctionUp,
                    onSelected: (_) => setState(() => _correctionUp = true),
                    label: Text(l10n.inventoryIn),
                  ),
                ),
                const SizedBox(width: AppDimensions.space8),
                Expanded(
                  child: ChoiceChip(
                    selected: !_correctionUp,
                    onSelected: (_) => setState(() => _correctionUp = false),
                    label: Text(l10n.inventoryOut),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppDimensions.space12),
          GlassTextField(
            controller: _qtyCtrl,
            label: l10n.inventoryQuantity,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppDimensions.space12),
          GlassTextField(
            controller: _noteCtrl,
            label: l10n.inventoryNoteHint,
          ),
          const SizedBox(height: AppDimensions.space16),
          FilledButton.icon(
            onPressed: _busy || qty <= 0 ? null : _save,
            icon: Icon(
              _isIncrease
                  ? Icons.add_circle_outline_rounded
                  : Icons.remove_circle_outline_rounded,
            ),
            label: Text(_isIncrease ? l10n.inventoryIn : l10n.inventoryOut),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final qty = int.tryParse(_qtyCtrl.text) ?? 0;
    if (qty <= 0) return;
    setState(() => _busy = true);

    final settings = ref.read(settingsProvider).valueOrNull;
    // Books the delivery, waste or recount against the shelf in front of this
    // person, not the chain's. Without an outlet there is no shelf to move.
    final outletId = ref.read(activeOutletProvider).valueOrNull?.id;
    if (outletId == null) {
      setState(() => _busy = false);
      return;
    }
    try {
      final balance = await StockRepository.instance.adjust(
        outletId: outletId,
        productId: widget.product.id,
        delta: _isIncrease ? qty : -qty,
        reason: _reason,
        employeeId: settings?.employeeId ?? '',
        employeeName: settings?.cashierName ?? '',
        note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      );
      // Everything that reads a stock count is now stale: the sell grid, the
      // low-stock list and the ledger.
      ref.invalidate(productsProvider);
      ref.invalidate(lowStockProvider);
      ref.invalidate(stockHistoryProvider(null));
      ref.invalidate(stockHistoryProvider(widget.product.id));
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppSnackBar(context, l10n.inventoryAdjusted(balance), success: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showAppSnackBar(context, '$e', error: true);
    }
  }
}
