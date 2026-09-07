import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import '../../data/models/outlet.dart';
import '../../data/repositories/outlet_repository.dart';
import '../../providers/outlet_provider.dart';
import '../../providers/settings_provider.dart';

/// The branches the business trades from: open one, rename one, close one, and
/// say which one the tablet in your hand is standing in.
///
/// That last part is why this screen is not simply a list. Everything scoped
/// by branch — stock, the floor plan, the sales list — reads the device's
/// outlet, so a device pointed at the wrong branch shows the wrong shop's
/// numbers and sells from the wrong shelf. The current one is marked on the
/// list rather than buried in settings.
class OutletManagementPage extends ConsumerWidget {
  const OutletManagementPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final outlets = ref.watch(outletsProvider);
    final active = ref.watch(activeOutletProvider).valueOrNull;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: GlassAppBar(title: l10n.outletsTitle),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _openForm(context, null),
            icon: const Icon(Icons.add_business_rounded),
            label: Text(l10n.outletAdd),
          ),
          body: outlets.when(
            loading: () => const LoadingIndicator(),
            error: (e, _) => EmptyState(
              icon: Icons.error_outline_rounded,
              title: l10n.commonError,
              subtitle: '$e',
            ),
            data: (list) {
              if (list.isEmpty) {
                return EmptyState(
                  icon: Icons.storefront_outlined,
                  title: l10n.outletsTitle,
                  subtitle: l10n.outletAdd,
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
                itemBuilder: (_, i) => _OutletTile(
                  outlet: list[i],
                  isHere: list[i].id == active?.id,
                  onEdit: () => _openForm(context, list[i]),
                  onUseHere: () => ref
                      .read(settingsProvider.notifier)
                      .setOutletId(list[i].id),
                  onManageRegisters: () =>
                      context.push('/registers?outlet=${list[i].id}'),
                  onManageTables: () =>
                      context.push('/floorplan?outlet=${list[i].id}'),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _openForm(BuildContext context, Outlet? existing) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => _OutletFormSheet(existing: existing),
    );
  }
}

class _OutletTile extends StatelessWidget {
  const _OutletTile({
    required this.outlet,
    required this.isHere,
    required this.onEdit,
    required this.onUseHere,
    required this.onManageRegisters,
    required this.onManageTables,
  });

  final Outlet outlet;

  /// Whether this is the branch the device is standing in.
  final bool isHere;

  final VoidCallback onEdit;
  final VoidCallback onUseHere;
  final VoidCallback onManageRegisters;
  final VoidCallback onManageTables;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;

    return GlassCard.solid(
      onTap: onEdit,
      padding: const EdgeInsets.all(AppDimensions.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                  Icons.storefront_rounded,
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
                      outlet.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: design.textHigh,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      outlet.address?.isNotEmpty == true
                          ? outlet.address!
                          : (outlet.active ? l10n.outletOpen : l10n.outletClosed),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: design.textMedium),
                    ),
                  ],
                ),
              ),
              if (!outlet.active)
                _Pill(text: l10n.outletClosed, tone: design.textLow),
            ],
          ),
          const SizedBox(height: AppDimensions.space10),
          // The device's own branch is stated, not merely implied by a colour:
          // pointing a tablet at the wrong shop is the one mistake here that
          // silently produces wrong numbers all day.
          //
          // A `Wrap`, not a `Row` with a `Spacer` — three items (the device
          // marker plus two management links) in Indonesian routinely no
          // longer fit one line on a phone-width card, and a fixed `Row`
          // overflows instead of degrading. `spaceBetween` keeps the original
          // look whenever there IS room; anything that doesn't fit drops to
          // its own line rather than clipping.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: [
              if (isHere)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: design.success,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        l10n.outletThisDevice,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: design.success,
                        ),
                      ),
                    ],
                  ),
                )
              else if (outlet.active)
                TextButton.icon(
                  onPressed: onUseHere,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.tablet_mac_rounded, size: 16),
                  label: Text(l10n.outletUseHere),
                )
              else
                const SizedBox.shrink(),
              Wrap(
                children: [
                  // Straight to THIS branch's floor plan, for the same reason
                  // the tills button is: a manager configuring tables for a
                  // shop they are not standing in must land on that shop, not
                  // the device's.
                  TextButton.icon(
                    onPressed: onManageTables,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.table_restaurant_rounded, size: 16),
                    label: Text(l10n.tableManagementTitle),
                  ),
                  TextButton.icon(
                    onPressed: onManageRegisters,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.point_of_sale_rounded, size: 16),
                    label: Text(l10n.registersManage),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.tone});
  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(AppDimensions.radius8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: tone),
    ),
  );
}

class _OutletFormSheet extends ConsumerStatefulWidget {
  const _OutletFormSheet({this.existing});
  final Outlet? existing;

  @override
  ConsumerState<_OutletFormSheet> createState() => _OutletFormSheetState();
}

class _OutletFormSheetState extends ConsumerState<_OutletFormSheet> {
  late final TextEditingController _nameCtrl = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _addressCtrl = TextEditingController(
    text: widget.existing?.address ?? '',
  );
  late bool _active = widget.existing?.active ?? true;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
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
                isEdit ? l10n.outletEdit : l10n.outletAdd,
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
            label: l10n.outletName,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: AppDimensions.space12),
          GlassTextField(
            controller: _addressCtrl,
            label: l10n.outletAddress,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: AppDimensions.space12),
          Row(
            children: [
              Expanded(
                child: Text(
                  _active ? l10n.outletOpen : l10n.outletClosed,
                  style: TextStyle(color: design.textHigh, fontSize: 14),
                ),
              ),
              Switch(
                value: _active,
                onChanged: (v) => setState(() => _active = v),
              ),
            ],
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

    final repo = OutletRepository.instance;
    // Two branches called "Bintaro" make every per-outlet report unreadable.
    if (await repo.isNameTaken(name, exceptId: widget.existing?.id)) {
      if (!mounted) return;
      setState(() => _error = l10n.outletNameTaken);
      return;
    }

    // Closing the last open branch would leave every device with nowhere to
    // sell from, and the fallback in `activeOutletProvider` has nothing to
    // fall back to.
    if (!_active) {
      final open = await repo.all(onlyActive: true);
      final wouldClose =
          open.length <= 1 && open.any((o) => o.id == widget.existing?.id);
      if (!mounted) return;
      if (wouldClose) {
        setState(() => _error = l10n.outletKeepOneOpen);
        return;
      }
    }

    final existing = widget.existing;
    await ref
        .read(outletsProvider.notifier)
        .save(
          Outlet(
            id: existing?.id ?? 'outlet_${DateTime.now().millisecondsSinceEpoch}',
            name: name,
            address: _addressCtrl.text.trim().isEmpty
                ? null
                : _addressCtrl.text.trim(),
            active: _active,
            sortOrder: existing?.sortOrder ?? 100,
          ),
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final l10n = context.l10n;
    final id = widget.existing!.id;

    // A branch with sales cannot be deleted: its orders would point at an id
    // that resolves to nothing, and the chain's totals would stop adding up.
    // Closing keeps the history readable, which is what the person actually
    // wants when they say a shop is gone.
    if (await OutletRepository.instance.orderCount(id) > 0) {
      if (!mounted) return;
      setState(() => _error = l10n.outletHasSales);
      return;
    }
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.outletDeleteConfirm),
        content: Text(l10n.outletDeleteConfirmBody),
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
    await ref.read(outletsProvider.notifier).remove(id);
    if (mounted) Navigator.of(context).pop();
  }
}
