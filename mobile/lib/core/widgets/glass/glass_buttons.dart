import 'package:flutter/material.dart';

import '../../theme/app_dimensions.dart';
import '../../theme/app_theme.dart';
import '../../theme/brand_colors.dart';
import 'glass_card.dart';

/// Min height for every button in the family — matches Material's filled
/// button minimum and keeps the tap target accessible.
const double _kMinHeight = 52;

/// Wraps [child] in an [AnimatedScale] that dips to 0.97 while the user
/// presses, then fires [onPressed] via a [GestureDetector]. The scale is a
/// render-tree transform, so it does not swallow gestures — [GestureDetector]
/// still wins the arena and `onTap` fires.
///
/// When [enabled] is false the [GestureDetector]'s `onTap` is null and the
/// press animation is suppressed, so taps are a no-op.
class _PressScale extends StatefulWidget {
  const _PressScale({
    required this.onPressed,
    required this.enabled,
    required this.child,
  });

  final VoidCallback? onPressed;
  final bool enabled;
  final Widget child;

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!mounted || !widget.enabled) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.enabled ? widget.onPressed : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Paints either the caller's [child] (foreground-tinted via
/// [DefaultTextStyle.merge] + [IconTheme.merge]) or an 18px spinner in
/// [foreground] when [loading] is true. Shared across the family so the
/// loading swap is identical everywhere.
class _ButtonContent extends StatelessWidget {
  const _ButtonContent({
    required this.loading,
    required this.foreground,
    required this.child,
  });

  final bool loading;
  final Color foreground;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(foreground),
        ),
      );
    }
    return DefaultTextStyle.merge(
      style: TextStyle(
        color: foreground,
        fontWeight: FontWeight.w700,
        fontSize: 16,
        letterSpacing: -0.1,
      ),
      child: IconTheme.merge(
        data: IconThemeData(color: foreground, size: 20),
        child: child,
      ),
    );
  }
}

/// Shared body for the flat button variants (Primary, Ghost, Danger): a
/// [_kMinHeight]-tall box with `radiusLg` corners and `space20` horizontal
/// padding, wrapped in [_PressScale]. Stretches to full width when
/// [expanded] is true; otherwise wraps to content.
class _FlatGlassButton extends StatelessWidget {
  const _FlatGlassButton({
    required this.onPressed,
    required this.loading,
    required this.expanded,
    required this.foreground,
    required this.child,
    this.background,
    this.border,
  });

  final VoidCallback? onPressed;
  final bool loading;
  final bool expanded;
  final Color foreground;
  final Color? background;
  final Border? border;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;

    Widget body = Container(
      constraints: const BoxConstraints(minHeight: _kMinHeight),
      padding: const EdgeInsets.symmetric(horizontal: AppDimensions.space20),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        border: border,
        borderRadius: AppDimensions.radiusLg,
      ),
      child: _ButtonContent(
        loading: loading,
        foreground: foreground,
        child: child,
      ),
    );

    body = _PressScale(
      onPressed: onPressed,
      enabled: enabled,
      child: body,
    );

    // Dim the whole painted body when disabled (null onPressed or loading)
    // so the button reads as inert instead of pixel-identical to enabled.
    body = Opacity(opacity: enabled ? 1.0 : 0.45, child: body);

    return expanded ? SizedBox(width: double.infinity, child: body) : body;
  }
}

/// Filled brand-color action — the affirmative action on a screen.
///
/// Background resolves to [BrandColors.primary], label to
/// [BrandColors.onPrimary].
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.loading = false,
    this.expanded = true,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final bool loading;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return _FlatGlassButton(
      onPressed: onPressed,
      loading: loading,
      expanded: expanded,
      background: design.primary,
      foreground: design.onPrimary,
      child: child,
    );
  }
}

/// Glass-tinted secondary action — a [GlassCard.solid] with the brand's
/// [BrandColors.primary] as its label. Sits below [PrimaryButton] in the
/// visual hierarchy.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.loading = false,
    this.expanded = true,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final bool loading;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final enabled = onPressed != null && !loading;

    Widget body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: _kMinHeight),
      child: GlassCard.solid(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimensions.space20,
          vertical: AppDimensions.space14,
        ),
        radius: AppDimensions.radiusLg,
        child: Center(
          child: _ButtonContent(
            loading: loading,
            foreground: design.primary,
            child: child,
          ),
        ),
      ),
    );

    body = _PressScale(
      onPressed: onPressed,
      enabled: enabled,
      child: body,
    );

    // Same disabled dim as the flat variants — keeps the family consistent.
    body = Opacity(opacity: enabled ? 1.0 : 0.45, child: body);

    return expanded ? SizedBox(width: double.infinity, child: body) : body;
  }
}

/// Outline-only tertiary action: no fill, just a [Border] in
/// [BrandColors.glassBorder] with a [BrandColors.textHigh] label. Used for
/// low-priority actions like "skip" or "later".
class GhostButton extends StatelessWidget {
  const GhostButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.loading = false,
    this.expanded = true,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final bool loading;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return _FlatGlassButton(
      onPressed: onPressed,
      loading: loading,
      expanded: expanded,
      foreground: design.textHigh,
      border: Border.all(color: design.glassBorder),
      child: child,
    );
  }
}

/// Destructive action — filled with the semantic [BrandColors.error] and a
/// white label (`ColorScheme.onError`). Reserved for delete / sign-out /
/// discard flows.
class DangerButton extends StatelessWidget {
  const DangerButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.loading = false,
    this.expanded = true,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final bool loading;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return _FlatGlassButton(
      onPressed: onPressed,
      loading: loading,
      expanded: expanded,
      background: design.error,
      foreground: Theme.of(context).colorScheme.onError,
      child: child,
    );
  }
}
