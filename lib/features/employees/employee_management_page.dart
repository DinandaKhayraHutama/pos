import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/role_display.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../data/models/employee.dart';
import '../../data/repositories/employee_repository.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/employee_provider.dart';
import '../../providers/settings_provider.dart';

/// Staff list: who can sign in, with what PIN, and at what level.
class EmployeeManagementPage extends ConsumerWidget {
  const EmployeeManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final employees = ref.watch(employeesProvider);
    final signedInId = ref.watch(settingsProvider).valueOrNull?.employeeId ?? '';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: GlassAppBar(title: l10n.employeesTitle),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openForm(context, ref, null),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: Text(l10n.employeeAdd),
          ),
          body: employees.when(
            loading: () => const LoadingIndicator(),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline_rounded,
              title: l10n.commonError,
              subtitle: '$e',
            ),
            data: (list) {
              if (list.isEmpty) {
                return EmptyState(
                  icon: Icons.badge_outlined,
                  title: l10n.employeesTitle,
                  subtitle: l10n.employeeAdd,
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppDimensions.space16,
                  AppDimensions.space16,
                  AppDimensions.space16,
                  96, // clears the FAB
                ),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _EmployeeTile(
                  employee: list[i],
                  isSignedIn: list[i].id == signedInId,
                  onEdit: () => _openForm(context, ref, list[i]),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _openForm(BuildContext context, WidgetRef ref, Employee? existing) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => _EmployeeFormSheet(existing: existing),
    );
  }
}

class _EmployeeTile extends StatelessWidget {
  const _EmployeeTile({
    required this.employee,
    required this.isSignedIn,
    required this.onEdit,
  });

  final Employee employee;
  final bool isSignedIn;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    return GlassCard.solid(
      onTap: onEdit,
      padding: const EdgeInsets.all(AppDimensions.space12),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: design.primaryContainer.withValues(alpha: 0.6),
              borderRadius: AppDimensions.radiusMd,
            ),
            alignment: Alignment.center,
            child: Icon(
              roleIcon(employee.role),
              color: design.onPrimaryContainer,
              size: 22,
            ),
          ),
          const SizedBox(width: AppDimensions.space12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        employee.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: design.textHigh,
                        ),
                      ),
                    ),
                    if (isSignedIn) ...[
                      const SizedBox(width: 6),
                      // Marks the account this device is currently using, which
                      // is also the one that cannot be deleted.
                      Icon(
                        Icons.check_circle_rounded,
                        size: 14,
                        color: design.success,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  roleLabel(l10n, employee.role),
                  style: TextStyle(color: design.textMedium, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  // The PIN is masked in the list. It is readable in the edit
                  // form, which is a deliberate line: a manager needs to be
                  // able to tell someone their PIN, but it should not be on
                  // screen while a queue of customers can see it.
                  '•••• · ${employee.active ? l10n.employeeActive : l10n.employeeInactive}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: employee.active ? design.textMedium : design.error,
                  ),
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

class _EmployeeFormSheet extends ConsumerStatefulWidget {
  const _EmployeeFormSheet({this.existing});
  final Employee? existing;

  @override
  ConsumerState<_EmployeeFormSheet> createState() => _EmployeeFormSheetState();
}

class _EmployeeFormSheetState extends ConsumerState<_EmployeeFormSheet> {
  late final _nameCtrl = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final _pinCtrl = TextEditingController(text: widget.existing?.pin ?? '');
  late EmployeeRole _role = widget.existing?.role ?? EmployeeRole.cashier;
  late bool _active = widget.existing?.active ?? true;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final isEdit = widget.existing != null;
    final signedInId =
        ref.watch(settingsProvider).valueOrNull?.employeeId ?? '';
    final isSelf = isEdit && widget.existing!.id == signedInId;

    return Padding(
      padding: EdgeInsets.only(
        left: AppDimensions.space16,
        right: AppDimensions.space16,
        top: AppDimensions.space8,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppDimensions.space16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                isEdit ? l10n.employeeEdit : l10n.employeeAdd,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: design.textHigh,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.close_rounded, color: design.textMedium),
              ),
            ],
          ),
          const SizedBox(height: AppDimensions.space8),
          GlassTextField(
            controller: _nameCtrl,
            label: l10n.employeeName,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: AppDimensions.space12),
          GlassTextField(
            controller: _pinCtrl,
            label: l10n.employeePin,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
          ),
          const SizedBox(height: AppDimensions.space12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.employeeRole,
              style: TextStyle(
                color: design.textMedium,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 6),
          // Wrap, not Row: three roles at their Indonesian labels ("Pemilik",
          // "Manajer", "Kasir") no longer fit three-across on a phone, and an
          // Expanded ChoiceChip ellipsises its own label rather than wrapping.
          Wrap(
            spacing: AppDimensions.space8,
            runSpacing: AppDimensions.space8,
            children: [
              for (final role in EmployeeRole.values)
                ChoiceChip(
                  selected: _role == role,
                  onSelected: (_) => setState(() => _role = role),
                  avatar: Icon(roleIcon(role), size: 18),
                  label: Text(roleLabel(l10n, role)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _roleHint(l10n, _role),
            style: TextStyle(color: design.textLow, fontSize: 11),
          ),
          const SizedBox(height: AppDimensions.space12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _active ? l10n.employeeActive : l10n.employeeInactive,
                  style: TextStyle(color: design.textHigh, fontSize: 14),
                ),
              ),
              Switch(
                value: _active,
                // Signing yourself out of the ability to sign in would lock the
                // till for whoever is holding it, so the switch is disabled on
                // your own account.
                onChanged: isSelf
                    ? null
                    : (v) => setState(() => _active = v),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: AppDimensions.space10),
            Text(
              _error!,
              style: TextStyle(color: design.error, fontSize: 12),
            ),
          ],
          const SizedBox(height: AppDimensions.space16),
          FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
          if (isEdit) ...[
            const SizedBox(height: AppDimensions.space8),
            TextButton.icon(
              onPressed: isSelf ? null : _confirmDelete,
              icon: Icon(Icons.delete_outline_rounded, color: design.error),
              label: Text(
                l10n.commonDelete,
                style: TextStyle(color: design.error),
              ),
            ),
            if (isSelf)
              Text(
                l10n.employeeCannotDeleteSelf,
                textAlign: TextAlign.center,
                style: TextStyle(color: design.textLow, fontSize: 11),
              ),
          ],
        ],
      ),
    );
  }

  /// One line on what the picked role can actually do.
  ///
  /// Roles are the one setting here with consequences the person filling in
  /// the form cannot see: choosing "Kasir" quietly removes the catalogue and
  /// the reports. Saying so at the point of choice is cheaper than a support
  /// call about a screen that "disappeared".
  String _roleHint(AppLocalizations l10n, EmployeeRole role) => switch (role) {
    EmployeeRole.cashier => l10n.employeeRoleCashierHint,
    EmployeeRole.manager => l10n.employeeRoleManagerHint,
    EmployeeRole.owner => l10n.employeeRoleOwnerHint,
  };

  Future<void> _save() async {
    final l10n = context.l10n;
    final name = _nameCtrl.text.trim();
    final pin = _pinCtrl.text.trim();

    if (name.isEmpty) {
      setState(() => _error = l10n.commonRequired);
      return;
    }
    // Exactly four digits: the login pad verifies as soon as the fourth digit
    // lands, so a PIN of any other length could never be entered.
    if (pin.length != 4) {
      setState(() => _error = l10n.employeePinLength);
      return;
    }
    // Two people sharing a PIN would silently attribute sales to whichever row
    // the lookup returned first.
    final taken = await EmployeeRepository.instance.isPinTaken(
      pin,
      exceptId: widget.existing?.id,
    );
    if (!mounted) return;
    if (taken) {
      setState(() => _error = l10n.employeePinTaken);
      return;
    }

    final existing = widget.existing;
    await ref
        .read(employeesProvider.notifier)
        .upsert(
          Employee(
            id: existing?.id ?? 'emp_${DateTime.now().millisecondsSinceEpoch}',
            name: name,
            pin: pin,
            role: _role,
            active: _active,
            sortOrder: existing?.sortOrder ?? 100,
          ),
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.employeeDeleteConfirm),
        content: Text(l10n.employeeDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(employeesProvider.notifier).delete(widget.existing!.id);
    if (mounted) Navigator.of(context).pop();
  }
}
