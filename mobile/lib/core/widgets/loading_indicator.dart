import 'package:flutter/material.dart';

import '../theme/app_dimensions.dart';
import '../theme/app_theme.dart';
import 'glass/skeleton.dart';

/// Lightweight, snappy loading indicator.
///
/// The spinner stroke reads `design.primary` so it always matches the active
/// [BrandPreset]; the [LoadingIndicator.skeleton] constructor (Task 12) is
/// untouched.
class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: context.design.primary,
        ),
      ),
    );
  }

  /// A column of [lines] [Skeleton] bars with staggered widths (full, 80%,
  /// 60%, repeating), for list / paragraph loading states. Reads as "content
  /// is loading" rather than a bare spinner — use on dashboard / orders /
  /// tables list screens.
  ///
  /// Not `const`: the [LayoutBuilder] needs runtime constraints to compute
  /// per-line widths. Call sites just write `LoadingIndicator.skeleton()`.
  static Widget skeleton({int lines = 3}) {
    const fractions = [1.0, 0.8, 0.6];
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasWidth = constraints.maxWidth.isFinite;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < lines; i++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: i == lines - 1 ? 0 : AppDimensions.space10,
                ),
                child: Skeleton(
                  width: hasWidth
                      ? constraints.maxWidth * fractions[i % fractions.length]
                      : null,
                  height: 16,
                ),
              ),
          ],
        );
      },
    );
  }
}
