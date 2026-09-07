import 'package:flutter/material.dart';

import '../../../core/theme/app_dimensions.dart';
import '../../../core/theme/app_theme.dart';
import 'glass_card.dart';

/// Variants of [GlassStepper].
enum GlassStepperVariant { full, addOnly }

/// Unified quantity stepper for cart lines and POS tiles.
///
/// - [GlassStepperVariant.full] (default): the `[-][n][+]` row used in the
///   cart. When [quantity] == 0 it renders an "Add" affordance instead, which
///   is what the POS tile shows before the first tap.
/// - [GlassStepperVariant.addOnly]: always renders the "Add" affordance
///   regardless of [quantity] — for tiles where the count is shown elsewhere.
///
/// Colours resolve from [BrandColors] via `context.design`. When [enabled] is
/// false the whole stepper dims to 45% opacity and does not fire.
///
/// This is a primitive. Cart lines and POS tiles delegate here in later tasks.
class GlassStepper extends StatelessWidget {
  const GlassStepper({
    super.key,
    required this.quantity,
    required this.onAdd,
    required this.onDecrement,
    this.variant = GlassStepperVariant.full,
    this.enabled = true,
    this.addLabel,
  });

  /// Current quantity. `0` switches the full variant to the Add affordance.
  final int quantity;

  /// Fired on the increment tap target and on the Add affordance.
  final VoidCallback onAdd;

  /// Fired on the decrement tap target (full variant, quantity > 0 only).
  final VoidCallback onDecrement;

  /// Controls which layout to use. See [GlassStepperVariant].
  final GlassStepperVariant variant;

  /// When false the stepper dims and ignores all taps.
  final bool enabled;

  /// Optional label for the qty==0 Add affordance. Caller localizes it.
  final String? addLabel;

  static const double _minHeight = 34;

  @override
  Widget build(BuildContext context) {
    final showAdd = quantity == 0 || variant == GlassStepperVariant.addOnly;
    final core = showAdd ? _buildAdd(context) : _buildStepper(context);
    if (!enabled) {
      return Opacity(opacity: 0.45, child: IgnorePointer(child: core));
    }
    return core;
  }

  /// Qty==0 / addOnly: a solid glass pill with `+` and the optional label.
  Widget _buildAdd(BuildContext context) {
    final design = context.design;
    final color = enabled ? design.primary : design.textMedium;
    return SizedBox(
      height: _minHeight,
      child: GlassCard.solid(
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimensions.space12,
          vertical: AppDimensions.space6,
        ),
        radius: AppDimensions.radiusMd,
        onTap: enabled ? onAdd : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 16, color: color),
            if (addLabel != null) ...[
              const SizedBox(width: AppDimensions.space6),
              Flexible(
                child: Text(
                  addLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// qty>0 full variant: solid [BrandColors.primary] bar with three tap zones.
  Widget _buildStepper(BuildContext context) {
    final design = context.design;
    final decIcon =
        quantity == 1 ? Icons.delete_outline_rounded : Icons.remove_rounded;
    return SizedBox(
      height: _minHeight,
      child: Material(
        color: design.primary,
        borderRadius: AppDimensions.radiusMd,
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onDecrement,
                child: Center(
                  child: Icon(decIcon, size: 17, color: design.onPrimary),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimensions.space12,
              ),
              child: Text(
                '$quantity',
                style: TextStyle(
                  color: design.onPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: onAdd,
                child: Center(
                  child: Icon(
                    Icons.add_rounded,
                    size: 17,
                    color: design.onPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
