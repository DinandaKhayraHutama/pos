import 'package:flutter/material.dart';

import '../../theme/app_dimensions.dart';
import '../../theme/app_theme.dart';

/// The single reusable pill chip for POS category chips, Orders filter
/// chips, and Tables status chips.
///
/// Selected → [BrandColors.primary] fill with [BrandColors.onPrimary] label.
/// Unselected → translucent [BrandColors.glassTint] fill with a hairline
/// [BrandColors.glassBorder] and [BrandColors.textMedium] label. The caller
/// owns the [selected] state and rebuilds on toggle; this widget is a pure
/// function of [selected].
class GlassFilterChip extends StatelessWidget {
  const GlassFilterChip({
    super.key,
    required this.label,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  /// Visible label. Caller is responsible for localizing it.
  final String label;

  /// Optional leading icon. Rendered at 16px.
  final IconData? icon;

  /// Whether the chip is in the selected (active) state.
  final bool selected;

  /// Tap handler. Caller toggles [selected] and rebuilds.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppDimensions.radius28),
        // Neutral scrim-tint splash — same rationale as GlassCard. Selected
        // chips already flood with `design.primary` via the AnimatedContainer
        // fill, so the default brand splash on top would double up.
        splashColor: design.textHigh.withValues(alpha: 0.08),
        highlightColor: design.textHigh.withValues(alpha: 0.06),
        hoverColor: design.textHigh.withValues(alpha: 0.04),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimensions.space12,
            vertical: AppDimensions.space8,
          ),
          decoration: BoxDecoration(
            color: selected
                ? design.primary
                : design.glassTint.withValues(alpha: design.glassOpacity * 0.6),
            borderRadius: BorderRadius.circular(AppDimensions.radius28),
            border: selected
                ? null
                : Border.all(color: design.glassBorder.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 16,
                  color: selected ? design.onPrimary : design.textMedium,
                ),
                const SizedBox(width: AppDimensions.space4),
              ],
              Text(
                label,
                style: TextStyle(
                  color: selected ? design.onPrimary : design.textMedium,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
