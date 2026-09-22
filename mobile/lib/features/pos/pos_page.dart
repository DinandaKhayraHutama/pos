import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/localization/till_error.dart';
import '../../data/device/till_coordinator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/authorize_sheet.dart';
import '../../core/auth/permissions.dart';
import '../../core/auth/role_display.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/icon_map.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_chip.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../data/device/till_binding.dart';
import '../../data/models/enums.dart';
import '../../data/models/modifier_group.dart';
import '../../data/models/modifier_option.dart';
import '../../data/models/product.dart';
import '../../data/models/product_variant.dart';
import '../../providers/cart_provider.dart';
import '../../providers/catalog_provider.dart';
import '../../providers/modifier_provider.dart';
import '../../providers/outlet_provider.dart';
import '../../providers/settings_provider.dart';
import '../../core/widgets/app_snack_bar.dart';
import '../shift/shift_page.dart' show PosSessionOpenCard;
import 'cart_panel.dart';
import 'checkout_sheet.dart';
import 'modifier_picker_sheet.dart';
import 'product_card.dart';
import 'outlet_picker_sheet.dart';
import 'table_picker_sheet.dart';
import 'variant_picker_sheet.dart';

/// Widest a product tile may get before the grid adds another column. Keeps
/// two columns on a phone and grows to three or more on a tablet.
const double _maxTileWidth = 200;

/// Main POS screen - browse products, build cart, checkout.
class PosPage extends ConsumerStatefulWidget {
  const PosPage({super.key});

  @override
  ConsumerState<PosPage> createState() => _PosPageState();
}

class _PosPageState extends ConsumerState<PosPage> {
  String? _activeCategory;
  String _query = '';
  bool _showPopular = false;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).valueOrNull;
    // Selling needs an open POS session. This renders INSIDE PosPage rather
    // than redirecting to `/shift` — `/` is a `ShellRoute` tab, and a redirect
    // to that pushed route took `MainShell` (bottom nav / rail) down with it,
    // leaving a cashier who had just closed their drawer with no way to
    // switch tabs. Only `== false` gates (not `!= true`): settings is only
    // ever null for a single loading frame the router itself already blocks
    // on, and treating that frame as "show the catalog" rather than "show the
    // gate" matches the permissive-on-unknown default `MainShell` uses for
    // tab visibility.
    if (settings?.hasPosSession == false) {
      return const _SessionGate();
    }
    final width = MediaQuery.sizeOf(context).width;
    final isTablet = width >= AppDimensions.tabletWidth;
    return isTablet ? _buildSplit(context) : _buildPhone(context);
  }

  // Phone layout -------------------------------------------------------------
  Widget _buildPhone(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final pb1Rate = settings?.pb1Rate ?? 0;
    final serviceChargeRate = (settings?.serviceChargeEnabled ?? false)
        ? settings!.serviceChargeRate
        : 0.0;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _posHeader(onCartTap: () => _openCartSheet(context)),
            Expanded(child: _catalogBody(context)),
          ],
        ),
      ),
      // No placeholder bar when the cart is empty: MainShell already renders
      // the NavigationBar below this Scaffold, so reserving height here only
      // cut ~72dp off the catalog and left a dead band above the tabs.
      bottomNavigationBar: cart.isEmpty
          ? null
          : SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(
                AppDimensions.space12,
                6,
                AppDimensions.space12,
                6,
              ),
              child: _OpenCartBar(
                itemCount: cart.itemCount,
                total: cart.totalFor(
                  pb1Rate: pb1Rate,
                  serviceChargeRate: serviceChargeRate,
                ),
                onTap: () => _openCartSheet(context),
              ),
            ),
    );
  }

  // Tablet / desktop layout --------------------------------------------------
  Widget _buildSplit(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Column(
                children: [
                  _posHeader(onCartTap: () => _openCheckout(context)),
                  Expanded(child: _catalogBody(context)),
                ],
              ),
            ),
            // CartPanel itself is restyled in Task 17; keep its surface
            // container here so the panel still reads as a distinct column
            // over the shell-provided AppBackground substrate.
            Container(
              width: AppDimensions.cartPanelWidth,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                border: Border(
                  left: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: CartPanel(onCheckout: () => _openCheckout(context)),
            ),
          ],
        ),
      ),
    );
  }

  // Header (title + search + categories) -------------------------------------
  Widget _posHeader({required VoidCallback onCartTap}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_topBar(onCartTap), _searchField(), _categoryChips()],
    );
  }

  Widget _topBar(VoidCallback onCartTap) {
    final design = context.design;
    final settings = ref.watch(settingsProvider).valueOrNull;
    final cartCount = ref.watch(cartProvider.select((c) => c.itemCount));
    // Which branch this device is standing in. Named on the sell screen rather
    // than only in Settings because it silently decides which shelf the stock
    // comes off and whose takings the sale lands in — a tablet pointed at the
    // wrong shop looks completely normal all day.
    final outlet = ref.watch(activeOutletProvider).valueOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimensions.space16,
        AppDimensions.space8,
        AppDimensions.space8,
        0,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: GlassCard.solid(
              padding: EdgeInsets.zero,
              radius: const BorderRadius.all(Radius.circular(20)),
              child: Center(
                child: Icon(
                  Icons.storefront_rounded,
                  size: 20,
                  color: design.primary,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  settings?.storeName ?? 'POS',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: design.textHigh,
                    height: 1.1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (outlet != null) ...[
                      // A pill, not the grey subtitle it used to be. Which
                      // branch this device is standing in decides which shelf
                      // the stock comes off and whose takings the sale lands
                      // in, and a cashier had no way to notice it was wrong.
                      _OutletChip(
                        name: outlet.name,
                        // Only someone who may manage branches may move the
                        // device between them — otherwise a cashier could
                        // quietly sell one shop's stock from another's floor.
                        // An activated device is bound to its outlet, so no
                        // one moves it.
                        onTap:
                            settings?.can(AppPermission.manageOutlets) ==
                                    true &&
                                TillBinding.current == null
                            ? () => showGlassSheet<void>(
                                context: context,
                                builder: (_) => const OutletPickerSheet(),
                              )
                            : null,
                      ),
                      const SizedBox(width: AppDimensions.space6),
                    ],
                    // Which till, stated next to which branch. Two registers
                    // at one counter look identical on screen, and the drawer
                    // this sale lands in is decided by which one this is —
                    // exactly the same class of silent error as the outlet.
                    if (settings != null &&
                        settings.posRegisterName.isNotEmpty) ...[
                      _OutletChip(
                        name: settings.posRegisterName,
                        icon: Icons.point_of_sale_rounded,
                      ),
                      const SizedBox(width: AppDimensions.space6),
                    ],
                    Flexible(
                      child: Text(
                        _greeting(),
                        style: TextStyle(
                          color: design.textMedium,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Who the next sale will be attributed to, and the way to change it.
          // On screen rather than buried in Settings because it is the answer
          // to "whose name is on this receipt" — a question that only gets
          // asked after the receipt is already printed.
          if (settings != null) _OnDutyChip(settings: settings),
          IconButton(
            onPressed: onCartTap,
            icon: Badge(
              isLabelVisible: cartCount > 0,
              label: Text('$cartCount'),
              backgroundColor: design.primary,
              textColor: design.onPrimary,
              child: const Icon(Icons.shopping_cart_checkout_rounded),
            ),
          ),
        ],
      ),
    );
  }

  String _greeting() {
    final l10n = context.l10n;
    final h = DateTime.now().hour;
    if (h < 11) return l10n.posGreetingMorning;
    if (h < 15) return l10n.posGreetingNoon;
    if (h < 19) return l10n.posGreetingAfternoon;
    return l10n.posGreetingEvening;
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimensions.space16,
        AppDimensions.space12,
        AppDimensions.space16,
        0,
      ),
      child: GlassTextField(
        onChanged: (v) => setState(() => _query = v.toLowerCase()),
        hint: context.l10n.posSearchProduct,
        prefix: Icons.search_rounded,
        textInputAction: TextInputAction.search,
      ),
    );
  }

  Widget _categoryChips() {
    final categories = ref.watch(categoriesProvider);
    final l10n = context.l10n;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          AppDimensions.space16,
          AppDimensions.space10,
          AppDimensions.space16,
          0,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GlassFilterChip(
              label: l10n.categoryAll,
              icon: Icons.restaurant_menu_rounded,
              selected: _activeCategory == null && !_showPopular,
              onTap: () => setState(() {
                _activeCategory = null;
                _showPopular = false;
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GlassFilterChip(
              label: l10n.categoryPopular,
              icon: Icons.local_fire_department_rounded,
              selected: _showPopular,
              onTap: () => setState(() {
                _activeCategory = null;
                _showPopular = true;
              }),
            ),
          ),
          ...categories.maybeWhen(
            data: (data) => data
                .map(
                  (c) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GlassFilterChip(
                      label: c.name,
                      icon: iconFromKey(c.iconKey),
                      selected: _activeCategory == c.id,
                      onTap: () => setState(() {
                        _activeCategory = c.id;
                        _showPopular = false;
                      }),
                    ),
                  ),
                )
                .toList(),
            orElse: () => <Widget>[],
          ),
        ],
      ),
    );
  }

  // Catalog grid -------------------------------------------------------------
  Widget _catalogBody(BuildContext context) {
    final products = ref.watch(productsProvider);
    final cart = ref.watch(cartProvider);
    // Empty until loaded, so the grid paints immediately and cards simply
    // gain their variant affordance a frame later. Blocking the whole
    // catalogue on a second query would be a visible stall for a detail that
    // only six of twenty-six products have.
    final variantsByProduct =
        ref.watch(productVariantsProvider).valueOrNull ?? const {};
    // Same "empty until loaded" reasoning as variants — both bulk providers
    // are read here, once for the whole grid, so ModifierPickerSheet opens
    // fully resolved and never fires a query of its own.
    final modifierGroupsByProduct =
        ref.watch(productModifierGroupsProvider).valueOrNull ??
        const <String, List<ModifierGroup>>{};
    final modifierOptionsByGroup =
        ref.watch(modifierOptionsByGroupProvider).valueOrNull ??
        const <String, List<ModifierOption>>{};
    // Which of an attached group's options THIS product actually offers —
    // "Topping" stays one reusable group, but a food item and a coffee
    // attached to it can each be scoped to a different subset. See
    // ModifierRepository's "Product option scope" section.
    final modifierOptionScopeByProduct =
        ref.watch(productModifierOptionScopeProvider).valueOrNull ??
        const <String, Set<String>>{};
    final defaults = ref.watch(productModifierDefaultsProvider);
    final configuration = <AsyncValue<Object>>[
      ref.watch(productVariantsProvider),
      ref.watch(productModifierGroupsProvider),
      ref.watch(modifierOptionsByGroupProvider),
      ref.watch(productModifierOptionScopeProvider),
      defaults,
    ];
    if (configuration.any((v) => v.hasError)) {
      return Center(
        child: TextButton(
          onPressed: () {
            ref.invalidate(productVariantsProvider);
            ref.invalidate(productModifierGroupsProvider);
            ref.invalidate(modifierOptionsByGroupProvider);
            ref.invalidate(productModifierOptionScopeProvider);
            ref.invalidate(productModifierDefaultsProvider);
          },
          child: Text(context.l10n.commonRetry),
        ),
      );
    }
    if (configuration.any((v) => v.isLoading)) return const LoadingIndicator();

    final filtered = products.maybeWhen(
      data: (all) {
        var out = all.where((p) => p.available).toList();
        if (_query.isNotEmpty) {
          out = out
              .where((p) => p.name.toLowerCase().contains(_query))
              .toList();
        }
        if (_showPopular) {
          out = out.where((p) => p.isPopular).toList();
        } else if (_activeCategory != null) {
          out = out.where((p) => p.categoryId == _activeCategory).toList();
        }
        return out;
      },
      orElse: () => <Product>[],
    );

    if (products.isLoading) return const LoadingIndicator();
    if (products.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppDimensions.space20),
          child: Text(
            '${products.error}',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.design.error),
          ),
        ),
      );
    }
    if (filtered.isEmpty) {
      return _emptyCatalog();
    }

    // The column count is worked out here rather than handed to
    // SliverGridDelegateWithMaxCrossAxisExtent because the tile height depends
    // on the tile *width* (see [productCardExtent]). Letting the delegate pick
    // the width internally would mean guessing it back - and a wrong guess is
    // exactly what used to clip the cards.
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - AppDimensions.space16 * 2;
        if (available <= 0) return const SizedBox.shrink();

        final columns = math.max(
          2,
          (available / (_maxTileWidth + AppDimensions.space10)).ceil(),
        );
        final tileWidth = math.max(
          1.0,
          (available - AppDimensions.space10 * (columns - 1)) / columns,
        );

        return GridView.builder(
          controller: _scrollController,
          // The cart bar lives in bottomNavigationBar rather than on top of
          // the grid, so the catalog only needs normal breathing room here.
          padding: const EdgeInsets.fromLTRB(
            AppDimensions.space16,
            AppDimensions.space8,
            AppDimensions.space16,
            AppDimensions.space16,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: AppDimensions.space10,
            mainAxisSpacing: AppDimensions.space10,
            mainAxisExtent: productCardExtent(context, tileWidth),
          ),
          itemCount: filtered.length,
          itemBuilder: (context, i) {
            final p = filtered[i];
            // Summed across variants: the badge answers "how many of this
            // product are in the cart", and a Large plus a Regular is two.
            final qty = cart.lines
                .where((l) => l.product.id == p.id)
                .fold<int>(0, (a, l) => a + l.quantity);
            final variants = variantsByProduct[p.id] ?? const [];
            final scopedOptionIds =
                modifierOptionScopeByProduct[p.id] ?? const <String>{};
            final groups = <ModifierGroupOffer>[
              for (final g
                  in modifierGroupsByProduct[p.id] ?? const <ModifierGroup>[])
                (
                  group: g,
                  options:
                      (modifierOptionsByGroup[g.id] ?? const <ModifierOption>[])
                          .where(
                            (o) => o.active && scopedOptionIds.contains(o.id),
                          )
                          .toList(),
                ),
            ];
            return ProductCard(
              product: p,
              inCartQty: qty,
              // One glyph for "tapping this opens a picker first", whichever
              // kind of picker it turns out to be — the cashier only needs to
              // know a sheet is coming, not why.
              hasVariants: variants.isNotEmpty || groups.isNotEmpty,
              onAdd: () => _addToCart(
                p,
                variants,
                groups,
                defaults.valueOrNull?[p.id] ?? const {},
              ),
              // Steps the LAST matching line rather than a product id: with
              // variants there is no single line to decrement, and taking one
              // off the most recently touched size is what the cashier means.
              onDecrement: () {
                final line = cart.lines.lastWhere(
                  (l) => l.product.id == p.id,
                  orElse: () => CartLine(product: p, quantity: 0),
                );
                ref.read(cartProvider.notifier).decrement(line.key);
              },
            );
          },
        );
      },
    );
  }

  /// Adds [product], asking which variant first when it has any, then which
  /// modifiers when it has any of those too.
  ///
  /// A product with neither still adds on a single tap — each picker only
  /// appears where there is genuinely a choice, so the common case does not
  /// pay for the uncommon one.
  Future<void> _addToCart(
    Product product,
    List<ProductVariant> variants,
    List<ModifierGroupOffer> groups,
    Set<String> defaultIds,
  ) async {
    ProductVariant? variant;
    if (variants.isNotEmpty) {
      variant = await showGlassSheet<ProductVariant>(
        context: context,
        builder: (_) =>
            VariantPickerSheet(product: product, variants: variants),
      );
      if (variant == null) return; // cashier backed out
    }

    if (!mounted) return;
    var modifiers = selectionsForOffers(groups, defaultIds);
    if (needsModifierSelection(groups, modifiers)) {
      final chosen = await showGlassSheet<List<SelectedModifier>>(
        context: context,
        builder: (_) => ModifierPickerSheet(
          product: product,
          basePrice: product.price + (variant?.priceDelta ?? 0),
          groups: groups,
          initialSelections: modifiers,
        ),
      );
      if (chosen == null) return; // cashier backed out
      modifiers = chosen;
    }
    if (!mounted) return;
    ref
        .read(cartProvider.notifier)
        .add(product, variant: variant, modifiers: modifiers);
  }

  Widget _emptyCatalog() {
    final design = context.design;
    final l10n = context.l10n;
    return Center(
      child: GlassCard.solid(
        padding: const EdgeInsets.all(AppDimensions.space28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: design.primary.withValues(alpha: 0.12),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.search_off_rounded,
                size: 36,
                color: design.primary,
              ),
            ),
            const SizedBox(height: AppDimensions.space12),
            Text(
              l10n.posNoProducts,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: design.textHigh,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _query.isNotEmpty ? '"$_query"' : l10n.posCartEmptyHint,
              style: TextStyle(color: design.textMedium, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // Cart sheet & checkout ----------------------------------------------------
  void _openCartSheet(BuildContext context) {
    final isTablet =
        MediaQuery.sizeOf(context).width >= AppDimensions.tabletWidth;
    if (isTablet) {
      _openCheckout(context);
      return;
    }
    // The cart body is a [DraggableScrollableSheet], which sizes itself as a
    // fraction of the available height and therefore needs a BOUNDED height.
    // [showGlassSheet] wraps its body in a `mainAxisSize.min` Column (inside
    // [GlassSheet]) that passes an unbounded max height to non-flex children,
    // starving the DSS of a finite height and tripping a `hasSize` layout
    // assertion. So the cart opens via a plain [showModalBottomSheet] — which
    // gives the DSS bounded constraints — and the DSS body wears the glass
    // surface directly ([GlassSurface] adds no sizing Column). [CartPanel] in
    // compact mode paints its own grabber handle, so the sheet keeps exactly
    // one.
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.98,
        builder: (_, controller) => GlassSurface(
          child: CartPanel(
            compact: true,
            scrollController: controller,
            onCheckout: () => _openCheckout(context),
          ),
        ),
      ),
    );
  }

  void _openCheckout(BuildContext context) {
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    // Only a store with a floor plan can be asked which table this is for.
    // Without one this guard would open a picker over an empty board and the
    // sale could never be completed.
    final tableService =
        ref.read(settingsProvider).valueOrNull?.tableServiceEnabled ?? true;
    if (tableService && cart.type == OrderType.dineIn && cart.table == null) {
      _pickTable(context);
      return;
    }
    showGlassSheet<void>(
      context: context,
      builder: (_) => const CheckoutSheet(),
    );
  }

  Future<void> _pickTable(BuildContext context) async {
    await showGlassSheet<void>(
      context: context,
      builder: (_) => const TablePickerSheet(),
    );
    if (context.mounted && ref.read(cartProvider).table != null) {
      _openCheckout(context);
    }
  }
}

/// What the New Sale tab shows in place of the catalogue while this device
/// holds no POS session.
///
/// Deliberately stays INSIDE `PosPage` — same `Scaffold`-in-`MainShell`
/// arrangement every other tab uses — rather than navigating anywhere: the
/// bottom nav / rail is painted by `MainShell` around `widget.child`
/// regardless of what that child shows, so the moment this stopped being a
/// redirect the "stuck with no way to switch tabs" bug stopped being
/// reachable. A cashier can freely tap Orders, Tables or Settings from here
/// and come straight back to the same gate.
///
/// `GlassAppBar` here (unlike the catalogue's own `_posHeader`) matches how
/// every OTHER tab titles itself, so this reads as "the New Sale tab, in an
/// empty-till state" rather than as a different screen.
class _SessionGate extends StatelessWidget {
  const _SessionGate();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: GlassAppBar(title: l10n.navPos),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppDimensions.space16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: const PosSessionOpenCard(),
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenCartBar extends StatelessWidget {
  const _OpenCartBar({
    required this.itemCount,
    required this.total,
    required this.onTap,
  });
  final int itemCount;
  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    // The cart bar is the primary checkout CTA, so it paints in solid
    // [BrandColors.primary] - not a glass tint. GlassCard.solid multiplies the
    // tint by [BrandColors.glassOpacity] (0.10 in dark mode), which left the
    // bar too faint to read as a CTA after dark. Solid primary matches the
    // filled stepper and stays bold in both light and dark.
    return Material(
      color: design.primary,
      borderRadius: AppDimensions.radiusLg,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppDimensions.radiusLg,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimensions.space14,
            vertical: AppDimensions.space12,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: design.onPrimary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$itemCount',
                  style: TextStyle(
                    color: design.onPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: AppDimensions.space12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.posCheckout,
                      style: TextStyle(
                        color: design.onPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      l10n.posCartItems(itemCount),
                      style: TextStyle(
                        color: design.onPrimary.withValues(alpha: 0.8),
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Text(
                MoneyFormatter.format(total),
                style: TextStyle(
                  color: design.onPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, color: design.onPrimary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows who is on the till and swaps them out on a PIN.
///
/// The multi-cashier handover, in one tap. It is a compact avatar on a phone
/// and gains the name at tablet width — a till at 1280px has the room, and a
/// name is what makes the attribution checkable at a glance.
/// Where this device is standing — the branch, and the till within it.
///
/// Tappable only for someone who may manage outlets; for everyone else it is
/// a label they can read but not change — which is the point. A cashier needs
/// to KNOW where they are, not to be able to move the till somewhere else. The
/// register chip is never tappable: moving between tills means closing a
/// drawer, which is the shift screen's job.
class _OutletChip extends StatelessWidget {
  const _OutletChip({
    required this.name,
    this.onTap,
    this.icon = Icons.storefront_rounded,
  });

  final String name;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppDimensions.radius8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: design.primary),
              const SizedBox(width: 4),
              Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: design.primary,
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.unfold_more_rounded,
                  size: 13,
                  color: design.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OnDutyChip extends ConsumerWidget {
  const _OnDutyChip({required this.settings});

  final SettingsState settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final design = context.design;
    final l10n = context.l10n;
    final wide = MediaQuery.sizeOf(context).width >= AppDimensions.tabletWidth;

    return Tooltip(
      message: '${l10n.posOnDuty}: ${settings.cashierName}',
      child: InkWell(
        onTap: () => _switch(context, ref),
        borderRadius: BorderRadius.circular(AppDimensions.radius20),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: wide ? AppDimensions.space10 : 6,
            vertical: 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: design.primaryContainer,
                child: Text(
                  initialsFor(settings.cashierName),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: design.onPrimaryContainer,
                  ),
                ),
              ),
              if (wide) ...[
                const SizedBox(width: AppDimensions.space8),
                ConstrainedBox(
                  // Bounded: a long name would otherwise squeeze the store
                  // title, which is the more important of the two.
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        settings.cashierName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: design.textHigh,
                        ),
                      ),
                      Text(
                        roleLabel(l10n, settings.employeeRole),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: design.textMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.unfold_more_rounded,
                  size: 16,
                  color: design.textLow,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _switch(BuildContext context, WidgetRef ref) async {
    final employee = await requestCashierSwitch(context);
    if (employee == null || !context.mounted) return;

    // The cart is deliberately kept. A handover mid-order is the common case —
    // the queue does not pause for a shift change — and discarding a
    // customer's basket to make the attribution tidy is the wrong trade.
    //
    // So is the POS session, for the same reason one step down: the session
    // belongs to the till, and the cash box does not change hands just because
    // the person in front of it does. The next order carries the new cashier's
    // name into the same drawer, and whoever counts it at close is recorded
    // separately. Signing in from the login screen does NOT keep it — that
    // path re-resolves, so nobody silently inherits somebody else's drawer.
    try {
      await ref.read(settingsProvider.notifier).signIn(employee, keepPosSession: true);
    } on TillOperationException catch(e) {
      if(context.mounted)showAppSnackBar(context,tillErrorMessage(context,e),error:true);
      return;
    }
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      context.l10n.posSwitchedTo(employee.name),
      success: true,
    );
  }
}
