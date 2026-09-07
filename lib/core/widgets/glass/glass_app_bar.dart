import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/brand_colors.dart';

/// Blurred, optionally large-title app bar used by the redesign's restyled
/// screens.
///
/// Renders a Material [AppBar] whose `flexibleSpace` is a frosted-glass layer
/// (BackdropFilter + translucent tint + hairline bottom border). All colours
/// resolve from [BrandColors] via `context.design` — never hardcode a colour.
///
/// Pass `large: true` to reserve extra height for an oversized title row. The
/// large title itself is the caller's responsibility (a later restyle task can
/// add a full large-title row in the flexibleSpace); here `large` only grows
/// [preferredSize] so the flexibleSpace has room to paint behind a taller bar.
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    super.key,
    this.title,
    this.titleWidget,
    this.actions = const [],
    this.leading,
    this.bottom,
    this.large = false,
  });

  /// Plain-text title. Ignored when [titleWidget] is non-null.
  final String? title;

  /// Fully custom title widget. Wins over [title] when both are supplied.
  final Widget? titleWidget;

  /// Trailing action widgets, shown on the right edge.
  final List<Widget> actions;

  /// Leading widget (typically a back / menu button).
  final Widget? leading;

  /// Optional persistent bottom slab ([TabBar], filter chips, etc.). Its
  /// [PreferredSizeWidget.preferredSize] feeds this widget's height.
  final PreferredSizeWidget? bottom;

  /// When true, reserve extra height for an oversized title row.
  final bool large;

  @override
  Size get preferredSize => Size.fromHeight(
    kToolbarHeight +
        (bottom?.preferredSize.height ?? 0) +
        (large ? 28 : 0),
  );

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      leading: leading,
      title: titleWidget ??
          (title == null
              ? null
              : Text(
                  title!,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                    color: design.textHigh,
                  ),
                )),
      actions: actions,
      bottom: bottom,
      flexibleSpace: _GlassBarFlex(large: large),
    );
  }
}

/// Frosted-glass painter that fills the app bar's `flexibleSpace`.
///
/// `ClipRect` keeps the blur inside the bar bounds; the `BackdropFilter` blurs
/// the substrate (the [AppBackground] behind every screen), and the
/// `DecoratedBox` lays down the translucent tint plus a hairline bottom edge
/// so the bar reads as floating without needing an elevation shadow.
class _GlassBarFlex extends StatelessWidget {
  const _GlassBarFlex({required this.large});

  /// Currently only affects layout callers may reserve; the painter itself is
  /// identical in both modes. Kept on the widget so a future large-title row
  /// has the hook it needs without changing the constructor.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: design.glassBlurSigma,
          sigmaY: design.glassBlurSigma,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: design.glassTint.withValues(alpha: design.glassOpacity),
            border: Border(
              bottom: BorderSide(
                color: design.glassBorder.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
