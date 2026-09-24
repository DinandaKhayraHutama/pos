import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/authorize_sheet.dart';
import '../../core/auth/permissions.dart';
import '../../core/localization/l10n.dart';
import '../../core/pricing/pricing.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_snack_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/glass/glass_stepper.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../core/widgets/product_thumbnail.dart';
import '../../core/widgets/segmented_selector.dart';
import '../../data/models/bill.dart';
import '../../data/models/enums.dart';
import '../../data/models/modifier_group.dart';
import '../../data/models/modifier_option.dart';
import '../../data/models/product_variant.dart';
import '../../data/models/sales_config.dart';
import '../../data/repositories/customer_repository.dart';
import '../../data/repositories/sales_config_repository.dart';
import '../../data/device/bill_coordinator.dart';
import '../../data/repositories/bill_repository.dart';
import '../../providers/bill_provider.dart';
import '../../providers/cart_provider.dart';
import '../../providers/catalog_provider.dart';
import '../../providers/modifier_provider.dart';
import '../../providers/pricing_provider.dart';
import '../../providers/settings_provider.dart';
import '../bills/bill_ui.dart';
import '../bills/cancel_bill_sheet.dart';
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
    final pricing =
        ref.watch(pricingContextProvider).valueOrNull ?? PricingContext.empty;

    if (cart.isEmpty) {
      return _EmptyCart(compact: widget.compact, pricing: pricing);
    }

    // Every figure below comes from this one quote — the same object the
    // checkout sheet charges and the order records.
    final quote = ref.watch(cartQuoteProvider);
    final result = quote.result;
    final total = result.total;
    final salesTypes = pricing.salesTypes;
    final usesTable =
        quote.salesType?.usesTable ?? cart.type == OrderType.dineIn;
    final billsOn = ref.watch(billsEnabledProvider);

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
              if (cart.bill case final bill?) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    bill.number,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: design.textMedium,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (pricing.isV2 || cart.bill?.pricing.version == 2)
                IconButton(
                  onPressed: () => addCustomAmount(context, ref),
                  icon: const Icon(Icons.edit_note_rounded),
                  tooltip: l10n.posCustomAmount,
                ),
              if (billsOn) _BillMenu(cart: cart),
              // A saved bill is closed, not cleared: it stays on the till and
              // under Open bills. Only a cart never saved is thrown away.
              IconButton(
                onPressed: () => notifier.clear(),
                icon: Icon(
                  cart.isBill
                      ? Icons.close_rounded
                      : Icons.delete_sweep_rounded,
                ),
                tooltip: cart.isBill ? l10n.billCloseEditor : l10n.posClearCart,
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
          // A saved bill's visit type priced its lines: it is shown, not changed.
          child: IgnorePointer(
            ignoring: cart.isBill,
            child: Opacity(
              opacity: cart.isBill ? 0.6 : 1,
              child: salesTypes.isNotEmpty
                  ? Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final type in salesTypes)
                          ChoiceChip(
                            label: Text(type.name),
                            selected: quote.salesType?.id == type.id,
                            onSelected: (_) => notifier.setSalesType(type),
                          ),
                      ],
                    )
                  : SegmentedSelector<OrderType>(
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
          ),
        ),
        // Dine-in without a floor plan is a normal way to run a warung: guests
        // sit wherever they like and the order is still eaten in. So the table
        // row follows the store's own setting, not the order type alone.
        if (usesTable && settings?.tableServiceEnabled != false)
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
              onTap: cart.isBill && cart.tableSessionId != null
                  ? () => showAppSnackBar(context, l10n.tableMoveLater)
                  : () => _pickTable(context),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppDimensions.space16,
            AppDimensions.space10,
            AppDimensions.space16,
            0,
          ),
          child: _OrderDetailsField(
            customerName: cart.customerName,
            note: cart.note,
            onTap: () => _editOrderDetails(context),
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
                quoted: i < quote.lines.length ? quote.lines[i] : null,
                // The kitchen has it: it never changes again (paritas F4).
                locked: line.dispatched,
                // Keyed on the line, not the product: a Large and a Regular
                // of the same coffee are two lines, and stepping one must
                // not move the other. Modifiers have to come along too, or
                // stepping a line that carries any would compute a DIFFERENT
                // key (no modifiers) and silently fork into — or merge with
                // — the wrong line.
                // A custom amount is sold once: stepping it up would re-add
                // its synthetic product as a catalogue line.
                onAdd: line.custom || line.dispatched
                    ? null
                    // A saved line steps its own quantity; adding the product
                    // again would start a new line at today's price.
                    : line.billLineId != null
                    ? () => notifier.setQuantity(line.key, line.quantity + 1)
                    : () => notifier.add(
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
                subtotal: result.subtotal,
                discount: result.discount,
                discountLabel: cart.discountLabel,
                onDiscount: cart.isEmpty
                    ? null
                    : () => showGlassSheet<void>(
                        context: context,
                        builder: (_) => const DiscountSheet(),
                      ),
                serviceCharge: result.serviceCharge,
                tax: quote.addedTax,
                taxIncluded: result.taxIncluded,
                rounding: result.rounding,
                total: total,
                onCheckout: widget.onCheckout,
                checkoutLabel:
                    '${l10n.posCheckout} · ${MoneyFormatter.format(total)}',
                billActions: billsOn ? _BillActions(cart: cart) : null,
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

  Future<void> _editOrderDetails(BuildContext context) async {
    await showGlassSheet<void>(
      context: context,
      builder: (_) => const _OrderDetailsSheet(),
    );
  }

  /// Re-opens whichever pickers [line]'s product has, pre-filled with its
  /// current selections, and replaces the line if the cashier goes through
  /// with it. Closing either picker cancels the whole edit — same "back out
  /// leaves nothing changed" behaviour as adding a fresh line.
  Future<void> _editLine(BuildContext context, CartLine line) async {
    var variant = line.variant;
    var modifiers = line.modifiers;
    // A custom amount has no product behind it: nothing to pick, only its
    // note and discount to change.
    if (!line.custom) {
      final picked = await _pickSelections(context, line);
      if (picked == null) return;
      (variant, modifiers) = picked;
    }

    // Always the last step, even for a plain product with neither variants
    // nor modifiers — otherwise tapping such a tile would have nothing to
    // show and a per-item note would have no way in.
    if (!context.mounted) return;
    final pricing =
        ref.read(pricingContextProvider).valueOrNull ?? PricingContext.empty;
    final edit = await showGlassSheet<_LineEdit>(
      context: context,
      builder: (_) => _LineOptionsSheet(line: line, pricing: pricing),
    );
    if (edit == null) return;

    // Approval first, so a PIN prompt backed out of leaves the line exactly
    // as it was. Any item discount is a manual-discount decision.
    var approver = line.discountApprovedBy;
    if (edit.discountChanged && edit.discount != null) {
      if (!context.mounted) return;
      approver = await approveManualDiscount(
        context,
        ref,
        reason: context.l10n.authorizeReasonItemDiscount,
      );
      if (approver == null) return;
    }

    if (!context.mounted) return;
    final notifier = ref.read(cartProvider.notifier);
    var key = line.key;
    final sameChoices =
        line.variant?.id == variant?.id &&
        line.modifiers.length == modifiers.length &&
        {
          for (final m in line.modifiers) m.option.id,
        }.containsAll({for (final m in modifiers) m.option.id});
    // A saved line whose choices did not change keeps its identity and the
    // price it was frozen at; only a new choice makes it a new line.
    if (line.custom || (line.billLineId != null && sameChoices)) {
      notifier.setNote(key, edit.note);
    } else {
      notifier.updateLineSelections(
        key,
        variant: variant,
        modifiers: modifiers,
        note: edit.note,
        clearNote: edit.note.isEmpty,
      );
      // Re-adding the line gave it a new identity and no discount.
      key = CartLine(
        product: line.product,
        quantity: line.quantity,
        variant: variant,
        modifiers: modifiers,
      ).key;
    }
    final discount = edit.discountChanged ? edit.discount : line.discount;
    if (discount == null) {
      notifier.clearLineDiscount(key);
    } else {
      notifier.setLineDiscount(
        key,
        discount: discount,
        discountId: edit.discountChanged ? edit.discountId : line.discountId,
        discountName: edit.discountChanged
            ? edit.discountName
            : line.discountName,
        approvedBy: approver,
      );
    }
  }

  /// The variant and modifier pickers, pre-filled with [line]'s selections.
  /// Null when the cashier closed either one — the whole edit is cancelled.
  Future<(ProductVariant?, List<SelectedModifier>)?> _pickSelections(
    BuildContext context,
    CartLine line,
  ) async {
    var variant = line.variant;
    final variants =
        (await ref.read(productVariantsProvider.future))[line.product.id] ??
        const [];
    if (!context.mounted) return null;
    if (variants.isNotEmpty) {
      final chosen = await showGlassSheet<ProductVariant>(
        context: context,
        builder: (_) =>
            VariantPickerSheet(product: line.product, variants: variants),
      );
      if (chosen == null) return null;
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
      if (!context.mounted) return null;
      final chosen = await showGlassSheet<List<SelectedModifier>>(
        context: context,
        builder: (_) => ModifierPickerSheet(
          product: line.product,
          basePrice: line.product.price + (variant?.priceDelta ?? 0),
          groups: groups,
          initialSelections: modifiers,
        ),
      );
      if (chosen == null) return null;
      modifiers = chosen;
    }
    return (variant, modifiers);
  }
}

class _EmptyCart extends ConsumerWidget {
  const _EmptyCart({required this.compact, required this.pricing});
  final bool compact;
  final PricingContext pricing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            // A custom amount needs no product, so it has to be reachable
            // from an empty cart too.
            if (pricing.isV2) ...[
              const SizedBox(height: AppDimensions.space12),
              TextButton.icon(
                onPressed: () => addCustomAmount(context, ref),
                icon: const Icon(Icons.edit_note_rounded),
                label: Text(l10n.posCustomAmount),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CartLineTile extends StatelessWidget {
  const _CartLineTile({
    required this.line,
    required this.quoted,
    this.locked = false,
    required this.onAdd,
    required this.onDec,
    required this.onRemove,
    required this.onTap,
  });

  final CartLine line;

  /// Sent to the kitchen: shown, never stepped, removed or edited.
  final bool locked;

  /// The line as the pricing engine priced it — its resolved sales-type price
  /// and item discount. Null only for the frame before the quote catches up.
  final QuotedLine? quoted;

  /// Null for a line that cannot be stepped up (a custom amount).
  final VoidCallback? onAdd;
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
      direction: locked ? DismissDirection.none : DismissDirection.endToStart,
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
        onTap: locked ? null : onTap,
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
                  if (line.note != null && line.note!.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        Icon(
                          Icons.sticky_note_2_outlined,
                          size: 11,
                          color: design.primary,
                        ),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            line.note!,
                            style: TextStyle(
                              fontSize: 11,
                              color: design.primary,
                              fontStyle: FontStyle.italic,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                    // The priced gross, which carries the variant delta and
                    // the sales type's own price — `product.price * qty`
                    // would quietly under-report a Large, or a GoFood price.
                    MoneyFormatter.format(
                      quoted?.result.gross ?? line.lineTotal,
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      color: design.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if ((quoted?.result.lineDiscount ?? 0) > 0)
                    Text(
                      '${line.discountName ?? context.l10n.posItemDiscount}'
                      ' - ${MoneyFormatter.format(quoted!.result.lineDiscount)}',
                      style: TextStyle(fontSize: 11, color: design.textMedium),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (locked)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '× $qty',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: design.textHigh,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.soup_kitchen_rounded,
                        size: 12,
                        color: design.success,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        context.l10n.billLineInKitchen,
                        style: TextStyle(fontSize: 11, color: design.success),
                      ),
                    ],
                  ),
                ],
              )
            else if (onAdd case final add?)
              SizedBox(
                // Compact inline stepper; bounded width so GlassStepper's
                // internal Expanded children can flex (unbounded width trips
                // RenderFlex's flex assertion in debug, broken sizing in
                // release).
                width: 128,
                child: GlassStepper(
                  quantity: qty,
                  onAdd: add,
                  onDecrement: onDec,
                ),
              )
            else
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline_rounded),
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
    required this.taxIncluded,
    required this.rounding,
    required this.total,
    required this.onCheckout,
    required this.checkoutLabel,
    this.billActions,
  });

  /// Save and Send-to-kitchen, where saved bills run (paritas F4).
  final Widget? billActions;

  final int subtotal;
  final int discount;

  /// Name of the applied promo, or the typed percentage. Null when none.
  final String? discountLabel;

  /// Null disables the row — an empty cart has nothing to discount.
  final VoidCallback? onDiscount;

  final int serviceCharge;

  /// Tax ADDED on top of the prices.
  final int tax;

  /// Tax already inside the prices — shown, never added again.
  final int taxIncluded;
  final int rounding;
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
        if (rounding != 0)
          _row(context, l10n.posRounding, MoneyFormatter.format(rounding)),
        if (taxIncluded > 0)
          _row(
            context,
            l10n.posTaxIncluded,
            MoneyFormatter.format(taxIncluded),
            color: design.textMedium,
          ),
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
        if (billActions case final actions?) ...[
          actions,
          const SizedBox(height: AppDimensions.space8),
        ],
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

/// Summary row for the whole order's customer name and note — the same
/// read-only-row-that-opens-a-sheet shape as [_TableField], so tapping
/// anywhere on the cart panel follows one consistent interaction.
class _OrderDetailsField extends StatelessWidget {
  const _OrderDetailsField({
    required this.customerName,
    required this.note,
    this.onTap,
  });

  final String? customerName;
  final String? note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final name = customerName?.trim() ?? '';
    final noteText = note?.trim() ?? '';
    final summary = [
      if (name.isNotEmpty) name,
      if (noteText.isNotEmpty) noteText,
    ].join(' · ');
    final hasValue = summary.isNotEmpty;
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
            Icons.person_outline_rounded,
            size: 18,
            color: hasValue ? design.onPrimary : design.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasValue ? summary : l10n.posOrderDetails,
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

/// Edits the whole order's customer name and note together. Applies only on
/// explicit save, matching [DiscountSheet]'s confirm-then-pop convention
/// rather than writing to the cart on every keystroke.
class _OrderDetailsSheet extends ConsumerStatefulWidget {
  const _OrderDetailsSheet();

  @override
  ConsumerState<_OrderDetailsSheet> createState() => _OrderDetailsSheetState();
}

class _OrderDetailsSheetState extends ConsumerState<_OrderDetailsSheet> {
  final _nameCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  String? _selectedCustomerId;

  @override
  void initState() {
    super.initState();
    final cart = ref.read(cartProvider);
    _nameCtrl.text = cart.customerName ?? '';
    _selectedCustomerId = cart.customerId;
    _noteCtrl.text = cart.note ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
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
                  l10n.posOrderDetails,
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
              label: l10n.posCustomerName,
              prefix: Icons.person_outline_rounded,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() => _selectedCustomerId = null),
            ),
            if (_nameCtrl.text.trim().isNotEmpty)
              FutureBuilder(
                future: CustomerRepository.instance.search(
                  _nameCtrl.text,
                  limit: 4,
                ),
                builder: (context, snapshot) {
                  final matches = snapshot.data ?? const [];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final customer in matches)
                        TextButton.icon(
                          onPressed: () => setState(() {
                            _selectedCustomerId = customer.id;
                            _nameCtrl.text = customer.name;
                          }),
                          icon: Icon(
                            _selectedCustomerId == customer.id
                                ? Icons.check_circle_rounded
                                : Icons.person_outline_rounded,
                          ),
                          label: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              customer.phone == null
                                  ? customer.name
                                  : '${customer.name} · ${customer.phone}',
                            ),
                          ),
                        ),
                      if (_selectedCustomerId == null)
                        TextButton.icon(
                          onPressed: _createCustomer,
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                          label: Text(l10n.posCreateCustomer),
                        ),
                    ],
                  );
                },
              ),
            const SizedBox(height: AppDimensions.space10),
            GlassTextField(
              controller: _noteCtrl,
              label: l10n.posNote,
              hint: l10n.posNoteHint,
              prefix: Icons.sticky_note_2_outlined,
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
            ),
            const SizedBox(height: AppDimensions.space16),
            FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
          ],
        ),
      ),
    );
  }

  Future<void> _createCustomer() async {
    final customer = await CustomerRepository.instance.create(
      name: _nameCtrl.text,
    );
    if (!mounted) return;
    setState(() {
      _selectedCustomerId = customer.id;
      _nameCtrl.text = customer.name;
    });
  }

  void _save() {
    final notifier = ref.read(cartProvider.notifier);
    notifier.setCustomer(id: _selectedCustomerId, name: _nameCtrl.text);
    notifier.setOrderNote(_noteCtrl.text);
    Navigator.of(context).pop();
  }
}

/// What the line sheet hands back: the note, and — only when the cashier
/// touched it — the item discount (null in [discount] means "remove it").
typedef _LineEdit = ({
  String note,
  bool discountChanged,
  DiscountSpec? discount,
  String? discountId,
  String? discountName,
});

/// Adds a custom amount — a line typed at the till with no product behind it
/// (Fase 3, version 2 outlets). What was typed is asked first, so whoever
/// approves it sees the amount they are approving; someone without
/// [AppPermission.enterCustomAmount] needs a PIN from someone with it.
Future<void> addCustomAmount(BuildContext context, WidgetRef ref) async {
  final entry = await showGlassSheet<({String label, int amount})>(
    context: context,
    builder: (_) => const _CustomAmountSheet(),
  );
  if (entry == null || !context.mounted) return;
  final settings = ref.read(settingsProvider).valueOrNull;
  if (settings?.can(AppPermission.enterCustomAmount) != true) {
    final approver = await requestAuthorization(
      context,
      reason: context.l10n.authorizeReasonCustomAmount,
      permission: AppPermission.enterCustomAmount,
    );
    if (approver == null) return;
  }
  ref
      .read(cartProvider.notifier)
      .addCustomAmount(label: entry.label, amount: entry.amount);
}

/// Edits one cart line's note and, at a version 2 outlet, its item discount.
/// Returns null if the sheet was dismissed without saving — same
/// cancel-abandons-the-edit convention [_CartPanelState._editLine] already
/// uses for the variant and modifier steps ahead of this one.
class _LineOptionsSheet extends StatefulWidget {
  const _LineOptionsSheet({required this.line, required this.pricing});
  final CartLine line;
  final PricingContext pricing;

  @override
  State<_LineOptionsSheet> createState() => _LineOptionsSheetState();
}

class _LineOptionsSheetState extends State<_LineOptionsSheet> {
  final _noteCtrl = TextEditingController();
  final _valueCtrl = TextEditingController();

  /// The saved item discount picked, or null for a hand-typed one.
  DiscountConfig? _named;
  bool _asPercent = true;
  bool _discountChanged = false;
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    _noteCtrl.text = widget.line.note ?? '';
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _valueCtrl.dispose();
    super.dispose();
  }

  List<DiscountConfig> get _itemDiscounts =>
      widget.pricing.discounts.where((d) => d.isItem).toList();

  DiscountKind get _kind =>
      _named?.kind ?? (_asPercent ? DiscountKind.percent : DiscountKind.amount);

  /// The value typed in the field, as the discount it describes — in the
  /// kind of the saved discount picked, or the one the chips chose.
  DiscountSpec? get _typed {
    final value = int.tryParse(_valueCtrl.text) ?? 0;
    if (value <= 0) return null;
    if (_kind == DiscountKind.percent) {
      return value > 100 ? null : DiscountSpec.percent(value);
    }
    return DiscountSpec.amount(value);
  }

  bool get _needsValue => _named == null || _named!.value == null;

  DiscountSpec? get _spec => _needsValue ? _typed : _named!.spec;

  /// A discount being set must be a complete one; a note alone always saves.
  bool get _canSave => !_discountChanged || _removed || _spec != null;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final line = widget.line;
    final hasDiscount = line.discount != null && !_removed;

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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      line.displayName,
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
              const SizedBox(height: AppDimensions.space8),
              GlassTextField(
                controller: _noteCtrl,
                label: l10n.posLineNote,
                hint: l10n.posLineNoteHint,
                prefix: Icons.sticky_note_2_outlined,
                textCapitalization: TextCapitalization.sentences,
                maxLines: 2,
              ),
              if (widget.pricing.isV2) ...[
                const SizedBox(height: AppDimensions.space16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        hasDiscount && line.discountName != null
                            ? '${l10n.posItemDiscount} · ${line.discountName}'
                            : l10n.posItemDiscount,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: hasDiscount
                              ? design.primary
                              : design.textMedium,
                        ),
                      ),
                    ),
                    if (hasDiscount)
                      TextButton(
                        onPressed: () => setState(() {
                          _removed = true;
                          _discountChanged = true;
                          _named = null;
                          _valueCtrl.clear();
                        }),
                        child: Text(l10n.posDiscountRemove),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final d in _itemDiscounts)
                      ChoiceChip(
                        label: Text(d.name),
                        selected: _named?.id == d.id,
                        onSelected: (_) => setState(() {
                          _named = _named?.id == d.id ? null : d;
                          _discountChanged = true;
                          _removed = false;
                        }),
                      ),
                    if (_named == null) ...[
                      ChoiceChip(
                        selected: _asPercent,
                        onSelected: (_) => setState(() => _asPercent = true),
                        label: Text(l10n.posDiscountPercent),
                      ),
                      ChoiceChip(
                        selected: !_asPercent,
                        onSelected: (_) => setState(() => _asPercent = false),
                        label: Text(l10n.posDiscountAmount),
                      ),
                    ],
                  ],
                ),
                if (_needsValue) ...[
                  const SizedBox(height: AppDimensions.space10),
                  GlassTextField(
                    controller: _valueCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    hint: _kind == DiscountKind.percent ? '10' : '5000',
                    onChanged: (_) => setState(() {
                      _discountChanged = true;
                      _removed = false;
                    }),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    l10n.posItemDiscountLocked,
                    style: TextStyle(fontSize: 11, color: design.textLow),
                  ),
                ),
              ],
              const SizedBox(height: AppDimensions.space16),
              FilledButton(
                onPressed: _canSave ? _save : null,
                child: Text(l10n.commonSave),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _save() {
    final setting = _discountChanged && !_removed;
    Navigator.of(context).pop<_LineEdit>((
      note: _noteCtrl.text.trim(),
      discountChanged: _discountChanged,
      discount: setting ? _spec : null,
      discountId: setting ? _named?.id : null,
      discountName: setting ? _named?.name : null,
    ));
  }
}

/// Types a custom amount: what it is, and what it costs.
class _CustomAmountSheet extends StatefulWidget {
  const _CustomAmountSheet();

  @override
  State<_CustomAmountSheet> createState() => _CustomAmountSheetState();
}

class _CustomAmountSheetState extends State<_CustomAmountSheet> {
  final _labelCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();

  @override
  void dispose() {
    _labelCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  int get _amount => int.tryParse(_amountCtrl.text) ?? 0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
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
                  l10n.posCustomAmount,
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
              controller: _labelCtrl,
              label: l10n.posCustomAmountLabel,
              prefix: Icons.edit_note_rounded,
              textCapitalization: TextCapitalization.sentences,
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppDimensions.space10),
            GlassTextField(
              controller: _amountCtrl,
              label: l10n.posCustomAmountValue,
              prefix: Icons.payments_outlined,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppDimensions.space16),
            FilledButton(
              onPressed: _labelCtrl.text.trim().isEmpty || _amount <= 0
                  ? null
                  : () => Navigator.of(
                      context,
                    ).pop((label: _labelCtrl.text.trim(), amount: _amount)),
              child: Text(l10n.commonAdd),
            ),
          ],
        ),
      ),
    );
  }
}

/// Save and Send to kitchen (paritas F4). Saving moves no stock; sending
/// consumes the lines the kitchen does not have yet, once. Pay (below them)
/// sends whatever is left and settles in one go.
class _BillActions extends ConsumerWidget {
  const _BillActions({required this.cart});
  final CartState cart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final pending = cart.pendingCount;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () async {
              final bill = await _run(context, ref, dispatch: false);
              if (bill != null && context.mounted) {
                showAppSnackBar(
                  context,
                  l10n.billSaved(bill.number),
                  success: true,
                );
              }
            },
            icon: const Icon(Icons.save_outlined),
            label: Text(l10n.billSave, overflow: TextOverflow.ellipsis),
          ),
        ),
        const SizedBox(width: AppDimensions.space8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: pending == 0
                ? () => showAppSnackBar(context, l10n.billNothingToSend)
                : () async {
                    final bill = await _run(context, ref, dispatch: true);
                    if (bill != null && context.mounted) {
                      showAppSnackBar(
                        context,
                        l10n.billSentToKitchen,
                        success: true,
                      );
                    }
                  },
            icon: const Icon(Icons.soup_kitchen_outlined),
            label: Text(
              l10n.billSendToKitchen(pending),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  static Future<Bill?> _run(
    BuildContext context,
    WidgetRef ref, {
    required bool dispatch,
  }) async {
    Bill? saved;
    await runBillAction(context, () async {
      saved = await saveCartBill(
        read: ref.read,
        invalidate: ref.invalidate,
        dispatch: dispatch,
      );
    });
    return saved;
  }
}

/// Pre-bill, park and cancel for the bill in the cart (paritas F4).
class _BillMenu extends ConsumerWidget {
  const _BillMenu({required this.cart});
  final CartState cart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final connected = BillCoordinator.current != null;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (action) async {
        switch (action) {
          case 'prebill':
            await printCartPrebill(context, ref);
          case 'park':
            final id = cart.bill?.id;
            if (id == null) return;
            await runBillAction(context, () async {
              // Whatever the cart still holds unsaved goes up with it.
              await saveCartBill(read: ref.read, invalidate: ref.invalidate);
              await parkBill(
                read: ref.read,
                invalidate: ref.invalidate,
                billId: id,
              );
            }, success: l10n.billParked);
          case 'cancel':
            final id = cart.bill?.id;
            if (id == null) return;
            final bill = await BillRepository.instance.byId(id);
            if (bill == null || !context.mounted) return;
            await showGlassSheet<void>(
              context: context,
              builder: (_) => CancelBillSheet(bill: bill),
            );
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'prebill',
          child: ListTile(
            leading: const Icon(Icons.receipt_outlined),
            title: Text(l10n.billPrebill),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (cart.isBill && connected)
          PopupMenuItem(
            value: 'park',
            child: ListTile(
              leading: const Icon(Icons.local_parking_rounded),
              title: Text(l10n.billPark),
              subtitle: Text(l10n.billParkHint),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (cart.isBill)
          PopupMenuItem(
            value: 'cancel',
            child: ListTile(
              leading: const Icon(Icons.cancel_outlined),
              title: Text(l10n.billCancel),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
    );
  }
}
