import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_chip.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../data/models/pos_register.dart';
import '../../data/repositories/pos_register_repository.dart';
import '../../providers/outlet_provider.dart';
import '../../providers/pos_register_provider.dart';

/// The tills a branch trades from: add one, rename one, retire one, and say
/// whether it runs the floor plan.
///
/// That last part is why this screen exists rather than a count of registers
/// in the outlet form. Table service used to be one switch for the whole
/// business, which forced every till in it to work the same way — a restaurant
/// with a dine-in counter and a takeaway window had to pick one. It is a
/// per-till setting now, and this is where it is set.
///
/// Scoped to one branch at a time on purpose: a flat list of every till in the
/// chain reads as a pile of "Kasir 1"s, and each branch is allowed its own.
class RegisterManagementPage extends ConsumerStatefulWidget {
  const RegisterManagementPage({super.key, this.outletId});

  /// Which branch to show. Null means the one this device is standing in,
  /// which is what the Settings entry point wants; the Outlets screen passes
  /// the branch whose row was tapped.
  final String? outletId;

  @override
  ConsumerState<RegisterManagementPage> createState() =>
      _RegisterManagementPageState();
}

class _RegisterManagementPageState
    extends ConsumerState<RegisterManagementPage> {
  /// Null until the user picks a different branch, so the initial value can
  /// come from a provider that is still loading on the first frame.
  String? _chosenOutletId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final outlets = ref.watch(outletsProvider);
    final activeOutletId = ref.watch(activeOutletProvider).valueOrNull?.id;
    final outletId = _chosenOutletId ?? widget.outletId ?? activeOutletId;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: GlassAppBar(title: l10n.registersTitle),
          floatingActionButton: outletId == null
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _openForm(context, outletId, null),
                  icon: const Icon(Icons.point_of_sale_rounded),
                  label: Text(l10n.registerAdd),
                ),
          body: outletId == null
              ? EmptyState(
                  icon: Icons.storefront_outlined,
                  title: l10n.outletsTitle,
                  subtitle: l10n.outletAdd,
                )
              : Column(
                  children: [
                    // Only worth a row of chips once there is more than one
                    // branch — a single-outlet business would just be reading
                    // its own name back.
                    outlets.maybeWhen(
                      data: (list) {
                        final open = list.where((o) => o.active).toList();
                        if (open.length < 2) return const SizedBox.shrink();
                        return SizedBox(
                          height: 44,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.fromLTRB(
                              AppDimensions.space16,
                              AppDimensions.space10,
                              AppDimensions.space16,
                              0,
                            ),
                            children: [
                              for (final o in open)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: GlassFilterChip(
                                    label: o.name,
                                    icon: Icons.storefront_rounded,
                                    selected: o.id == outletId,
                                    onTap: () =>
                                        setState(() => _chosenOutletId = o.id),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                      orElse: () => const SizedBox.shrink(),
                    ),
                    Expanded(child: _RegisterList(outletId: outletId)),
                  ],
                ),
        ),
      ),
    );
  }

  void _openForm(
    BuildContext context,
    String outletId,
    PosRegister? existing,
  ) {
    showGlassSheet<void>(
      context: context,
      builder: (_) =>
          _RegisterFormSheet(outletId: outletId, existing: existing),
    );
  }
}

class _RegisterList extends ConsumerWidget {
  const _RegisterList({required this.outletId});
  final String outletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final registers = ref.watch(posRegistersProvider(outletId));

    return registers.when(
      loading: () => const LoadingIndicator(),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline_rounded,
        title: l10n.commonError,
        subtitle: '$e',
      ),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            icon: Icons.point_of_sale_outlined,
            title: l10n.registersEmpty,
            subtitle: l10n.registerAdd,
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
          itemBuilder: (_, i) => _RegisterTile(
            register: list[i],
            onEdit: () => showGlassSheet<void>(
              context: context,
              builder: (_) => _RegisterFormSheet(
                outletId: outletId,
                existing: list[i],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RegisterTile extends StatelessWidget {
  const _RegisterTile({required this.register, required this.onEdit});

  final PosRegister register;
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
              Icons.point_of_sale_rounded,
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
                Text(
                  register.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: design.textHigh,
                  ),
                ),
                const SizedBox(height: 2),
                // What this till is FOR, in the row rather than behind a tap.
                // It is the whole reason a business has more than one.
                Row(
                  children: [
                    Icon(
                      register.tableService
                          ? Icons.table_restaurant_rounded
                          : Icons.takeout_dining_rounded,
                      size: 13,
                      color: design.textMedium,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        register.tableService
                            ? l10n.settingsTableServiceOn
                            : l10n.settingsTableServiceOff,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: design.textMedium,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!register.active) _Pill(text: l10n.registerRetired),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final tone = context.design.textLow;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppDimensions.radius8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: tone,
        ),
      ),
    );
  }
}

class _RegisterFormSheet extends ConsumerStatefulWidget {
  const _RegisterFormSheet({required this.outletId, this.existing});

  final String outletId;
  final PosRegister? existing;

  @override
  ConsumerState<_RegisterFormSheet> createState() => _RegisterFormSheetState();
}

class _RegisterFormSheetState extends ConsumerState<_RegisterFormSheet> {
  late final TextEditingController _nameCtrl = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late bool _tableService = widget.existing?.tableService ?? true;
  late bool _active = widget.existing?.active ?? true;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final isEdit = widget.existing != null;

    return Padding(
      padding: EdgeInsets.only(
        left: AppDimensions.space16,
        right: AppDimensions.space16,
        top: AppDimensions.space16,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppDimensions.space16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                isEdit ? l10n.registerEdit : l10n.registerAdd,
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
            label: l10n.registerName,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: AppDimensions.space12),
          _SwitchRow(
            icon: Icons.table_restaurant_outlined,
            title: l10n.registerTableService,
            subtitle: _tableService
                ? l10n.settingsTableServiceOn
                : l10n.settingsTableServiceOff,
            value: _tableService,
            onChanged: (v) => setState(() => _tableService = v),
          ),
          const Divider(height: AppDimensions.space20),
          _SwitchRow(
            icon: Icons.power_settings_new_rounded,
            title: _active ? l10n.registerActive : l10n.registerRetired,
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppDimensions.space10),
            Text(_error!, style: TextStyle(color: design.error, fontSize: 12)),
          ],
          const SizedBox(height: AppDimensions.space16),
          FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
          if (isEdit) ...[
            const SizedBox(height: AppDimensions.space8),
            TextButton.icon(
              onPressed: _confirmDelete,
              icon: Icon(Icons.delete_outline_rounded, color: design.error),
              label: Text(
                l10n.commonDelete,
                style: TextStyle(color: design.error),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.commonRequired);
      return;
    }

    final repo = PosRegisterRepository.instance;
    // Per branch, not globally: two tills called "Kasir 1" at one counter is
    // the case that actually confuses somebody, and every branch is allowed
    // its own.
    if (await repo.isNameTaken(
      name,
      outletId: widget.outletId,
      exceptId: widget.existing?.id,
    )) {
      if (!mounted) return;
      setState(() => _error = l10n.registerNameTaken);
      return;
    }

    // Retiring the last active till would leave every cashier at this branch
    // with nothing to sign on to and no way back — the picker would be empty
    // and the sell screen unreachable.
    if (!_active) {
      final active = await repo.byOutlet(widget.outletId, onlyActive: true);
      final wouldStrand =
          active.length <= 1 && active.any((r) => r.id == widget.existing?.id);
      if (!mounted) return;
      if (wouldStrand) {
        setState(() => _error = l10n.registerKeepOneActive);
        return;
      }
    }

    final existing = widget.existing;
    await ref
        .read(posRegistersProvider(widget.outletId).notifier)
        .save(
          PosRegister(
            id:
                existing?.id ??
                'pos_${DateTime.now().millisecondsSinceEpoch}',
            outletId: widget.outletId,
            name: name,
            tableService: _tableService,
            active: _active,
            sortOrder: existing?.sortOrder ?? 100,
          ),
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final l10n = context.l10n;
    final id = widget.existing!.id;
    final repo = PosRegisterRepository.instance;

    // A till with drawer counts or sales filed against it cannot be deleted:
    // those rows would point at an id that resolves to nothing, and a shift
    // report naming a till nobody can look up is a number with no story.
    // Retiring keeps the history readable, which is what somebody means when
    // they say a till is gone.
    if (await repo.sessionCount(id) > 0 || await repo.orderCount(id) > 0) {
      if (!mounted) return;
      setState(() => _error = l10n.registerHasHistory);
      return;
    }
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.registerDeleteConfirm),
        content: Text(l10n.registerDeleteConfirmBody),
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
    await ref.read(posRegistersProvider(widget.outletId).notifier).remove(id);
    if (mounted) Navigator.of(context).pop();
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Row(
      children: [
        Icon(icon, size: 20, color: design.textMedium),
        const SizedBox(width: AppDimensions.space12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: design.textHigh,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(color: design.textMedium, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
