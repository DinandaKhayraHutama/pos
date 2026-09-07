import 'package:flutter/material.dart';

import '../../theme/app_dimensions.dart';
import '../../theme/app_theme.dart';

/// Shimmer placeholder box used in list-loading states. Paints a horizontal
/// gradient sweep from [BrandColors.surfaceRaised] to [BrandColors.surfaceOverlay]
/// that slides forever (~1100ms loop, [Curves.easeInOut]). All colours resolve
/// via `context.design`, so a [Skeleton] reads correctly under any [BrandPreset]
/// and in either brightness.
///
/// Use directly for bespoke layouts, or pull a ready-made paragraph via
/// [LoadingIndicator.skeleton].
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, this.width, this.height = 16, this.radius});

  /// Bar width. Null = fill the parent's horizontal constraint.
  final double? width;

  /// Bar height. Defaults to `16` (one line of body text).
  final double height;

  /// Corner radius. Defaults to [AppDimensions.radius8] circular.
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: radius ?? BorderRadius.circular(AppDimensions.radius8),
        child: _Shimmer(
          base: design.surfaceRaised,
          highlight: design.surfaceOverlay,
        ),
      ),
    );
  }
}

/// Owns the shimmer ticker so [Skeleton] can stay stateless. The band is a
/// 3-stop [LinearGradient] (base → highlight → base) whose `begin`/`end` slide
/// horizontally with the controller value; `repeat(reverse: true)` avoids the
/// hard reset a one-shot sweep would produce at the loop seam.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.base, required this.highlight});

  final Color base;
  final Color highlight;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curve;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _curve = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, _) {
        // Slide the gradient from just left of the box to just right of it.
        // At t=0 begin=-1,end=0 (band off the left edge); at t=1 begin=1,end=2
        // (band off the right edge). Reverse:true sends it back, so the band
        // reads as a continuous sweep with no jump.
        final t = _curve.value;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1 + 2 * t, 0),
              end: Alignment(2 * t, 0),
              colors: [widget.base, widget.highlight, widget.base],
            ),
          ),
        );
      },
    );
  }
}
