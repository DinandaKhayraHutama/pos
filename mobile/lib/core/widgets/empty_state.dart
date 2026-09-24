import 'package:flutter/material.dart';

import '../theme/app_dimensions.dart';
import '../theme/app_theme.dart';
import 'glass/glass_card.dart';

/// Friendly empty state with an icon and optional CTA.
///
/// Uses [IconData] rather than an emoji so it renders identically on every
/// platform - emoji fall back to tofu boxes wherever the system emoji font is
/// missing, e.g. the iOS Simulator.
///
/// Restyled onto the glass system: content sits inside a [GlassCard.solid]
/// with the icon in a soft brand-tinted circle, so empty states read as
/// premium panels rather than bare centered text.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppDimensions.space32),
        child: GlassCard.solid(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: design.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 32, color: design.primary),
              ),
              const SizedBox(height: AppDimensions.space16),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: design.textHigh,
                ),
                textAlign: TextAlign.center,
              ),
              if (subtitle != null) ...[
                const SizedBox(height: AppDimensions.space6),
                Text(
                  subtitle!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: design.textMedium),
                  textAlign: TextAlign.center,
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AppDimensions.space20),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
