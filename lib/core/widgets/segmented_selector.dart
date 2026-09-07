import 'package:flutter/material.dart';

import '../theme/app_dimensions.dart';
import '../theme/app_theme.dart';
import 'glass/glass_card.dart';

/// iOS-style segmented control rebuilt on [GlassCard.solid].
///
/// Public API is unchanged: callers pass [value], [onChanged], and a list of
/// [Segment]s. Internally a sliding pill ([BrandColors.primary]) animates
/// behind the selected segment via [AnimatedPositioned]; the foreground is a
/// row of tap targets whose icon/label flip to [BrandColors.onPrimary] when
/// selected and [BrandColors.textMedium] otherwise.
class SegmentedSelector<T> extends StatelessWidget {
  const SegmentedSelector({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.expand = false,
  });

  final List<Segment<T>> segments;
  final T value;
  final ValueChanged<T> onChanged;

  /// Unused under the new glass design — kept only so existing call sites
  /// that pass it still compile. Segments always split the row evenly.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final count = segments.length;
    final selectedIndex = segments.indexWhere((s) => s.value == value);

    return GlassCard.solid(
      padding: const EdgeInsets.all(AppDimensions.space4),
      radius: BorderRadius.circular(AppDimensions.radius14),
      onTap: null,
      child: LayoutBuilder(
        builder: (ctx, c) {
          final slot = c.maxWidth / count;
          return SizedBox(
            height: 40,
            child: Stack(
              children: [
                if (selectedIndex >= 0)
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    left: selectedIndex * slot,
                    top: 0,
                    bottom: 0,
                    width: slot,
                    child: Padding(
                      padding: const EdgeInsets.all(AppDimensions.space2),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: design.primary,
                          borderRadius: BorderRadius.circular(
                            AppDimensions.radius10,
                          ),
                        ),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    for (final seg in segments)
                      Expanded(
                        child: InkWell(
                          onTap: () => onChanged(seg.value),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (seg.icon != null) ...[
                                  Icon(
                                    seg.icon,
                                    size: 16,
                                    color: seg.value == value
                                        ? design.onPrimary
                                        : design.textMedium,
                                  ),
                                  const SizedBox(width: AppDimensions.space6),
                                ],
                                Flexible(
                                  child: Text(
                                    seg.label,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: seg.value == value
                                          ? design.onPrimary
                                          : design.textMedium,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// One segment in a [SegmentedSelector].
class Segment<T> {
  const Segment({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}
