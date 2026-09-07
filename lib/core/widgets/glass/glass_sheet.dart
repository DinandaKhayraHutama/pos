import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/app_dimensions.dart';
import '../../theme/app_theme.dart';

/// Glassmorphism modal — a bottom sheet on phones, a side panel on wide screens.
///
/// Below [AppDimensions.tabletWidth] this is a thin wrapper over
/// [showModalBottomSheet] that:
/// - Makes the modal transparent so the [GlassSheet] body can paint its own
///   translucent tint + [BackdropFilter] blur over the substrate.
/// - Drops a 35% black barrier so whatever screen is underneath stays visible
///   (this is the whole point of glass — you see it floating over content).
/// - Hands the rest (`isDismissible`, `useSafeArea`, route lifecycle) straight
///   through to [showModalBottomSheet].
///
/// Use this anywhere the old code called `showModalBottomSheet` with custom
/// rounded + blurred chrome — POS checkout, table picker, etc.
///
/// NOTE: [showGlassSheet] wraps its body in a [GlassSheet], whose grabber +
/// content live inside a `mainAxisSize.min` [Column]. That Column passes an
/// unbounded max height to its children, so a body that needs BOUNDED height
/// to size against (a [DraggableScrollableSheet], or anything containing an
/// [Expanded]) must NOT go through [showGlassSheet] — open the modal directly
/// and wrap the body in a bare [GlassSurface] instead. The POS cart sheet is
/// the worked example (see `PosPage._openCartSheet`).
///
/// At or above [AppDimensions.tabletWidth] it opens a right-anchored side panel
/// instead. A sheet rising from the bottom edge is a phone idiom — it exists
/// because a thumb reaches the bottom of a handheld. On a wide screen it wastes
/// the axis that actually has room, drags the eye away from the content it
/// belongs to, and reads as a phone app stretched out. The panel slides in from
/// the right, keeps full height, and leaves the page readable beside it.
///
/// The panel scrolls its body, so the bounded-height caveat above applies to
/// the bottom-sheet path only — but keep using [GlassSurface] directly for
/// those bodies, since they still open as bottom sheets on phones.
///
/// Both paths push a normal route, so `Navigator.pop` inside the body behaves
/// identically either way.
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isDismissible = true,
  bool useSafeArea = true,
}) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= AppDimensions.tabletWidth) {
    return _showGlassSidePanel<T>(
      context: context,
      builder: builder,
      isDismissible: isDismissible,
      useSafeArea: useSafeArea,
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    isDismissible: isDismissible,
    useSafeArea: useSafeArea,
    builder: (ctx) => GlassSheet(child: builder(ctx)),
  );
}

Future<T?> _showGlassSidePanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required bool isDismissible,
  required bool useSafeArea,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: isDismissible,
    // showGeneralDialog asserts a non-empty label whenever the barrier is
    // dismissible; it is what a screen reader announces for the scrim.
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (ctx, animation, secondaryAnimation) {
      final size = MediaQuery.sizeOf(ctx);
      // Wide enough for a form, never more than a third of a large screen —
      // the point is that the page stays readable beside it.
      final panelWidth = (size.width * 0.34).clamp(380.0, 520.0);
      Widget body = _GlassPanelSurface(
        child: SingleChildScrollView(child: builder(ctx)),
      );
      if (useSafeArea) body = SafeArea(left: false, child: body);
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: panelWidth,
          height: double.infinity,
          child: body,
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

/// [GlassSurface]'s side-panel twin: rounded on the left edge instead of the
/// top, bordered on the left, and full height. No grabber — dragging a panel
/// down is meaningless, so it closes via its own control or the scrim.
class _GlassPanelSurface extends StatelessWidget {
  const _GlassPanelSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final design = context.design;

    return ClipRRect(
      borderRadius: const BorderRadius.horizontal(
        left: Radius.circular(AppDimensions.radius28),
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
              left: BorderSide(
                color: design.glassBorder.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          // showGeneralDialog does not insert a Material the way
          // showModalBottomSheet does, and without one every Text falls back to
          // the debug style — the panel rendered with underlined labels.
          // Transparency keeps the glass tint above visible.
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox.expand(child: child),
          ),
        ),
      ),
    );
  }
}

/// Frosted-glass surface — top-rounded clip + [BackdropFilter] blur + tint,
/// with NO layout of its own.
///
/// Unlike [GlassSheet], this does not add a grabber handle or wrap the child in
/// a sizing [Column], so the child receives its parent's constraints
/// unmodified. Use this directly around bodies that must size against a bounded
/// height (e.g. a [DraggableScrollableSheet] body, which computes its size as a
/// fraction of the available height and asserts when that height is infinite).
/// [GlassSheet] composes this plus a grabber for normal intrinsic-content
/// modals.
class GlassSurface extends StatelessWidget {
  const GlassSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final design = context.design;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(AppDimensions.radius28),
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
                color: design.glassBorder.withValues(alpha: 0.5),
                width: 0.5,
              ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Frosted-glass body for [showGlassSheet].
///
/// Lays out a grabber handle followed by [child], all clipped to a top-only
/// [AppDimensions.radius28] corner radius (so the sheet's bottom edge kisses
/// the screen edge with no gap). Colours resolve from [BrandColors] via
/// `context.design` — never hardcode a colour here.
///
/// The grabber + [child] sit inside a `mainAxisSize.min` [Column], so [child]
/// must have an intrinsic height (text, fixed-size cards, a `mainAxisSize.min`
/// inner Column). For a body that fills a bounded height — a
/// [DraggableScrollableSheet] or anything using [Expanded] — use
/// [GlassSurface] directly so the body receives bounded constraints.
class GlassSheet extends StatelessWidget {
  const GlassSheet({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final design = context.design;

    // The grabber handle reserves this much vertical extent (4px handle plus
    // 10px top & bottom margin), so the body is capped to the remaining height
    // the modal gave the sheet. Without this cap the body (a non-flex child of
    // this `mainAxisSize.min` Column) receives an unbounded height: an
    // intrinsic-content sheet sizes to its content and overflows when that
    // content is taller than the screen (e.g. the product form with the
    // keyboard up), and a scrollable body never scrolls. Capping lets a tall
    // body scroll while a short one still shrinks to fit.
    const grabberExtent = 24.0;
    return GlassSurface(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxBodyHeight = constraints.maxHeight.isFinite
              ? (constraints.maxHeight - grabberExtent).clamp(
                  0.0,
                  double.infinity,
                )
              : double.infinity;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: design.glassBorder.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxBodyHeight),
                child: child,
              ),
            ],
          );
        },
      ),
    );
  }
}
