import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../providers/outlet_provider.dart';
import '../../providers/settings_provider.dart';

/// Move this device to another branch, from the screen it sells on.
///
/// A shortcut, not a second way to manage outlets — it only lists the open
/// ones and only changes which one this device is standing in. Opening,
/// renaming and closing branches stays on the management screen.
///
/// Worth being one tap from the till: standing at the wrong branch is the
/// mistake here that silently produces a whole day of wrong numbers, and the
/// alternative was three levels into Settings.
class OutletPickerSheet extends ConsumerWidget {
  const OutletPickerSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final outlets = ref.watch(outletsProvider);
    final activeId = ref.watch(activeOutletProvider).valueOrNull?.id;

    return Padding(
      padding: const EdgeInsets.all(AppDimensions.space16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.outletPickTitle,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: design.textHigh,
            ),
          ),
          const SizedBox(height: AppDimensions.space4),
          // Says what the choice costs, because it is not obvious that a
          // setting on a sell screen moves the stock and the takings too.
          Text(
            l10n.outletPickHint,
            style: TextStyle(color: design.textMedium, fontSize: 12),
          ),
          const SizedBox(height: AppDimensions.space16),
          outlets.when(
            loading: () => const LoadingIndicator(),
            error: (e, _) =>
                Text('$e', style: TextStyle(color: design.error, fontSize: 12)),
            data: (list) {
              final open = list.where((o) => o.active).toList();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final outlet in open)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: AppDimensions.space8,
                      ),
                      child: GlassCard.solid(
                        onTap: () async {
                          await ref
                              .read(settingsProvider.notifier)
                              .setOutletId(outlet.id);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        padding: const EdgeInsets.all(AppDimensions.space12),
                        child: Row(
                          children: [
                            Icon(
                              Icons.storefront_rounded,
                              size: 20,
                              color: design.onPrimaryContainer,
                            ),
                            const SizedBox(width: AppDimensions.space12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    outlet.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14,
                                      color: design.textHigh,
                                    ),
                                  ),
                                  if (outlet.address?.isNotEmpty == true) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      outlet.address!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: design.textMedium,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (outlet.id == activeId)
                              Icon(
                                Icons.check_circle_rounded,
                                size: 18,
                                color: design.success,
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
