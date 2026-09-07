import 'package:flutter/material.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/enums.dart';
import '../../l10n/gen/app_localizations.dart';
import '../theme/brand_colors.dart';

/// Colored glass pill representing an [OrderStatus] or [TableStatus].
///
/// Background resolves to the matching `*Container` token, foreground to the
/// matching semantic token, both via `context.design`. A hairline border in
/// the foreground color at low alpha gives the pill its glass edge. The label
/// logic and localization keys are unchanged from the pre-redesign version —
/// only colors and shape moved onto the design system.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status, this.compact = false});

  final dynamic status;
  final bool compact;

  (Color, Color, String) _resolve(AppLocalizations l10n, BrandColors d) {
    return switch (status) {
      OrderStatus.pending => (
        d.warning,
        d.warningContainer,
        l10n.orderStatusPending,
      ),
      OrderStatus.preparing => (
        d.info,
        d.infoContainer,
        l10n.orderStatusPreparing,
      ),
      OrderStatus.ready => (
        d.success,
        d.successContainer,
        l10n.orderStatusReady,
      ),
      OrderStatus.served => (
        d.primary,
        d.primaryContainer,
        l10n.orderStatusServed,
      ),
      OrderStatus.paid => (
        d.success,
        d.successContainer,
        l10n.orderStatusPaid,
      ),
      OrderStatus.cancelled => (
        d.error,
        d.errorContainer,
        l10n.orderStatusCancelled,
      ),
      // Warning rather than error: money going back to a customer is a normal
      // thing a shop does, not a fault. Reading it in the same red as a voided
      // order would make a legitimate refund look like a mistake.
      OrderStatus.refunded => (
        d.warning,
        d.warningContainer,
        l10n.orderStatusRefunded,
      ),
      TableStatus.available => (
        d.success,
        d.successContainer,
        l10n.tableStatusAvailable,
      ),
      TableStatus.occupied => (
        d.warning,
        d.warningContainer,
        l10n.tableStatusOccupied,
      ),
      TableStatus.reserved => (
        d.info,
        d.infoContainer,
        l10n.tableStatusReserved,
      ),
      _ => (
        d.textMedium,
        d.surfaceOverlay,
        l10n.commonUnknown,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final (fg, bg, label) = _resolve(l10n, design);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? AppDimensions.space8 : AppDimensions.space10,
        vertical: compact ? 3 : 4,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppDimensions.radius32),
        border: Border.all(color: fg.withValues(alpha: 0.2)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: compact ? 11 : 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}
