import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../data/sync/device_sync_controller.dart';

/// Sync on an activated till: when it last reached the server, what is still
/// waiting to go up, what the server refused, and a manual "Sync now".
///
/// Shown to every role. The cashier is the one who notices the wifi is down,
/// and "12 records waiting to upload" is what tells them the takings are safe
/// on the tablet rather than gone.
class SyncStatusCard extends StatelessWidget {
  const SyncStatusCard({super.key, required this.controller});

  final DeviceSyncController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;

    return GlassCard.solid(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space16,
        vertical: AppDimensions.space12,
      ),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final status = controller.status;
          final healthy = status.lastFailure == null;
          final lastSuccess = status.lastSuccessAt;
          final state = status.running
              ? l10n.syncRunning
              : status.updateRequired
              ? l10n.syncUpdateRequired
              : !healthy
              ? l10n.syncFailed
              : lastSuccess != null
              ? l10n.syncLastSuccess(
                  TimeOfDay.fromDateTime(lastSuccess).format(context),
                )
              : l10n.syncNever;

          final tiles = <Widget>[
            _SyncTile(
              icon: healthy
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
              iconColor: healthy ? design.success : design.warning,
              title: l10n.syncStatus,
              value: state,
            ),
            _SyncTile(
              icon: Icons.outbox_outlined,
              iconColor: design.info,
              title: l10n.syncPending,
              value: l10n.syncPendingValue(status.pending),
              onTap: status.pending > 0
                  ? () => context.push('/recovery')
                  : null,
            ),
            // Only when there is something to recover. Refused rows are kept
            // on the device; this is how anyone finds out they exist.
            if (status.deadLetters > 0)
              _SyncTile(
                icon: Icons.report_gmailerrorred_outlined,
                iconColor: design.error,
                title: l10n.syncRejected(status.deadLetters),
                value: l10n.syncRejectedRetry,
                onTap: () => context.push('/recovery'),
              ),
            _SyncTile(
              icon: Icons.sync_rounded,
              iconColor: design.primary,
              title: l10n.syncNow,
              value: l10n.syncNowHint,
              onTap: status.running ? null : controller.syncNow,
            ),
          ];

          return Column(
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                tiles[i],
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Same shape as the Settings screen's own rows, so the card reads as part of
/// the page rather than a panel dropped onto it.
class _SyncTile extends StatelessWidget {
  const _SyncTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppDimensions.radius8),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: AppDimensions.space10,
          horizontal: AppDimensions.space4,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: AppDimensions.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: design.textHigh,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    style: TextStyle(fontSize: 12, color: design.textMedium),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: AppDimensions.space8),
              Icon(
                Icons.chevron_right_rounded,
                color: design.textLow,
                size: 20,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
