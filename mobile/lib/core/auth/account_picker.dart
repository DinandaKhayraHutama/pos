import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/employee.dart';
import '../../providers/employee_provider.dart';
import '../../providers/settings_provider.dart';
import '../localization/l10n.dart';
import '../theme/app_dimensions.dart';
import '../theme/app_theme.dart';
import '../widgets/app_snack_bar.dart';
import '../widgets/glass/glass_card.dart';
import '../widgets/glass/skeleton.dart';
import 'authorize_sheet.dart';
import 'role_display.dart';

/// "Who is at the till?" — the step that now precedes every keypad.
///
/// A bare PIN pad asks a question it never states: it assumes you already know
/// both that accounts exist and which one is yours. Naming the accounts first
/// makes the multi-cashier model visible — four people, four PINs, four
/// different views of the app — which is exactly the thing a demo needs to
/// show rather than explain.
///
/// Only the PIN stays secret. Showing the names costs nothing a till does not
/// already print on every receipt.
class AccountPicker extends ConsumerWidget {
  const AccountPicker({super.key, required this.onSelected, this.filter});

  final ValueChanged<Employee> onSelected;

  /// Narrows the list — to the accounts able to approve an action, say. Null
  /// lists every active account.
  final bool Function(Employee employee)? filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final employees = ref.watch(employeesProvider);
    // Empty before sign-in, so the badge simply never appears on the login
    // screen — no branch needed for "nobody is on duty yet".
    final onDutyId = ref.watch(settingsProvider).valueOrNull?.employeeId ?? '';

    return employees.when(
      loading: () => Column(
        children: List.generate(
          3,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: AppDimensions.space8),
            child: Skeleton(height: 64, radius: AppDimensions.radiusLg),
          ),
        ),
      ),
      error: (_, _) => Text(
        l10n.authNoAccounts,
        textAlign: TextAlign.center,
        style: TextStyle(color: design.textMedium, fontSize: 13),
      ),
      data: (all) {
        // Inactive staff are excluded, not greyed out. Deactivating someone has
        // to actually lock them out; offering a tile that always rejects the
        // PIN would read as a broken keypad rather than a closed account.
        final active = all
            .where((e) => e.active && (filter?.call(e) ?? true))
            .toList();
        if (active.isEmpty) {
          return Text(
            l10n.authNoAccounts,
            textAlign: TextAlign.center,
            style: TextStyle(color: design.textMedium, fontSize: 13),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final e in active)
              Padding(
                padding: const EdgeInsets.only(bottom: AppDimensions.space8),
                child: _AccountTile(
                  employee: e,
                  onDuty: e.id == onDutyId,
                  onTap: () => onSelected(e),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.employee,
    required this.onDuty,
    required this.onTap,
  });

  final Employee employee;
  final bool onDuty;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;

    return GlassCard.solid(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space14,
        vertical: AppDimensions.space12,
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: design.primaryContainer,
            child: Text(
              initialsFor(employee.name),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: design.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  employee.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: design.textHigh,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      roleIcon(employee.role),
                      size: 13,
                      color: design.textMedium,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        roleLabel(l10n, employee.role),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: design.textMedium,
                        ),
                      ),
                    ),
                    if (onDuty) ...[
                      const SizedBox(width: AppDimensions.space8),
                      _OnDutyBadge(label: l10n.posOnDuty),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: design.textLow),
        ],
      ),
    );
  }
}

/// Marks whoever currently holds the till, so a handover sheet says who is
/// being handed over *from* without needing a sentence to say it.
class _OnDutyBadge extends StatelessWidget {
  const _OnDutyBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: design.successContainer,
        borderRadius: BorderRadius.circular(AppDimensions.radius8),
      ),
      // `success` on `successContainer` — the same pairing StatusBadge uses,
      // so a badge is one colour scheme across the app rather than two.
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: design.success,
        ),
      ),
    );
  }
}

/// Who currently holds the till, sized for the side rail's bottom slot.
///
/// The POS header carries the same information, but only on POS — Orders,
/// Tables, Dashboard and Settings had nowhere that answered "who am I signed
/// in as?", which matters on a device several people share. Tapping it opens
/// the same handover sheet, so the rail is a second door to one flow rather
/// than a second flow.
class OnDutyRailTile extends ConsumerWidget {
  const OnDutyRailTile({super.key, required this.expanded});

  /// Matches the rail: name and role only when there is room for them.
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final settings = ref.watch(settingsProvider).valueOrNull;
    if (settings == null) return const SizedBox.shrink();

    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: design.primaryContainer,
      child: Text(
        initialsFor(settings.cashierName),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: design.onPrimaryContainer,
        ),
      ),
    );

    final tile = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _switch(context, ref),
        borderRadius: BorderRadius.circular(AppDimensions.radius12),
        splashColor: design.textHigh.withValues(alpha: 0.08),
        highlightColor: design.textHigh.withValues(alpha: 0.06),
        hoverColor: design.textHigh.withValues(alpha: 0.05),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimensions.space8,
            vertical: AppDimensions.space8,
          ),
          child: Row(
            children: [
              // Same fixed-width icon column as the nav rows, so the avatar
              // sits on the same axis as the icons above it.
              SizedBox(
                width:
                    AppDimensions.navRailCollapsedWidth -
                    AppDimensions.space12 * 2 -
                    AppDimensions.space8 * 2,
                child: Center(child: avatar),
              ),
              const SizedBox(width: AppDimensions.space8),
              // Faded, not removed — same reason as the nav labels: the row is
              // laid out at the expanded width, so anything left opaque gets
              // sliced by the clip as the rail narrows and reads as a bug.
              Expanded(
                child: AnimatedOpacity(
                  opacity: expanded ? 1 : 0,
                  duration: const Duration(milliseconds: 140),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        settings.cashierName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: design.textHigh,
                        ),
                      ),
                      Text(
                        roleLabel(l10n, settings.employeeRole),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 11,
                          color: design.textMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              AnimatedOpacity(
                opacity: expanded ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                child: Icon(
                  Icons.unfold_more_rounded,
                  size: 16,
                  color: design.textLow,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return expanded
        ? tile
        : Tooltip(
            message:
                '${settings.cashierName} · '
                '${roleLabel(l10n, settings.employeeRole)}',
            child: tile,
          );
  }

  Future<void> _switch(BuildContext context, WidgetRef ref) async {
    final employee = await requestCashierSwitch(context);
    if (employee == null || !context.mounted) return;
    // The cart survives, exactly as it does from the POS header — a handover
    // mid-order is the common case and the queue does not pause for it.
    await ref.read(settingsProvider.notifier).signIn(employee);
    if (!context.mounted) return;
    showAppSnackBar(
      context,
      context.l10n.posSwitchedTo(employee.name),
      success: true,
    );
  }
}

/// The chosen account, shown above the keypad with a way back to the list.
///
/// Without it the second step is an anonymous keypad again and the choice just
/// made is invisible — which is the problem the picker exists to solve.
class SelectedAccountHeader extends StatelessWidget {
  const SelectedAccountHeader({
    super.key,
    required this.employee,
    required this.onChange,
  });

  final Employee employee;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;

    return GlassCard.solid(
      onTap: onChange,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.space14,
        vertical: AppDimensions.space10,
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: design.primaryContainer,
            child: Text(
              initialsFor(employee.name),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: design.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  employee.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: design.textHigh,
                  ),
                ),
                Text(
                  roleLabel(l10n, employee.role),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: design.textMedium),
                ),
              ],
            ),
          ),
          TextButton(onPressed: onChange, child: Text(l10n.authChangeAccount)),
        ],
      ),
    );
  }
}
