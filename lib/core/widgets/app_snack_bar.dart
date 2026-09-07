import 'package:flutter/material.dart';

import '../theme/app_dimensions.dart';
import '../theme/app_theme.dart';
import 'glass/glass_card.dart';

/// Shows a glass-styled snackbar.
///
/// Lives in `core/widgets/` rather than in `main_shell.dart`, where it started:
/// it is a themed primitive with no knowledge of the shell, and leaving it in a
/// feature file meant `core/` had to import `features/` to use it — a cycle,
/// and a layering rule broken for one function.
void showAppSnackBar(
  BuildContext context,
  String message, {
  bool success = false,
  bool error = false,
}) {
  final design = context.design;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: AppDimensions.radiusLg),
      margin: const EdgeInsets.all(AppDimensions.space12),
      content: GlassCard.solid(
        child: Row(
          children: [
            Icon(
              success
                  ? Icons.check_circle_rounded
                  : error
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              color: success
                  ? design.success
                  : error
                  ? design.error
                  : design.primary,
              size: 20,
            ),
            const SizedBox(width: AppDimensions.space12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  );
}
