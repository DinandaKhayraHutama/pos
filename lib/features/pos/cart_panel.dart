import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/glass/glass_stepper.dart';
import '../../core/widgets/product_thumbnail.dart';
import '../../core/widgets/segmented_selector.dart';
import '../../data/models/enums.dart';
import '../../data/models/modifier_group.dart';
import '../../data/models/modifier_option.dart';
import '../../data/models/product_variant.dart';
import '../../providers/cart_provider.dart';
import '../../providers/catalog_provider.dart';
import '../../providers/modifier_provider.dart';
import '../../providers/settings_provider.dart';
import 'discount_sheet.dart';
import 'modifier_picker_sheet.dart';
import 'table_picker_sheet.dart';
import 'variant_picker_sheet.dart';

/// Cart contents. On phone this lives inside a bottom sheet; on tablet it is
/// displayed as a permanent side panel.
class CartPanel extends ConsumerStatefulWidget {
  const CartPanel({
    super.key,
    required this.onCheckout,
    this.compact = false,
    this.scrollController,
  });

  final VoidCallback onCheckout;
  final bool compact;
  final ScrollController? scrollController;

  @override
  ConsumerState<CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends ConsumerState<CartPanel> {
  ScrollController? _ownedController;

  ScrollController get _scroll =>
      widget.scrollController ?? (_ownedController ??= ScrollController());

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final cart = ref.watch(cartProvider);
    final notifier = ref.read(cartProvider.notifier);
    final settings = ref.watch(settingsProvider).valueOrNull;

    if (cart.isEmpty) {
      return _EmptyCart(compact: widget.compact);
    }

    final pb1Rate = settings?.pb1Rate ?? 0;
    final serviceChargeRate = (settings?.serviceChargeEnabled ?? false)
        ? settings!.serviceChargeRate
        : 0.0;
    final total = cart.totalFor(
      pb1Rate: pb1Rate,
      serviceChargeRate: serviceChargeRate,
    );

    return Column(
      children: [
        if (widget.compact)
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(
                top: AppDimensions.space8,
                bottom: AppDimensions.space8,
              ),
              decoration: BoxDecoration(
                color: design.glassBorder.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppDimensions.space16,
            0,
            AppDimensions.space8,
            0,
          ),
          child: Row(
            children: [
              Text(
                l10n.posCart,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: design.textHigh,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: design.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${cart.itemCount}',
                  style: TextStyle(
                    color: design.onPrimaryContainer,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => notifier.clear(),
                icon: const Icon(Icons.delete_sweep_rounded),
                tooltip: l10n.posClearCart,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppDimensions.space16,
            AppDimensions.space6,
            AppDimensions.space16,
            0,
          ),
          child: SegmentedSelector<OrderType>(
            value: cart.type,
            onChanged: notifier.setType,
            segments: [
              Segment(
                value: OrderType.dineIn,
                label: l10n.posDineIn,
                icon: Icons.table_restaurant_rounded,
              ),
              Segment(
                value: OrderType.takeaway,
                label: l10n.posTakeaway,
                icon: Icons.shopping_bag_rounded,
              ),
              Segment(
                value: OrderType.delivery,
                label: l10n.posDelivery,
                icon: Icons.two_wheeler_rounded,
              ),
            ],
          ),
        ),
        // Dine-in without a floor plan is a normal way to run a warung: guests
        // sit wherever they like and the order is still eaten in. So the table
        // row follows the store's own setting, not the order type alone.
        if (cart.type == OrderType.dineIn &&
            settings?.tableServiceEnabled != false)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimensions.space16,
              AppDimensions.space10,
              AppDimensions.space16,
              0,
            ),
            child: _TableField(
              value: cart.table?.name ?? '',
              compact: widget.compact,
              onTap: () => _pickTable(context),
            ),
          ),
        Expanded(
          child: ListView.separated(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(
              AppDimensions.space16,
              AppDimensions.space12,
              AppDimensions.space16,
              AppDimensions.space12,
            ),
            itemCount: cart.lines.length,
            separatorBuilder: (_, _) =>
                const SizedBox(height: AppDimensions.space10),
            itemBuilder: (context, i) {
              final line = cart.lines[i];
              return _CartLineTile(
                line: line,
                // Keyed on the line, not the product: a Large and a Regular
                // of the same coffee are two lines, and stepping one must
                // not move the other. Modifiers have to come along too, or
                // stepping a line that carries any would compute a DIFFERENT
                // key (no modifiers) and silently fork into — or merge with
                // — the wrong line.
                onAdd: () => notifier.add(
                  line.product,
                  variant: line.variant,
                  modifiers: line.modifiers,
                ),
                onDec: () => notifier.decrement(line.key),
                onRemove: () => notifier.removeLine(line.key),
                onTap: () => _editLine(context, line),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppDimensions.space16,
            AppDimensions.space8,
            AppDimensions.space16,
            AppDimensions.space16,
          ),
          child: SafeArea(
            top: false,
            child: GlassCard.solid(
              padding: const EdgeInsets.all(AppDimensions.space14),
              child: _CartSummary(
                subtotal: cart.subtotal,
                discount: cart.discountAmount,
                discountLabel: cart.discountLabel,
                onDiscount: cart.isEmpty
                    ? null
                    : () => showGlassSheet<void>(
                        context: context,
                        builder: (_) => const DiscountSheet(),
                      ),
                serviceCharge: cart.serviceChargeFor(serviceChargeRate),
                tax: cart.pb1For(
                  pb1Rate: pb1Rate,
                  serviceChargeRate: serviceChargeRate,
                ),
                total: total,
                onCheckout: widget.onCheckout,
                checkoutLabel:
                    '${l10n.posCheckout} · ${MoneyFormatter.format(total)}',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickTable(BuildContext context) async {
    await showGlassSheet(
      context: context,
      builder: (_) => const TablePickerSheet(),
    );
  }

  /// Re-opens whichever pickers [line]'s product has, pre-filled with its
  /// current selections, and replaces the line if the cashier goes through
  /// with it. Closing either picker cancels the whole edit — same "back out
  /// leaves nothing changed" behaviour as adding a fresh line.
  Future<void> _editLine(BuildContext context, CartLine line) async {
    var variant = line.variant;
    final variants =
        (await ref.read(productVariantsProvider.future))[line.product.id] ??
        const [];
    if (!context.mounted) return;
    if (variants.isNotEmpty) {
      final chosen = await showGlassSheet<ProductVariant>(
        context: context,
        builder: (_) =>
            VariantPickerSheet(product: line.product, variants: variants),
      );
      if (chosen == null) return;
      variant = chosen;
    }

    var modifiers = line.modifiers;
    final groupsByProduct = await ref.read(
      productModifierGroupsProvider.future,
    );
    final optionsByGroup = await ref.read(
      modifierOptionsByGroupProvider.future,
    );
    // Same per-product narrowing as the sell grid's own picker — see
    // ModifierRepository's "Product option scope" section.
    final optionScopeByProduct = await ref.read(
      productModifierOptionScopeProvider.future,
    );
    final scopedOptionIds =
        optionScopeByProduct[line.product.id] ?? const <String>{};
    final groups = <ModifierGroupOffer>[
      for (final g
          in groupsByProduct[line.product.id] ?? const <ModifierGroup>[])
        (
          group: g,
          options: (optionsByGroup[g.id] ?? const <ModifierOption>[])
              .where((o) => o.active && scopedOptionIds.contains(o.id))
              .toList(),
        ),
    ];
    modifiers = selectionsForOffers(
      groups,
      modifiers.map((m) => m.option.id).toSet(),
    );
    if (groups.isNotEmpty) {
      if (!context.mounted) return;
      final chosen = await showGlassSheet<List<SelectedModifier>>(
        context: context,
        builder: (_) => ModifierPickerSheet(
          product: line.product,
          basePrice: line.product.price + (variant?.priceDelta ?? 0),
          groups: groups,
          initialSelections: modifiers,
        ),
      );
      if (chosen == null) return;
      modifiers = chosen;
    }

    if (!context.mounted) return;
    ref
        .read(cartProvider.notifier)
        .updateLineSelections(line.key, variant: variant, modifiers: modifiers);
  }
}

class _EmptyCart extends StatelessWidget {
  const _EmptyCart({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppDimensions.space28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: design.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.shopping_cart_outlined,
                size: 30,
                color: design.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: AppDimensions.space12),
            Text(
              l10n.posCartEmpty,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: design.textHigh,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.posCartEmptyHint,
              textAlign: TextAlign.center,
              style: TextStyle(color: design.textMedium, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _CartLineTile extends StatelessWidget {
  const _CartLineTile({
    required this.line,
    required this.onAdd,
    required this.onDec,
    required this.onRemove,
    required this.onTap,
  });

  final CartLine line;
  final VoidCallback onAdd;
  final VoidCallback onDec;
  final VoidCallback onRemove;

  /// Re-opens the variant/modifier pickers, pre-filled, to change this
  /// line's selections. The only tap target on the tile besides the
  /// stepper — the row itself carries no other action to collide with.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final product = line.product;
    final qty = line.quantity;
    return Dismissible(
      key: ValueKey('${line.key}#$qty'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onRemove(),
      background: Container(
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: design.errorContainer,
          borderRadius: AppDimensions.radiusMd,
        ),
        padding: const EdgeInsets.only(right: 20),
        child: Icon(
          Icons.delete_outline_rounded,
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
      child: GlassCard.solid(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimensions.space10,
          vertical: AppDimensions.space10,
        ),
        radius: AppDimensions.radiusMd,
        child: Row(
          children: [
            ProductThumbnail(
              product: product,
              size: 44,
              borderRadius: AppDimensions.radiusSm,
            ),
            const SizedBox(width: AppDimensions.space10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.displayName,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: design.textHigh,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (line.modifiers.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(
                      line.modifiers.map((m) => m.option.name).join(', '),
                      style: TextStyle(fontSize: 11, color: design.textMedium),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    // The line's own unit price, which includes the variant
                    // delta — `product.price * qty` would quietly under-report
                    // a Large.
                    MoneyFormatter.format(line.lineTotal),
                    style: TextStyle(
                      fontSize: 12,
                      color: design.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              // Compact inline stepper; bounded width so GlassStepper's
              // internal Expanded children can flex (unbounded width trips
              // RenderFlex's flex assertion in debug, broken sizing in release).
              width: 128,
              child: GlassStepper(
                quantity: qty,
                onAdd: onAdd,
                onDecrement: onDec,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CartSummary extends StatelessWidget {
  const _CartSummary({
    required this.subtotal,
    required this.discount,
    required this.discountLabel,
    required this.onDiscount,
    required this.serviceCharge,
    required this.tax,
    required this.total,
    required this.onCheckout,
    required this.checkoutLabel,
  });

  final int subtotal;
  final int discount;

  /// Name of the applied promo, or the typed percentage. Null when none.
  final String? discountLabel;

  /// Null disables the row — an empty cart has nothing to discount.
  final VoidCallback? onDiscount;

  final int serviceCharge;
  final int tax;
  final int total;
  final VoidCallback onCheckout;
  final String checkoutLabel;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _row(context, l10n.posSubtotal, MoneyFormatter.format(subtotal)),
        // Always present, even at zero. A discount control that only appears
        // once a discount exists is a control nobody can find the first time.
        InkWell(
          onTap: onDiscount,
          borderRadius: AppDimensions.radiusSm,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Icon(
                  Icons.local_offer_outlined,
                  size: 14,
                  color: discount > 0 ? design.primary : design.textMedium,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    discountLabel ?? l10n.posDiscountTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: discount > 0
                          ? FontWeight.w700
                          : FontWeight.w400,
                      color: discount > 0 ? design.primary : design.textMedium,
                    ),
                  ),
                ),
                Text(
                  discount > 0
                      ? '- ${MoneyFormatter.format(discount)}'
                      : l10n.commonAdd,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: discount > 0 ? design.primary : design.textMedium,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (serviceCharge > 0)
          _row(
            context,
            l10n.posServiceCharge,
            MoneyFormatter.format(serviceCharge),
          ),
        if (tax > 0) _row(context, l10n.posTax, MoneyFormatter.format(tax)),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 10),
          child: Divider(
            height: 1,
            color: design.glassBorder.withValues(alpha: 0.4),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              l10n.posTotal,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: design.textMedium,
              ),
            ),
            Text(
              MoneyFormatter.format(total),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 20,
                color: design.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppDimensions.space12),
        FilledButton.icon(
          onPressed: onCheckout,
          icon: const Icon(Icons.payment_rounded),
          label: Text(checkoutLabel),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    Color? color,
  }) {
    final design = context.design;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: design.textMedium, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              color: color ?? design.textHigh,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TableField extends StatelessWidget {
  const _TableField({required this.value, required this.compact, this.onTap});
  final String value;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final hasValue = value.isNotEmpty;
    return GlassCard.solid(
      tint: hasValue ? design.primary : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space12,
        vertical: 10,
      ),
      radius: AppDimensions.radiusMd,
      onTap: onTap,
      child: Row(
        children: [
          Icon(
            Icons.table_restaurant_rounded,
            size: 18,
            color: hasValue ? design.onPrimary : design.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasValue ? value : l10n.posSelectTable,
              style: TextStyle(
                color: hasValue ? design.onPrimary : design.textMedium,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: hasValue ? design.onPrimary : design.textMedium,
            size: 20,
          ),
        ],
      ),
    );
  }
}
