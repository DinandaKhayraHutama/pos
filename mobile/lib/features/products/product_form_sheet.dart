import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../data/models/category.dart';
import '../../data/models/modifier_group.dart';
import '../../data/models/product_modifier_config.dart';

import 'product_modifier_config_page.dart';
import '../../data/models/product.dart';
import '../../data/models/product_variant.dart';
import '../../data/repositories/modifier_repository.dart';
import '../../data/repositories/product_repository.dart';
import '../../providers/catalog_provider.dart';
import '../../providers/modifier_provider.dart';
import '../../providers/settings_provider.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/icon_map.dart';

/// Add or edit a [Product].
///
/// Rendered inside a [GlassSheet] (via `showGlassSheet`) which supplies the
/// frosted blur + grabber handle; this widget paints only the form fields.
class ProductFormSheet extends ConsumerStatefulWidget {
  const ProductFormSheet({super.key, this.existing});
  final Product? existing;

  @override
  ConsumerState<ProductFormSheet> createState() => _ProductFormSheetState();
}

class _ProductFormSheetState extends ConsumerState<ProductFormSheet> {
  late final _nameCtrl = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final _priceCtrl = TextEditingController(
    text: widget.existing != null ? '${widget.existing!.price}' : '',
  );
  late final _descCtrl = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  late final _costCtrl = TextEditingController(
    text: widget.existing?.cost != null ? '${widget.existing!.cost}' : '',
  );
  late final _skuCtrl = TextEditingController(text: widget.existing?.sku ?? '');
  // Empty means "not stock-tracked", which is a real and different state from
  // 0 ("tracked, none left") — so this stays a text field rather than a
  // number that defaults to zero.
  late final _stockCtrl = TextEditingController(
    text: widget.existing?.stock != null ? '${widget.existing!.stock}' : '',
  );
  // Empty means "use the store rate". Same reasoning as stock: a literal 0 is
  // a real, different answer ("this item is zero-rated"), so the field cannot
  // default to a number.
  late final _taxCtrl = TextEditingController(
    text: widget.existing?.pb1Rate != null
        ? _trimTrailingZero(widget.existing!.pb1Rate!)
        : '',
  );
  late String? _categoryId = widget.existing?.categoryId;
  late String _iconKey = widget.existing?.iconKey ?? 'restaurant';
  late bool _available = widget.existing?.available ?? true;
  late bool _popular = widget.existing?.isPopular ?? false;

  /// Working copy of the variant list, edited in place and written as a unit
  /// on save. Loaded once in [initState] — reading it from a provider on every
  /// build would fight the user's edits.
  List<ProductVariant> _variants = const [];
  bool _variantsLoaded = false;

  /// Whether the product had any variants when the form opened.
  ///
  /// Guards the write on save: a product that never had variants and still
  /// has none must not issue a DELETE, both because it is pointless for the
  /// twenty of twenty-six products that will never have one, and because it
  /// would make the save path depend on the database in a form that otherwise
  /// does not touch it.
  bool _hadVariants = false;

  /// Ids of the modifier groups this product currently offers — a selection
  /// FROM the catalogue-wide list, not a list defined here. Same load-once
  /// and guard-the-write reasoning as [_variants]/[_hadVariants].
  Set<String> _selectedGroupIds = const {};
  bool _groupsLoaded = false;
  bool _hadGroups = false;

  /// A further narrowing UNDER [_selectedGroupIds]: not every option in an
  /// attached group necessarily applies to THIS product (a food item
  /// attaching "Topping" should not also offer the milk-based ones). Flat
  /// across every attached group — an option id is already unique to one
  /// group — and loaded/guarded the same way as the groups themselves.
  Set<String> _selectedOptionIds = const {};
  Set<String> _defaultOptionIds = const {};
  bool _saving = false;

  static String _trimTrailingZero(double v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(0) : '$v';

  @override
  void initState() {
    super.initState();
    final id = widget.existing?.id;
    if (id == null) {
      _variantsLoaded = true;
      _groupsLoaded = true;
      return;
    }
    ProductRepository.instance.variantsFor(id).then((v) {
      if (!mounted) return;
      setState(() {
        _variants = v;
        _hadVariants = v.isNotEmpty;
        _variantsLoaded = true;
      });
    });
    ModifierRepository.instance.configurationForProduct(id).then((config) {
      if (!mounted) return;
      setState(() {
        _selectedGroupIds = config.groupIds;
        _hadGroups = config.groupIds.isNotEmpty;
        _selectedOptionIds = config.optionIds;
        _defaultOptionIds = config.defaultOptionIds;
        _groupsLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    _descCtrl.dispose();
    _costCtrl.dispose();
    _skuCtrl.dispose();
    _stockCtrl.dispose();
    _taxCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final categories = ref.watch(categoriesProvider);
    final isEdit = widget.existing != null;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(
          left: AppDimensions.space16,
          right: AppDimensions.space16,
          top: AppDimensions.space4,
          bottom:
              MediaQuery.of(context).viewInsets.bottom + AppDimensions.space16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isEdit ? l10n.productEdit : l10n.productAdd,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: design.textHigh,
              ),
            ),
            const SizedBox(height: AppDimensions.space16),
            _IconPicker(
              value: _iconKey,
              onChanged: (v) => setState(() => _iconKey = v),
            ),
            const SizedBox(height: AppDimensions.space16),
            GlassTextField(
              controller: _nameCtrl,
              label: l10n.productName,
              autofocus: !isEdit,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: AppDimensions.space12),
            Row(
              children: [
                Expanded(
                  child: GlassTextField(
                    controller: _priceCtrl,
                    label: l10n.productPrice,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    prefixText: 'Rp ',
                  ),
                ),
                const SizedBox(width: AppDimensions.space10),
                Expanded(
                  child: GlassTextField(
                    controller: _costCtrl,
                    label: l10n.productCost,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    prefixText: 'Rp ',
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space12),
            Row(
              children: [
                Expanded(
                  child: GlassTextField(
                    controller: _stockCtrl,
                    label: l10n.productStock,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: AppDimensions.space10),
                Expanded(
                  child: GlassTextField(
                    controller: _skuCtrl,
                    label: l10n.productSku,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.productStockHint,
                style: TextStyle(color: design.textLow, fontSize: 11),
              ),
            ),
            const SizedBox(height: AppDimensions.space12),
            GlassTextField(
              controller: _taxCtrl,
              label: l10n.productTaxRate,
              hint: '${l10n.productTaxStore}: ${_storeRateLabel(ref)}',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.productTaxRateHint,
                style: TextStyle(color: design.textLow, fontSize: 11),
              ),
            ),
            const SizedBox(height: AppDimensions.space12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.productCategory,
                style: TextStyle(
                  color: design.textMedium,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 6),
            categories.maybeWhen(
              data: (list) => SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: list
                      .map(
                        (c) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _CatChip(
                            category: c,
                            selected: _categoryId == c.id,
                            onTap: () => setState(() => _categoryId = c.id),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              orElse: () => const SizedBox.shrink(),
            ),
            const SizedBox(height: AppDimensions.space16),
            _VariantEditor(
              basePrice: int.tryParse(_priceCtrl.text) ?? 0,
              variants: _variants,
              enabled: _variantsLoaded,
              onChanged: (v) => setState(() => _variants = v),
            ),
            const SizedBox(height: AppDimensions.space16),
            _ModifierSummary(
              config: ProductModifierConfig(
                groupIds: _selectedGroupIds,
                optionIds: _selectedOptionIds,
                defaultOptionIds: _defaultOptionIds,
              ),
              enabled: _groupsLoaded,
              onChanged: (config) => setState(() {
                _selectedGroupIds = config.groupIds;
                _selectedOptionIds = config.optionIds;
                _defaultOptionIds = config.defaultOptionIds;
              }),
            ),
            const SizedBox(height: AppDimensions.space12),
            GlassTextField(
              controller: _descCtrl,
              label: l10n.productDescription,
              maxLines: 3,
            ),
            const SizedBox(height: AppDimensions.space12),
            Row(
              children: [
                Expanded(
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _available,
                    onChanged: (v) => setState(() => _available = v),
                    title: Text(
                      _available
                          ? l10n.productAvailable
                          : l10n.productUnavailable,
                    ),
                  ),
                ),
                Expanded(
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _popular,
                    onChanged: (v) => setState(() => _popular = v),
                    title: Text(l10n.productPopular),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppDimensions.space20),
            FilledButton(
              onPressed: _groupsLoaded && _variantsLoaded && !_saving
                  ? _save
                  : null,
              child: Text(l10n.commonSave),
            ),
          ],
        ),
      ),
    );
  }

  /// The store-wide PB1 rate, shown as the hint so "empty" has a visible
  /// meaning.
  String _storeRateLabel(WidgetRef ref) {
    final rate = ref.watch(settingsProvider).valueOrNull?.pb1Rate ?? 0;
    return '${_trimTrailingZero(rate)}%';
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    final price = int.tryParse(_priceCtrl.text) ?? 0;
    final category = _categoryId;
    if (name.isEmpty || price <= 0 || category == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.commonRequired)));
      return;
    }
    final existing = widget.existing;
    // Blank stock means "not counted", NOT zero — clearing the field has to be
    // able to switch a product back to untracked, so this parses to null
    // rather than defaulting.
    final stockText = _stockCtrl.text.trim();
    final costText = _costCtrl.text.trim();
    final taxText = _taxCtrl.text.trim();
    final sku = _skuCtrl.text.trim();
    final id = existing?.id ?? 'p_${DateTime.now().millisecondsSinceEpoch}';
    setState(() => _saving = true);
    try {
      await ref
          .read(productsProvider.notifier)
          .upsert(
            Product(
              id: id,
              name: name,
              categoryId: category,
              price: price,
              cost: costText.isEmpty ? null : int.tryParse(costText),
              sku: sku.isEmpty ? null : sku,
              stock: stockText.isEmpty ? null : int.tryParse(stockText),
              // Blank means "inherit the store rate"; a typed 0 means this item
              // is genuinely zero-rated and must ignore it.
              pb1Rate: taxText.isEmpty ? null : double.tryParse(taxText),
              // Carried over, not edited here. The form builds a whole Product,
              // so any field it forgets is silently cleared on save — editing a
              // product's stock used to wipe its photo, which looked like the
              // image had failed to load rather than like data loss.
              imageUrl: existing?.imageUrl,
              emoji: existing?.emoji ?? '🍽️',
              description: _descCtrl.text.trim().isEmpty
                  ? null
                  : _descCtrl.text.trim(),
              iconKey: _iconKey,
              available: _available,
              isPopular: _popular,
              sortOrder: existing?.sortOrder ?? 100,
            ),
          );
      // After the product, so the FK has something to point at on a new one.
      // Replaced as a unit — see `replaceVariants`.
      if (_variants.isNotEmpty || _hadVariants) {
        await ProductRepository.instance.replaceVariants(id, _variants);
        ref.invalidate(productVariantsProvider);
      }
      // Same guard as variants: a product that never had a modifier group and
      // still has none must not issue a write for the majority of products
      // that will never use this.
      if (_selectedGroupIds.isNotEmpty || _hadGroups) {
        await ModifierRepository.instance.saveConfiguration(
          id,
          ProductModifierConfig(
            groupIds: _selectedGroupIds,
            optionIds: _selectedOptionIds,
            defaultOptionIds: _defaultOptionIds,
          ),
        );
        ref.invalidate(productModifierDefaultsProvider);
        ref.invalidate(productModifierGroupsProvider);
        ref.invalidate(productModifierOptionScopeProvider);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.modifierSaveFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// Only installed groups appear here; the full catalogue lives in the editor.
class _ModifierSummary extends ConsumerWidget {
  const _ModifierSummary({
    required this.config,
    required this.enabled,
    required this.onChanged,
  });
  final ProductModifierConfig config;
  final bool enabled;
  final ValueChanged<ProductModifierConfig> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(modifierGroupsProvider);
    final options = ref.watch(modifierOptionsByGroupProvider);
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.modifierGroupsSectionTitle,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: context.design.textHigh,
          ),
        ),
        if (groups.hasError || options.hasError)
          TextButton(
            onPressed: () {
              ref.invalidate(modifierGroupsProvider);
              ref.invalidate(modifierOptionsByGroupProvider);
            },
            child: Text(l10n.commonRetry),
          ),
        for (final group
            in (groups.valueOrNull ?? const <ModifierGroup>[]).where(
              (g) => config.groupIds.contains(g.id),
            ))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(group.name),
            subtitle: Text(
              l10n.modifierConfigSummary(
                (options.valueOrNull?[group.id] ?? [])
                    .where((o) => config.optionIds.contains(o.id))
                    .length,
                (options.valueOrNull?[group.id] ?? [])
                    .where((o) => config.defaultOptionIds.contains(o.id))
                    .length,
              ),
            ),
          ),
        if (config.groupIds.isEmpty) Text(l10n.modifierGroupEmpty),
        OutlinedButton.icon(
          icon: const Icon(Icons.tune),
          label: Text(l10n.modifierConfigure),
          onPressed: !enabled || !groups.hasValue || !options.hasValue
              ? null
              : () async {
                  final result = await Navigator.of(context)
                      .push<ProductModifierConfig>(
                        MaterialPageRoute(
                          builder: (_) => ProductModifierConfigPage(
                            initial: config,
                            groups: groups.requireValue,
                            options: options.requireValue,
                          ),
                        ),
                      );
                  if (result != null && context.mounted) onChanged(result);
                },
        ),
      ],
    );
  }
}

/// Edits a product's size/option list in place.
///
/// A price DELTA per row rather than an absolute price, matching the model:
/// the row shows what the customer will actually be charged next to the
/// delta, so the person typing "+5000" can see it lands on Rp 23.000 without
/// doing the sum themselves.
class _VariantEditor extends StatelessWidget {
  const _VariantEditor({
    required this.basePrice,
    required this.variants,
    required this.enabled,
    required this.onChanged,
  });

  final int basePrice;
  final List<ProductVariant> variants;
  final bool enabled;
  final ValueChanged<List<ProductVariant>> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              l10n.productVariants,
              style: TextStyle(
                color: design.textMedium,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: enabled ? () => _add(context) : null,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(l10n.productVariantAdd),
            ),
          ],
        ),
        if (variants.isEmpty)
          Text(
            l10n.productVariantsHint,
            style: TextStyle(color: design.textLow, fontSize: 11),
          )
        else
          for (var i = 0; i < variants.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _VariantRow(
                variant: variants[i],
                basePrice: basePrice,
                onRemove: () {
                  final next = [...variants]..removeAt(i);
                  onChanged(next);
                },
              ),
            ),
      ],
    );
  }

  Future<void> _add(BuildContext context) async {
    final result = await showDialog<(String, int)>(
      context: context,
      builder: (_) => const _VariantDialog(),
    );
    if (result == null) return;
    onChanged([
      ...variants,
      ProductVariant(
        // Time-based rather than index-based: an index would collide with a
        // row the user just deleted and silently overwrite it on save.
        id: 'pv_${DateTime.now().microsecondsSinceEpoch}',
        productId: '',
        name: result.$1,
        priceDelta: result.$2,
        sortOrder: variants.length,
      ),
    ]);
  }
}

class _VariantRow extends StatelessWidget {
  const _VariantRow({
    required this.variant,
    required this.basePrice,
    required this.onRemove,
  });

  final ProductVariant variant;
  final int basePrice;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space12,
        vertical: AppDimensions.space8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              variant.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: design.textHigh,
              ),
            ),
          ),
          Text(
            MoneyFormatter.format(basePrice + variant.priceDelta),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: design.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: Icon(Icons.close_rounded, size: 18, color: design.textMedium),
          ),
        ],
      ),
    );
  }
}

class _VariantDialog extends StatefulWidget {
  const _VariantDialog();

  @override
  State<_VariantDialog> createState() => _VariantDialogState();
}

class _VariantDialogState extends State<_VariantDialog> {
  final _nameCtrl = TextEditingController();
  final _deltaCtrl = TextEditingController(text: '0');

  @override
  void dispose() {
    _nameCtrl.dispose();
    _deltaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.productVariantAdd),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: l10n.productVariantName),
          ),
          const SizedBox(height: AppDimensions.space12),
          TextField(
            controller: _deltaCtrl,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            // Signed: a small size that costs less is a legitimate variant,
            // and digitsOnly would make it unenterable.
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^-?\d*')),
            ],
            decoration: InputDecoration(
              labelText: l10n.productVariantPriceDelta,
              prefixText: 'Rp ',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.of(
              context,
            ).pop((name, int.tryParse(_deltaCtrl.text) ?? 0));
          },
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}

/// Grid of Material icons from the `icon_map` whitelist. Replaced an emoji
/// palette, which rendered as tofu wherever the system emoji font is missing.
class _IconPicker extends StatelessWidget {
  const _IconPicker({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      padding: const EdgeInsets.all(AppDimensions.space8),
      child: SizedBox(
        height: 110,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 10,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
          ),
          itemCount: iconKeys.length,
          itemBuilder: (_, i) {
            final e = iconKeys[i];
            final selected = value == e;
            return GestureDetector(
              onTap: () => onChanged(e),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected
                      ? design.primaryContainer
                      : Colors.transparent,
                  borderRadius: AppDimensions.radiusSm,
                  border: selected
                      ? Border.all(color: design.primary, width: 1.5)
                      : null,
                ),
                child: Icon(
                  iconFromKey(e),
                  size: 20,
                  color: selected
                      ? design.onPrimaryContainer
                      : design.textMedium,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CatChip extends StatelessWidget {
  const _CatChip({
    required this.category,
    required this.selected,
    required this.onTap,
  });
  final Category category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Material(
      color: selected
          ? design.primary
          : design.glassTint.withValues(alpha: design.glassOpacity),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                iconFromKey(category.iconKey),
                size: 14,
                color: selected ? design.onPrimary : design.textMedium,
              ),
              const SizedBox(width: 4),
              Text(
                category.name,
                style: TextStyle(
                  color: selected ? design.onPrimary : design.textMedium,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
