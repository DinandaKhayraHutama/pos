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
import '../../core/utils/icon_map.dart';
import '../../data/models/category.dart';
import '../../data/models/enums.dart';
import '../../data/models/modifier_group.dart';
import '../../data/models/modifier_option.dart';
import '../../data/models/product.dart';
import '../../data/repositories/modifier_repository.dart';
import '../../providers/catalog_provider.dart';
import '../../providers/modifier_provider.dart';
import 'product_form_sheet.dart';

/// Manage products & categories.
///
/// Pushed route (from Settings) — not hosted inside the shell's [AppBackground],
/// so this page paints its own substrate behind a transparent [Scaffold].
class ProductManagementPage extends ConsumerStatefulWidget {
  const ProductManagementPage({super.key});

  @override
  ConsumerState<ProductManagementPage> createState() =>
      _ProductManagementPageState();
}

class _ProductManagementPageState extends ConsumerState<ProductManagementPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    // AppBackground wraps the whole Scaffold (not just the body) so the
    // frosted GlassAppBar + its TabBar have the brand substrate to blur behind
    // them, matching how MainShell provides the substrate for tab pages. When
    // it only wrapped the body, the app bar blurred empty space and read
    // inconsistently against the rest of the app.
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: GlassAppBar(
          title: l10n.productManagementTitle,
          bottom: TabBar(
            controller: _tab,
            tabAlignment: TabAlignment.start,
            isScrollable: true,
            labelColor: design.textHigh,
            unselectedLabelColor: design.textMedium,
            indicatorColor: design.primary,
            labelStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
            ),
            unselectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
            tabs: [
              Tab(text: l10n.productManagementTitle),
              Tab(text: l10n.categoryManagementTitle),
              Tab(text: l10n.modifierManagementTitle),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tab,
          children: const [_ProductsTab(), _CategoriesTab(), _ModifiersTab()],
        ),
      ),
    );
  }
}

class _ProductsTab extends ConsumerWidget {
  const _ProductsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final products = ref.watch(productsProvider);
    final categories = ref.watch(categoriesProvider);

    final catLookup = <String, Category>{};
    categories.maybeWhen(
      data: (c) => {for (final x in c) catLookup[x.id] = x},
      orElse: () {},
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(productsProvider);
          ref.invalidate(categoriesProvider);
        },
        child: products.when(
          loading: () => Center(child: LoadingIndicator.skeleton(lines: 6)),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: l10n.commonError,
            subtitle: '$e',
          ),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: [
                  EmptyState(
                    icon: Icons.restaurant_rounded,
                    title: l10n.productEmpty,
                    subtitle: l10n.productEmptyHint,
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(AppDimensions.space16),
              itemCount: list.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppDimensions.space8),
              itemBuilder: (_, i) {
                final p = list[i];
                final cat = catLookup[p.categoryId];
                return _ProductListTile(
                  product: p,
                  category: cat,
                  onEdit: () => _openForm(context, ref, existing: p),
                  onToggle: () async {
                    await ref
                        .read(productsProvider.notifier)
                        .upsert(p.copyWith(available: !p.available));
                  },
                  onDelete: () => _confirmDelete(context, ref, p),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.productAdd),
      ),
    );
  }

  void _openForm(BuildContext context, WidgetRef ref, {Product? existing}) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => ProductFormSheet(existing: existing),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Product p,
  ) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      // Named, not discarded: `showDialog` defaults to the ROOT navigator,
      // while this page's own `context` sits inside a nested ShellRoute/push
      // navigator. Popping via the outer `context` resolves to the WRONG
      // navigator (the one hosting this page, not the dialog), which had
      // nothing else to pop and corrupted routing — a black screen on either
      // button. `Navigator.of(dialogContext)` is scoped to the dialog's own
      // route and is unambiguous.
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.productDeleteConfirm),
        content: Text(l10n.productDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(productsProvider.notifier).delete(p.id);
    }
  }
}

class _ProductListTile extends StatelessWidget {
  const _ProductListTile({
    required this.product,
    required this.category,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });
  final Product product;
  final Category? category;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    return GlassCard.solid(
      onTap: onEdit,
      padding: const EdgeInsets.all(AppDimensions.space12),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: design.primaryContainer.withValues(alpha: 0.6),
              borderRadius: AppDimensions.radiusMd,
            ),
            alignment: Alignment.center,
            child: Icon(
              iconFromKey(product.iconKey),
              size: 24,
              color: design.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        product.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: design.textHigh,
                        ),
                      ),
                    ),
                    if (product.isPopular) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.local_fire_department_rounded,
                        color: design.warning,
                        size: 14,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  category?.name ?? '',
                  style: TextStyle(color: design.textMedium, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      MoneyFormatter.format(product.price),
                      style: TextStyle(
                        color: design.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Stock reads as a status, not a number in a list: an
                    // untracked product says so rather than showing a blank,
                    // and low / empty counts pick up the semantic colours so
                    // they are scannable down a long catalogue.
                    Flexible(
                      child: Text(
                        product.stock == null
                            ? l10n.productNotTracked
                            : l10n.productStockValue(product.stock!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: product.stock == null
                              ? FontWeight.w400
                              : FontWeight.w700,
                          color: product.isOutOfStock
                              ? design.error
                              : product.isLowStock
                              ? design.warning
                              : design.textMedium,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppDimensions.space8),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch.adaptive(
                value: product.available,
                onChanged: (_) => onToggle(),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: design.error,
                  size: 20,
                ),
                onPressed: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CategoriesTab extends ConsumerWidget {
  const _CategoriesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final categories = ref.watch(categoriesProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: categories.when(
        loading: () => Center(child: LoadingIndicator.skeleton(lines: 5)),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: l10n.commonError,
          subtitle: '$e',
        ),
        data: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.sell_rounded,
              title: l10n.categoryEmpty,
              subtitle: l10n.categoryAdd,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(AppDimensions.space16),
            itemCount: list.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: AppDimensions.space8),
            itemBuilder: (_, i) {
              final c = list[i];
              return _CategoryTile(
                category: c,
                onTap: () => _openForm(context, ref, existing: c),
                onDelete: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    // See the comment on the product-delete dialog above —
                    // same navigator mismatch between showDialog's root
                    // navigator and this outer context's nested one.
                    builder: (dialogContext) => AlertDialog(
                      title: Text(l10n.categoryDeleteConfirm),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(false),
                          child: Text(l10n.commonCancel),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(true),
                          child: Text(l10n.commonDelete),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    await ref.read(categoriesProvider.notifier).delete(c.id);
                  }
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.categoryAdd),
      ),
    );
  }

  void _openForm(BuildContext context, WidgetRef ref, {Category? existing}) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => _CategoryFormSheet(existing: existing),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.onTap,
    required this.onDelete,
  });

  final Category category;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      onTap: onTap,
      padding: const EdgeInsets.all(AppDimensions.space14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: design.primaryContainer.withValues(alpha: 0.6),
              borderRadius: AppDimensions.radiusMd,
            ),
            alignment: Alignment.center,
            child: Icon(
              iconFromKey(category.iconKey),
              size: 22,
              color: design.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Text(
              category.name,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: design.textHigh,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline_rounded, color: design.error),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _CategoryFormSheet extends ConsumerStatefulWidget {
  const _CategoryFormSheet({this.existing});
  final Category? existing;

  @override
  ConsumerState<_CategoryFormSheet> createState() => _CategoryFormSheetState();
}

class _CategoryFormSheetState extends ConsumerState<_CategoryFormSheet> {
  late final _nameCtrl = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late String _iconKey = widget.existing?.iconKey ?? 'restaurant';

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final isEdit = widget.existing != null;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppDimensions.space16,
          right: AppDimensions.space16,
          bottom:
              MediaQuery.of(context).viewInsets.bottom + AppDimensions.space16,
          top: AppDimensions.space4,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isEdit ? l10n.categoryEdit : l10n.categoryAdd,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: design.textHigh,
              ),
            ),
            const SizedBox(height: AppDimensions.space16),
            GlassTextField(
              controller: _nameCtrl,
              label: l10n.categoryName,
              autofocus: true,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: AppDimensions.space14),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppDimensions.space6),
                child: Text(
                  l10n.categoryEmoji,
                  style: TextStyle(
                    color: design.textMedium,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            GlassCard.solid(
              padding: const EdgeInsets.all(AppDimensions.space8),
              child: Wrap(
                spacing: AppDimensions.space8,
                runSpacing: AppDimensions.space8,
                children: iconKeys.map((e) {
                  final selected = _iconKey == e;
                  return GestureDetector(
                    onTap: () => setState(() => _iconKey = e),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: selected
                            ? design.primaryContainer
                            : design.glassTint.withValues(
                                alpha: design.glassOpacity,
                              ),
                        borderRadius: AppDimensions.radiusMd,
                        border: Border.all(
                          color: selected
                              ? design.primary
                              : design.glassBorder.withValues(alpha: 0.4),
                          width: selected ? 1.5 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        iconFromKey(e),
                        size: 22,
                        color: selected
                            ? design.onPrimaryContainer
                            : design.textMedium,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: AppDimensions.space20),
            FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final existing = widget.existing;
    await ref
        .read(categoriesProvider.notifier)
        .upsert(
          Category(
            id: existing?.id ?? 'cat_${DateTime.now().millisecondsSinceEpoch}',
            name: name,
            emoji: existing?.emoji ?? '🍽️',
            iconKey: _iconKey,
            sortOrder: existing?.sortOrder ?? 100,
            isPopular: existing?.isPopular ?? false,
          ),
        );
    if (mounted) Navigator.of(context).pop();
  }
}

/// Reusable option groups — spice level, toppings, sugar level — attached to
/// products from [ProductFormSheet], not redefined per product.
class _ModifiersTab extends ConsumerWidget {
  const _ModifiersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final groups = ref.watch(modifierGroupsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RefreshIndicator(
        onRefresh: () async =>
            ref.read(modifierGroupsProvider.notifier).refresh(),
        child: groups.when(
          loading: () => Center(child: LoadingIndicator.skeleton(lines: 5)),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline_rounded,
            title: l10n.commonError,
            subtitle: '$e',
          ),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: [
                  EmptyState(
                    icon: Icons.tune_rounded,
                    title: l10n.modifierGroupEmpty,
                    subtitle: l10n.modifierGroupEmptyHint,
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(AppDimensions.space16),
              itemCount: list.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: AppDimensions.space8),
              itemBuilder: (_, i) {
                final g = list[i];
                return _ModifierGroupTile(
                  group: g,
                  onTap: () => _openForm(context, ref, existing: g),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.modifierGroupAdd),
      ),
    );
  }

  void _openForm(BuildContext context, WidgetRef ref, {ModifierGroup? existing}) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => _ModifierGroupFormSheet(existing: existing),
    );
  }
}

class _ModifierGroupTile extends ConsumerWidget {
  const _ModifierGroupTile({required this.group, required this.onTap});
  final ModifierGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final design = context.design;
    final l10n = context.l10n;
    final options = ref.watch(modifierOptionsForProvider(group.id));

    return GlassCard.solid(
      onTap: onTap,
      padding: const EdgeInsets.all(AppDimensions.space14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: design.primaryContainer.withValues(alpha: 0.6),
              borderRadius: AppDimensions.radiusMd,
            ),
            alignment: Alignment.center,
            child: Icon(
              group.selectionType == ModifierSelectionType.multiple
                  ? Icons.checklist_rounded
                  : Icons.radio_button_checked_rounded,
              size: 22,
              color: design.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: design.textHigh,
                        ),
                      ),
                    ),
                    if (group.required) ...[
                      const SizedBox(width: 6),
                      _Pill(label: l10n.modifierRequired, color: design.warning),
                    ],
                    if (!group.active) ...[
                      const SizedBox(width: 6),
                      _Pill(label: l10n.productUnavailable, color: design.error),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  options.maybeWhen(
                    data: (list) => [
                      group.selectionType == ModifierSelectionType.multiple
                          ? l10n.modifierSelectionMultiple
                          : l10n.modifierSelectionSingle,
                      l10n.modifierOptionCount(list.length),
                    ].join(' · '),
                    orElse: () => '',
                  ),
                  style: TextStyle(color: design.textMedium, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
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
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ModifierGroupFormSheet extends ConsumerStatefulWidget {
  const _ModifierGroupFormSheet({this.existing});
  final ModifierGroup? existing;

  @override
  ConsumerState<_ModifierGroupFormSheet> createState() =>
      _ModifierGroupFormSheetState();
}

class _ModifierGroupFormSheetState
    extends ConsumerState<_ModifierGroupFormSheet> {
  late final _nameCtrl = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final _maxSelectCtrl = TextEditingController(
    text: widget.existing?.maxSelect != null
        ? '${widget.existing!.maxSelect}'
        : '',
  );
  late ModifierSelectionType _selectionType =
      widget.existing?.selectionType ?? ModifierSelectionType.single;
  late bool _required = widget.existing?.required ?? false;
  late bool _active = widget.existing?.active ?? true;

  /// Working copy of the option list, edited in place and written as a unit
  /// on save — same reasoning as `_VariantEditor` in `ProductFormSheet`.
  List<ModifierOption> _options = const [];
  bool _optionsLoaded = false;
  bool _hadOptions = false;

  String? _maxSelectError;

  @override
  void initState() {
    super.initState();
    final id = widget.existing?.id;
    if (id == null) {
      _optionsLoaded = true;
      return;
    }
    ModifierRepository.instance.optionsFor(id).then((options) {
      if (!mounted) return;
      setState(() {
        _options = options;
        _hadOptions = options.isNotEmpty;
        _optionsLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _maxSelectCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final isEdit = widget.existing != null;
    final noActiveOptions = _options.every((o) => !o.active) || _options.isEmpty;

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
              isEdit ? l10n.modifierGroupEdit : l10n.modifierGroupAdd,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: design.textHigh,
              ),
            ),
            const SizedBox(height: AppDimensions.space16),
            GlassTextField(
              controller: _nameCtrl,
              label: l10n.modifierGroupName,
              autofocus: !isEdit,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: AppDimensions.space14),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppDimensions.space6),
                child: Text(
                  l10n.modifierSelectionType,
                  style: TextStyle(
                    color: design.textMedium,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            SegmentedButton<ModifierSelectionType>(
              segments: [
                ButtonSegment(
                  value: ModifierSelectionType.single,
                  label: Text(l10n.modifierSelectionSingle),
                  icon: const Icon(Icons.radio_button_checked_rounded),
                ),
                ButtonSegment(
                  value: ModifierSelectionType.multiple,
                  label: Text(l10n.modifierSelectionMultiple),
                  icon: const Icon(Icons.checklist_rounded),
                ),
              ],
              selected: {_selectionType},
              onSelectionChanged: (s) => setState(() {
                _selectionType = s.first;
                // A single-select group is implicitly capped at one; a typed
                // limit from when it was 'multiple' would be misleading here.
                if (_selectionType == ModifierSelectionType.single) {
                  _maxSelectCtrl.clear();
                  _maxSelectError = null;
                }
              }),
            ),
            const SizedBox(height: AppDimensions.space12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _required,
              onChanged: (v) => setState(() => _required = v),
              title: Text(l10n.modifierRequired),
              subtitle: Text(
                l10n.modifierRequiredHint,
                style: TextStyle(fontSize: 11, color: design.textLow),
              ),
            ),
            if (_required && noActiveOptions) ...[
              const SizedBox(height: AppDimensions.space8),
              Container(
                padding: const EdgeInsets.all(AppDimensions.space10),
                decoration: BoxDecoration(
                  color: design.warningContainer,
                  borderRadius: AppDimensions.radiusMd,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: design.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.modifierRequiredNoActiveOptions,
                        style: TextStyle(fontSize: 11, color: design.textHigh),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_selectionType == ModifierSelectionType.multiple) ...[
              const SizedBox(height: AppDimensions.space12),
              GlassTextField(
                controller: _maxSelectCtrl,
                label: l10n.modifierMaxSelect,
                hint: l10n.modifierMaxSelectHint,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setState(() => _maxSelectError = null),
              ),
              if (_maxSelectError != null) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _maxSelectError!,
                    style: TextStyle(color: design.error, fontSize: 11),
                  ),
                ),
              ],
            ],
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: Text(_active ? l10n.productAvailable : l10n.productUnavailable),
            ),
            const SizedBox(height: AppDimensions.space16),
            _ModifierOptionEditor(
              options: _options,
              enabled: _optionsLoaded,
              onChanged: (o) => setState(() => _options = o),
            ),
            const SizedBox(height: AppDimensions.space20),
            FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.commonRequired)));
      return;
    }
    // maxSelect only applies to 'multiple' and, when typed, must be >= 1 — a
    // cap of 0 would mean "may select at most zero", which is nonsensical and
    // different from leaving it blank (unlimited).
    final maxSelectText = _maxSelectCtrl.text.trim();
    int? maxSelect;
    if (_selectionType == ModifierSelectionType.multiple &&
        maxSelectText.isNotEmpty) {
      maxSelect = int.tryParse(maxSelectText);
      if (maxSelect == null || maxSelect < 1) {
        setState(() => _maxSelectError = context.l10n.modifierMaxSelectInvalid);
        return;
      }
    }

    final existing = widget.existing;
    final id = existing?.id ?? 'mg_${DateTime.now().millisecondsSinceEpoch}';
    await ref.read(modifierGroupsProvider.notifier).upsertGroup(
      ModifierGroup(
        id: id,
        name: name,
        selectionType: _selectionType,
        required: _required,
        maxSelect: maxSelect,
        sortOrder: existing?.sortOrder ?? 100,
        active: _active,
      ),
    );
    // After the group, so the FK has something to point at on a new one —
    // same ordering reason as ProductFormSheet's variant save.
    if (_options.isNotEmpty || _hadOptions) {
      await ModifierRepository.instance.replaceOptions(id, _options);
      ref.invalidate(modifierOptionsForProvider(id));
      ref.invalidate(modifierOptionsByGroupProvider);
    }
    if (mounted) Navigator.of(context).pop();
  }
}

/// Edits a modifier group's option list in place — the same shape as
/// `_VariantEditor` in `ProductFormSheet`, minus the base-price total (there
/// is no product in this context to add it to) and with the delta field
/// restricted to non-negative values.
class _ModifierOptionEditor extends StatelessWidget {
  const _ModifierOptionEditor({
    required this.options,
    required this.enabled,
    required this.onChanged,
  });

  final List<ModifierOption> options;
  final bool enabled;
  final ValueChanged<List<ModifierOption>> onChanged;

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
              l10n.modifierOptions,
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
              label: Text(l10n.modifierOptionAdd),
            ),
          ],
        ),
        if (options.isEmpty)
          Text(
            l10n.modifierOptionsHint,
            style: TextStyle(color: design.textLow, fontSize: 11),
          )
        else
          for (var i = 0; i < options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _ModifierOptionRow(
                option: options[i],
                onEdit: () => _edit(context, i),
                onToggleActive: () {
                  final next = [...options];
                  next[i] = next[i].copyWith(active: !next[i].active);
                  onChanged(next);
                },
                onRemove: () {
                  final next = [...options]..removeAt(i);
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
      builder: (_) => const _ModifierOptionDialog(),
    );
    if (result == null) return;
    onChanged([
      ...options,
      ModifierOption(
        id: 'mo_${DateTime.now().microsecondsSinceEpoch}',
        groupId: '',
        name: result.$1,
        priceDelta: result.$2,
        sortOrder: options.length,
      ),
    ]);
  }

  /// Renames/repriced an EXISTING option in place — same id, same
  /// active/sortOrder — rather than the remove-then-recreate a cashier's
  /// order history would otherwise have to survive. `order_item_modifiers`
  /// snapshots the name/price at sale time regardless (see
  /// `OrderRepository.create`), so editing an option here never rewrites a
  /// past receipt; it only changes what the NEXT sale offers.
  Future<void> _edit(BuildContext context, int index) async {
    final result = await showDialog<(String, int)>(
      context: context,
      builder: (_) => _ModifierOptionDialog(initial: options[index]),
    );
    if (result == null) return;
    final next = [...options];
    next[index] = next[index].copyWith(name: result.$1, priceDelta: result.$2);
    onChanged(next);
  }
}

class _ModifierOptionRow extends StatelessWidget {
  const _ModifierOptionRow({
    required this.option,
    required this.onEdit,
    required this.onToggleActive,
    required this.onRemove,
  });

  final ModifierOption option;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      // Tapping the row edits it — same convention as the register and table
      // management lists. The toggle/remove icon buttons underneath still
      // take the tap for themselves; nothing here needs to guard against
      // both firing.
      onTap: onEdit,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space12,
        vertical: AppDimensions.space8,
      ),
      child: Opacity(
        opacity: option.active ? 1 : 0.5,
        child: Row(
          children: [
            Expanded(
              child: Text(
                option.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: design.textHigh,
                ),
              ),
            ),
            Text(
              option.priceDelta == 0
                  ? '+${MoneyFormatter.format(0)}'
                  : '+${MoneyFormatter.format(option.priceDelta)}',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: design.primary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: option.active
                  ? context.l10n.productAvailable
                  : context.l10n.productUnavailable,
              onPressed: onToggleActive,
              icon: Icon(
                option.active
                    ? Icons.toggle_on_rounded
                    : Icons.toggle_off_outlined,
                size: 22,
                color: option.active ? design.success : design.textMedium,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
              icon: Icon(
                Icons.close_rounded,
                size: 18,
                color: design.textMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModifierOptionDialog extends StatefulWidget {
  const _ModifierOptionDialog({this.initial});

  /// Null when adding a new option. Set when editing one already in the
  /// working list — the dialog prefills from it instead of starting blank,
  /// so a name typo or a wrong extra price no longer means remove-then-
  /// recreate (and losing whatever position/active state the row had).
  final ModifierOption? initial;

  @override
  State<_ModifierOptionDialog> createState() => _ModifierOptionDialogState();
}

class _ModifierOptionDialogState extends State<_ModifierOptionDialog> {
  late final _nameCtrl = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final _deltaCtrl = TextEditingController(
    text: '${widget.initial?.priceDelta ?? 0}',
  );

  @override
  void dispose() {
    _nameCtrl.dispose();
    _deltaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isEdit = widget.initial != null;
    return AlertDialog(
      title: Text(isEdit ? l10n.modifierOptionEdit : l10n.modifierOptionAdd),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: l10n.modifierOptionName),
          ),
          const SizedBox(height: AppDimensions.space12),
          TextField(
            controller: _deltaCtrl,
            keyboardType: TextInputType.number,
            // Non-negative only, unlike the variant dialog's signed field:
            // none of spice level / toppings / sugar level / ice level has a
            // realistic discount use case, so this removes "final price went
            // negative" as a possibility at the source.
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.modifierOptionPriceDelta,
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
          child: Text(isEdit ? l10n.commonSave : l10n.commonAdd),
        ),
      ],
    );
  }
}
