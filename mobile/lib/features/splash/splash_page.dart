import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/brand_mark.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../providers/settings_provider.dart';

/// Shown while settings are loading. Also acts as the very first frame so
/// the user sees brand identity immediately.
class SplashPage extends ConsumerWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final design = context.design;
    final settings = ref.watch(settingsProvider);

    settings.whenData((_) {});

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: GlassCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppDimensions.space32,
                    vertical: AppDimensions.space24,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const BrandMark(size: 64),
                      const SizedBox(height: AppDimensions.space20),
                      Text(
                        'JustClick POS',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              color: design.textHigh,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                      ),
                      const SizedBox(height: AppDimensions.space6),
                      Text(
                        context.l10n.appTagline,
                        style: TextStyle(
                          color: design.textMedium,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: AppDimensions.space32,
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: design.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
