import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/product_thumbnail.dart';
import '../../data/models/enums.dart';
import '../../data/models/modifier_group.dart';
import '../../data/models/modifier_option.dart';
import '../../data/models/product.dart';
import '../../data/models/product_modifier_config.dart';
import '../../providers/cart_provider.dart';

/// What one product offers: a group and its (already active-filtered, sorted)
/// options — resolved once by the caller from the bulk providers, never
/// queried again here. See `PosPage._addToCart`.
typedef ModifierGroupOffer = ({
  ModifierGroup group,
  List<ModifierOption> options,
});

List<SelectedModifier> selectionsForOffers(
  List<ModifierGroupOffer> groups,
  Set<String> ids,
) => [
  for (final offer in groups)
    for (final option in resolveModifierSelection(
      offer.group,
      offer.options,
      ids,
    ))
      (group: offer.group, option: option),
];

bool needsModifierSelection(
  List<ModifierGroupOffer> groups,
  List<SelectedModifier> selected,
) => groups.any(
  (offer) =>
      offer.group.active &&
      offer.group.required &&
      offer.options.any((o) => o.active) &&
      !selected.any((m) => m.group.id == offer.group.id),
);

/// Asks which modifiers apply to [product] — every attached group at once,
/// unlike [VariantPickerSheet]'s one-tap-per-row shape, because several
/// independent selections may all need to be made before this can be
/// submitted.
///
/// [initialSelections] pre-fills the picker for the "edit from cart" flow —
/// otherwise this opens empty, the same as adding a fresh line.
class ModifierPickerSheet extends ConsumerStatefulWidget {
  const ModifierPickerSheet({
    super.key,
    required this.product,
    required this.basePrice,
    required this.groups,
    this.initialSelections = const [],
  });

  final Product product;

  /// Base price with the chosen variant's delta already applied — the
  /// starting point the running total in the header adds modifier deltas on
  /// top of.
  final int basePrice;
  final List<ModifierGroupOffer> groups;
  final List<SelectedModifier> initialSelections;

  @override
  ConsumerState<ModifierPickerSheet> createState() =>
      _ModifierPickerSheetState();
}

class _ModifierPickerSheetState extends ConsumerState<ModifierPickerSheet> {
  /// Selected options per group id. A list because a 'multiple' group can
  /// hold more than one; a 'single' group never holds more than one entry.
  late final Map<String, List<ModifierOption>> _selected = {
    for (final offer in widget.groups) offer.group.id: [],
  };

  @override
  void initState() {
    super.initState();
    for (final m in selectionsForOffers(
      widget.groups,
      widget.initialSelections.map((m) => m.option.id).toSet(),
    )) {
      (_selected[m.group.id] ??= []).add(m.option);
    }
  }

  int get _total =>
      widget.basePrice +
      _selected.values.fold(
        0,
        (a, options) => a + options.fold(0, (b, o) => b + o.priceDelta),
      );

  /// A required group with no active options is vacuously satisfied — a
  /// catalogue mistake (the group's only option got deactivated, or none
  /// were ever added) must never make a product unsellable. See
  /// `ModifierGroup`'s class doc.
  bool get _canSubmit => widget.groups.every((offer) {
    if (!offer.group.required) return true;
    if (!offer.options.any((o) => o.active)) return true;
    return (_selected[offer.group.id] ?? const []).isNotEmpty;
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;

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
                ProductThumbnail(
                  product: widget.product,
                  size: 44,
                  borderRadius: AppDimensions.radiusSm,
                ),
                const SizedBox(width: AppDimensions.space12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.product.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          color: design.textHigh,
                        ),
                      ),
                      Text(
                        l10n.modifierPickTitle,
                        style: TextStyle(
                          color: design.textMedium,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final offer in widget.groups)
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: AppDimensions.space16,
                        ),
                        child: _GroupSection(
                          offer: offer,
                          selected: _selected[offer.group.id] ?? const [],
                          onChanged: (options) => setState(
                            () => _selected[offer.group.id] = options,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppDimensions.space8),
            FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: Text(
                l10n.modifierAddToCart(MoneyFormatter.format(_total)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final result = <SelectedModifier>[
      for (final offer in widget.groups)
        for (final option in _selected[offer.group.id] ?? const [])
          (group: offer.group, option: option),
    ];
    Navigator.of(context).pop(result);
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.offer,
    required this.selected,
    required this.onChanged,
  });

  final ModifierGroupOffer offer;
  final List<ModifierOption> selected;
  final ValueChanged<List<ModifierOption>> onChanged;

  bool _isSelected(ModifierOption o) => selected.any((s) => s.id == o.id);

  void _tapSingle(ModifierOption option) {
    // Tap-to-deselect: a radio list has no native way back to "nothing
    // picked", and requiring the admin to add an explicit "None" option for
    // every optional single group is an easy step to forget. Safe for a
    // required group too — toggling off just re-disables Add.
    onChanged(_isSelected(option) ? const [] : [option]);
  }

  void _tapMultiple(ModifierOption option) {
    if (_isSelected(option)) {
      onChanged(selected.where((s) => s.id != option.id).toList());
      return;
    }
    final max = offer.group.maxSelect;
    if (max != null && selected.length >= max) return;
    onChanged([...selected, option]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final group = offer.group;
    final isMultiple = group.selectionType == ModifierSelectionType.multiple;
    final activeOptions = offer.options.where((o) => o.active).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                group.name,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: design.textHigh,
                ),
              ),
            ),
            if (group.required && activeOptions.isNotEmpty)
              _Badge(
                label: l10n.modifierPickRequiredBadge,
                color: design.warning,
              )
            else if (isMultiple)
              _Badge(
                label: l10n.modifierPickOptionalBadge,
                color: design.textMedium,
              ),
            if (isMultiple && group.maxSelect != null) ...[
              const SizedBox(width: 6),
              _Badge(
                label: l10n.modifierPickMaxBadge(group.maxSelect!),
                color: design.info,
              ),
            ],
          ],
        ),
        const SizedBox(height: AppDimensions.space8),
        for (final option in activeOptions)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _OptionTile(
              option: option,
              selected: _isSelected(option),
              onTap: () =>
                  isMultiple ? _tapMultiple(option) : _tapSingle(option),
            ),
          ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final ModifierOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      tint: selected ? design.primary : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space14,
        vertical: AppDimensions.space10,
      ),
      onTap: onTap,
      child: Row(
        children: [
          Icon(
            selected
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 18,
            color: selected ? design.onPrimary : design.textMedium,
          ),
          const SizedBox(width: AppDimensions.space10),
          Expanded(
            child: Text(
              option.name,
              style: TextStyle(
                color: selected ? design.onPrimary : design.textHigh,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          if (option.priceDelta > 0)
            Text(
              '+${MoneyFormatter.format(option.priceDelta)}',
              style: TextStyle(
                color: selected
                    ? design.onPrimary.withValues(alpha: 0.9)
                    : design.primary,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
