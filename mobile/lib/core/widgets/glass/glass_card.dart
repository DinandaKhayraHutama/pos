import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/app_dimensions.dart';
import '../../theme/app_theme.dart';
import '../../theme/brand_colors.dart';

/// The workhorse glassmorphism container every screen composes over
/// [AppBackground].
///
/// Two flavours:
/// - **Default (`blur: true`)** — paints a [BackdropFilter] that blurs the
///   substrate behind it, then a translucent tint + sharper hairline border +
///   layered shadows + a diagonal sheen. Use for floating panels, dialogs,
///   sheets — anything where there is exactly one card on screen.
/// - **[GlassCard.solid]** (`blur: false`) — skips the [BackdropFilter] and
///   just paints the tint/border/shadow/sheen. Use inside scroll lists so a
///   column of N cards doesn't allocate N GPU blurs.
///
/// The decoration reads as a physical, elevated glass surface:
/// - **Layered drop shadows** — an ambient spread, a tight contact/key, and a
///   subtle brand glow.
/// - **Sharper border + inner top highlight** — a uniform 0.6px hairline plus
///   a bright vertical gradient along the top edge to simulate light from
///   above.
/// - **Diagonal sheen overlay** — a soft top-left → mid reflection; the key
///   premium-glass cue. Wrapped in [IgnorePointer] so taps pass through to
///   the [InkWell] beneath.
///
/// All colours resolve from [BrandColors] via `context.design` — never
/// hardcode a colour here. `Colors.white` is the sanctioned exception for the
/// sheen and top-edge highlight (they simulate reflected light, not brand
/// colour).
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    this.child,
    this.padding = AppDimensions.cardPadding,
    this.radius = const BorderRadius.all(
      Radius.circular(AppDimensions.radius20),
    ),
    this.blur = true,
    this.tint,
    this.borderColor,
    this.borderWidth = 1.5,
    this.onTap,
    this.trailing,
  }) : assert(
         child != null || trailing != null,
         'GlassCard needs at least a child or a trailing widget.',
       );

  /// Tinted card without a [BackdropFilter]. The right choice inside scroll
  /// lists (a column of N blurred cards is a perf cliff) and anywhere the
  /// substrate behind the card is already opaque.
  factory GlassCard.solid({
    Key? key,
    Widget? child,
    EdgeInsets? padding,
    BorderRadius? radius,
    Color? tint,
    Color? borderColor,
    double borderWidth = 1.5,
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    return GlassCard(
      key: key,
      padding: padding ?? AppDimensions.cardPadding,
      radius: radius ?? AppDimensions.radiusLg,
      tint: tint,
      borderColor: borderColor,
      borderWidth: borderWidth,
      onTap: onTap,
      trailing: trailing,
      blur: false,
      child: child,
    );
  }

  /// Primary content. Mutually optional with [trailing] (one must be non-null).
  final Widget? child;

  /// Inner padding. Defaults to [AppDimensions.cardPadding] (14dp).
  final EdgeInsets padding;

  /// Corner radius. Defaults to [AppDimensions.radius20] (20dp circular).
  final BorderRadius radius;

  /// When true (default), wraps the content in a [BackdropFilter] that blurs
  /// the substrate behind the card.
  final bool blur;

  /// Override the tint colour (still multiplied by [BrandColors.glassOpacity]).
  /// Defaults to [BrandColors.glassTint].
  final Color? tint;

  /// Override the border colour. When non-null this paints a ring of
  /// [borderWidth] around the card instead of the default 0.6px hairline
  /// (the selected-state ring on a [ProductCard] is the worked example).
  /// When null, behaviour is unchanged (the default hairline applies).
  final Color? borderColor;

  /// Width of the [borderColor] ring. Ignored when [borderColor] is null.
  /// Defaults to 1.5 so a selected card reads as outlined without thickening.
  final double borderWidth;

  /// Tap handler. When non-null the card wraps its content in an [InkWell].
  final VoidCallback? onTap;

  /// Optional trailing widget (chevron, action button, switch). When both
  /// [child] and [trailing] are set they lay out in a `Row` with the child in
  /// an `Expanded`.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final body = _body();

    // The glass body is a Stack so we can layer tint + reflection beneath the
    // interactive content. Material is the only non-positioned child, so the
    // Stack sizes to it (body + padding); the three `Positioned.fill` layers
    // stretch to cover the same area. The sheen and top highlight are
    // `IgnorePointer` so taps reach the InkWell on top.
    final painted = Stack(
      children: [
        // (1) Tint + sharper uniform border + layered drop shadows.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              // `glassOpacity` applies to the DEFAULT tint only. Forcing it
              // onto a caller-supplied colour overwrote that colour's own
              // alpha — and since the flat-genre change set glassOpacity to
              // 1.0, every soft container token (`primaryContainer` is
              // `primary` at 14%) was being painted as the full-strength
              // brand colour. Call sites then paired it with `onXContainer`
              // text, which is tuned for a pale wash, so the checkout total
              // read as dark navy on saturated blue.
              color:
                  tint ??
                  design.glassTint.withValues(alpha: design.glassOpacity),
              border: Border.all(
                color: borderColor ?? design.glassBorder.withValues(alpha: 0.6),
                width: borderColor != null ? borderWidth : 0.6,
              ),
              boxShadow: [
                // Ambient drop: broad, soft, directional (light from above).
                BoxShadow(
                  color: design.textHigh.withValues(alpha: 0.14),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
                // Contact/key: tight, close to the card — grounds the surface.
                BoxShadow(
                  color: design.textHigh.withValues(alpha: 0.08),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
                // Brand glow: wide, subtle, far — picks up the seed colour.
                BoxShadow(
                  color: design.primary.withValues(alpha: 0.07),
                  blurRadius: 48,
                  offset: const Offset(0, 20),
                ),
              ],
              borderRadius: radius,
            ),
          ),
        ),

        // (2) Diagonal sheen — top-left → lower-right reflection. Sits ABOVE
        // the tint so the frosted surface reads as glossy. IgnorePointer keeps
        // the gesture path clean.
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: const Alignment(0.4, 0.6),
                  colors: [
                    Colors.white.withValues(alpha: 0.18),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                ),
                borderRadius: radius,
              ),
            ),
          ),
        ),

        // (3) Inner top highlight — a bright vertical gradient confined to the
        // top sliver, simulating a lit edge. Flutter's `Border` can't take an
        // asymmetric `BorderSide` together with a non-zero `borderRadius`, so
        // we fake the lit top edge with a thin gradient strip. IgnorePointer
        // so taps pass through.
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(
                      alpha: design.brightness == Brightness.light ? 0.6 : 0.25,
                    ),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 0.05],
                ),
                borderRadius: radius,
              ),
            ),
          ),
        ),

        // (4) Interactive content on top. Last in the Stack so it hit-tests
        // first; the overlays above are all IgnorePointer.
        //
        // The splash/highlight/hover all derive from `textHigh` (which flips
        // per brightness: dark-on-light, light-on-dark) at very low alpha. The
        // default InkWell splash would flood the near-opaque glass tint with
        // the brand `primary` colour and clash with the card text; this neutral
        // scrim-tint reads as a gentle darken/lighten, not a colour shift.
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            splashColor: design.textHigh.withValues(alpha: 0.08),
            highlightColor: design.textHigh.withValues(alpha: 0.06),
            hoverColor: design.textHigh.withValues(alpha: 0.04),
            child: Padding(padding: padding, child: body),
          ),
        ),
      ],
    );

    // The blur path is the only thing that allocates a BackdropFilter, so a
    // list of `.solid` cards stays cheap.
    final Widget decorated = blur
        ? BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: design.glassBlurSigma,
              sigmaY: design.glassBlurSigma,
            ),
            child: painted,
          )
        : painted;

    // Clip so the tint + backdrop stay inside the rounded corners.
    return ClipRRect(borderRadius: radius, child: decorated);
  }

  Widget _body() {
    if (child != null && trailing != null) {
      return Row(
        children: [
          Expanded(child: child!),
          trailing!,
        ],
      );
    }
    if (child != null) return child!;
    return trailing!;
  }
}
