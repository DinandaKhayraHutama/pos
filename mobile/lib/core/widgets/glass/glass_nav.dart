import 'dart:ui';

import 'package:flutter/material.dart';

import '../../localization/l10n.dart';
import '../../theme/app_dimensions.dart';
import '../../theme/app_theme.dart';
import '../brand_mark.dart';

/// A single glass navigation destination.
///
/// Mirrors the active/inactive icon pair + label that Material's
/// [NavigationDestination] wants, plus an optional numeric [badge] used by the
/// POS tab to surface the cart item count.
class GlassNavItem {
  const GlassNavItem({
    required this.active,
    required this.inactive,
    required this.label,
    this.badge,
  });

  /// Icon shown when this destination is selected.
  final IconData active;

  /// Icon shown when this destination is not selected.
  final IconData inactive;

  /// Localized label rendered under the icon.
  final String label;

  /// Optional badge count (e.g. cart size). Hidden when null or `<= 0`.
  final int? badge;
}

/// Frosted-glass bottom navigation bar for phones.
///
/// Renders a [BackdropFilter] blur over the [AppBackground] substrate, a
/// translucent tint + hairline top border, and a row of [_GlassItemButton]s.
/// The selected item's icon and label switch to [BrandColors.primary] and the
/// icon grows slightly; that is the entire selected affordance — no pill,
/// keeping the bar visually quiet.
class GlassNav extends StatelessWidget {
  const GlassNav({
    super.key,
    required this.index,
    required this.onChanged,
    required this.items,
  });

  /// Index of the currently selected item.
  final int index;

  /// Fired with the tapped index.
  final ValueChanged<int> onChanged;

  /// The destinations, left-to-right.
  final List<GlassNavItem> items;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AppDimensions.radius20),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: design.glassBlurSigma,
          sigmaY: design.glassBlurSigma,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: design.glassTint.withValues(alpha: design.glassOpacity),
            border: Border(
              top: BorderSide(
                color: design.glassBorder.withValues(alpha: 0.4),
                width: 0.5,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimensions.space4,
                vertical: AppDimensions.space4,
              ),
              child: Row(
                children: [
                  for (int i = 0; i < items.length; i++)
                    Expanded(
                      child: _GlassItemButton(
                        item: items[i],
                        selected: i == index,
                        onTap: () => onChanged(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted-glass side rail for tablets and desktop (≥
/// `AppDimensions.tabletWidth`).
///
/// Same data model as [GlassNav], but laid out the way a web app's sidebar is
/// rather than as a stack of stubby icon-over-label tiles: a brand header, a
/// list of full-width rows reading icon-then-label, and a slot at the bottom
/// for whoever is signed in. It collapses to an icon strip and animates
/// between the two widths.
///
/// **Presentational only.** [expanded] and [onToggleExpanded] are owned by the
/// caller, and [footer] is handed in already built — this file stays free of
/// Riverpod so `core/widgets/glass/` remains a widget library rather than a
/// second place that knows about app state.
class GlassNavRail extends StatelessWidget {
  const GlassNavRail({
    super.key,
    required this.index,
    required this.onChanged,
    required this.items,
    required this.expanded,
    required this.onToggleExpanded,
    this.footer,
  });

  /// Index of the currently selected item.
  final int index;

  /// Fired with the tapped index.
  final ValueChanged<int> onChanged;

  /// The destinations, top-to-bottom.
  final List<GlassNavItem> items;

  /// When false the rail shrinks to icons and every row grows a tooltip.
  final bool expanded;

  /// Fired with the *requested* new state.
  final ValueChanged<bool> onToggleExpanded;

  /// Optional bottom slot (the on-duty employee). Built by the caller so this
  /// widget needs no providers.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final design = context.design;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: expanded
          ? AppDimensions.navRailWidth
          : AppDimensions.navRailCollapsedWidth,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: design.glassBlurSigma,
            sigmaY: design.glassBlurSigma,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: design.glassTint.withValues(alpha: design.glassOpacity),
              border: Border(
                right: BorderSide(
                  color: design.glassBorder.withValues(alpha: 0.4),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              right: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimensions.space12,
                  vertical: AppDimensions.space12,
                ),
                // Every row is laid out at the EXPANDED width and clipped by
                // the AnimatedContainer as it narrows. Rebuilding the rows for
                // each intermediate width would relayout the text on every
                // frame of the animation and overflow on the way through.
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth:
                      AppDimensions.navRailWidth - AppDimensions.space12 * 2,
                  maxWidth:
                      AppDimensions.navRailWidth - AppDimensions.space12 * 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _RailHeader(
                        expanded: expanded,
                        onToggle: () => onToggleExpanded(!expanded),
                      ),
                      const SizedBox(height: AppDimensions.space16),
                      // Scrolls rather than overflows: a short window plus a
                      // five-destination owner leaves little room once the
                      // header and footer have taken theirs.
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (int i = 0; i < items.length; i++)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: _RailTile(
                                    item: items[i],
                                    selected: i == index,
                                    expanded: expanded,
                                    onTap: () => onChanged(i),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (footer != null) ...[
                        const SizedBox(height: AppDimensions.space8),
                        Divider(
                          height: 1,
                          thickness: 0.5,
                          color: design.glassBorder.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: AppDimensions.space8),
                        footer!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Brand mark + wordmark + the collapse control.
///
/// "JustClick POS" is the product name, which is why it is a literal here —
/// the same exemption `_BootstrapScaffold` has. Everything else in the rail is
/// localized.
class _RailHeader extends StatelessWidget {
  const _RailHeader({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final design = context.design;

    const mark = BrandMark(size: 40);

    final toggle = Tooltip(
      message: expanded
          ? context.l10n.navCollapseSidebar
          : context.l10n.navExpandSidebar,
      child: IconButton(
        onPressed: onToggle,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          expanded
              ? Icons.keyboard_double_arrow_left_rounded
              : Icons.keyboard_double_arrow_right_rounded,
          size: 20,
          color: design.textMedium,
        ),
      ),
    );

    if (!expanded) {
      // Centred within the collapsed strip, not within the expanded row the
      // OverflowBox actually lays out — hence the explicit width.
      return SizedBox(
        width: AppDimensions.navRailCollapsedWidth - AppDimensions.space12 * 2,
        child: Column(
          children: [
            mark,
            const SizedBox(height: AppDimensions.space4),
            toggle,
          ],
        ),
      );
    }

    return Row(
      children: [
        mark,
        const SizedBox(width: AppDimensions.space10),
        Expanded(
          child: Text(
            'JustClick POS',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
              color: design.textHigh,
            ),
          ),
        ),
        toggle,
      ],
    );
  }
}

/// One destination in the side rail: a full-width row, icon then label.
///
/// Selected state is a filled `primaryContainer` pill rather than the bottom
/// bar's colour-only treatment. A rail row is wide and mostly empty, so colour
/// alone leaves the selection hard to find; the fill gives it an edge to read
/// against, which is what a sidebar in any modern web app does.
class _RailTile extends StatelessWidget {
  const _RailTile({
    required this.item,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  final GlassNavItem item;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final color = selected ? design.primary : design.textMedium;
    final hasBadge = item.badge != null && item.badge! > 0;

    final icon = Icon(
      selected ? item.active : item.inactive,
      size: 21,
      color: color,
    );

    final row = Row(
      children: [
        // The icon sits in a fixed-width box so every label starts on the same
        // x, and so the icon lands dead centre once the rail collapses.
        SizedBox(
          width:
              AppDimensions.navRailCollapsedWidth -
              AppDimensions.space12 * 2 -
              AppDimensions.space10 * 2,
          child: Center(
            child: hasBadge && !expanded
                ? Badge(
                    backgroundColor: design.primary,
                    textColor: design.onPrimary,
                    label: Text('${item.badge}'),
                    child: icon,
                  )
                : icon,
          ),
        ),
        const SizedBox(width: AppDimensions.space10),
        // Faded rather than removed. The row is always built at the expanded
        // width (see the OverflowBox above), so dropping the label would
        // relayout mid-animation; fading it lets the text disappear before
        // the clip reaches it, which is what makes the collapse read as one
        // motion instead of a snap.
        Expanded(
          child: AnimatedOpacity(
            opacity: expanded ? 1 : 0,
            duration: const Duration(milliseconds: 140),
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ),
        ),
        if (hasBadge && expanded)
          Container(
            margin: const EdgeInsets.only(left: AppDimensions.space6),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: design.primary,
              borderRadius: BorderRadius.circular(AppDimensions.radius10),
            ),
            child: Text(
              '${item.badge}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: design.onPrimary,
              ),
            ),
          ),
      ],
    );

    final tile = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppDimensions.radius12),
        // Neutral scrim-tint splash, same rationale as GlassCard: the rail
        // sits on a solid glass surface, so a brand-coloured splash would
        // flood the row and clash with the icon and label.
        splashColor: design.textHigh.withValues(alpha: 0.08),
        highlightColor: design.textHigh.withValues(alpha: 0.06),
        hoverColor: design.textHigh.withValues(alpha: 0.05),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimensions.space10,
            vertical: AppDimensions.space10,
          ),
          decoration: BoxDecoration(
            color: selected ? design.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(AppDimensions.radius12),
          ),
          child: row,
        ),
      ),
    );

    // A label the user cannot read has to be reachable some other way.
    return expanded
        ? tile
        : Tooltip(
            message: item.label,
            waitDuration: const Duration(milliseconds: 400),
            child: tile,
          );
  }
}

/// Single icon + label destination shared by [GlassNav] and [GlassNavRail].
///
/// Lays out vertically (icon over label) so it works identically inside a
/// horizontal `Row` and a vertical `Column`. Selected state is colour + a
/// slightly larger icon — no pill, keeping the bar quiet.
class _GlassItemButton extends StatelessWidget {
  const _GlassItemButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final GlassNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final color = selected ? design.primary : design.textMedium;
    final icon = Icon(
      selected ? item.active : item.inactive,
      size: selected ? 24 : 22,
      color: color,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppDimensions.radius12),
        // Neutral scrim-tint splash, same rationale as GlassCard: the nav bar
        // sits on a solid glass surface, so a brand-coloured splash would
        // flood the tile and clash with the icon/label.
        splashColor: design.textHigh.withValues(alpha: 0.08),
        highlightColor: design.textHigh.withValues(alpha: 0.06),
        hoverColor: design.textHigh.withValues(alpha: 0.04),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: AppDimensions.space6,
            horizontal: AppDimensions.space4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.badge != null && item.badge! > 0)
                Badge(
                  backgroundColor: design.primary,
                  textColor: design.onPrimary,
                  label: Text('${item.badge}'),
                  child: icon,
                )
              else
                icon,
              const SizedBox(height: AppDimensions.space4),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
