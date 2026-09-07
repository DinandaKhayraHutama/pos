import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../core/widgets/status_badge.dart';
import '../../data/models/enums.dart';
import '../../data/models/table.dart';
import '../../data/repositories/table_repository.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/order_provider.dart';
import '../../providers/outlet_provider.dart';

/// The floor plan's configuration, for ONE branch at a time: add a table,
/// rename one, resize it, move it to another area, or take it out of
/// rotation.
///
/// Deliberately a separate screen from [TablesPage] (`/tables`) rather than
/// an "edit mode" bolted onto it — that screen is the cashier's operational
/// board (seat/clear a table, every role that can sell holds the permission),
/// this one is Manager/Owner configuration (`manageOutlets`, same gate
/// `/registers` uses). Sharing a route would mean sharing a permission the
/// two audiences don't actually share.
///
/// Table count and capacity are real data here, not a fixed seed: a business
/// with two floors and one with six all use the same add/edit/deactivate
/// flow, scoped to whichever outlet is chosen — exactly the shape
/// `RegisterManagementPage` already established for tills.
class TableManagementPage extends ConsumerStatefulWidget {
  const TableManagementPage({super.key, this.outletId});

  /// Which branch to show. Null means the one this device is standing in;
  /// the Outlets screen passes the branch whose row was tapped.
  final String? outletId;

  @override
  ConsumerState<TableManagementPage> createState() =>
      _TableManagementPageState();
}

class _TableManagementPageState extends ConsumerState<TableManagementPage> {
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
          appBar: GlassAppBar(title: l10n.tableManagementTitle),
          floatingActionButton: outletId == null
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _openForm(context, outletId, null),
                  icon: const Icon(Icons.table_restaurant_rounded),
                  label: Text(l10n.tablesAddTable),
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
                    // branch to pick between.
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
                    Expanded(child: _TableManagementList(outletId: outletId)),
                  ],
                ),
        ),
      ),
    );
  }

  void _openForm(
    BuildContext context,
    String outletId,
    RestaurantTable? existing,
  ) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => _TableFormSheet(outletId: outletId, existing: existing),
    );
  }
}

class _TableManagementList extends ConsumerWidget {
  const _TableManagementList({required this.outletId});
  final String outletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final tables = ref.watch(tableManagementProvider(outletId));

    return tables.when(
      loading: () => const LoadingIndicator(),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline_rounded,
        title: l10n.commonError,
        subtitle: '$e',
      ),
      data: (list) {
        if (list.isEmpty) {
          return EmptyState(
            icon: Icons.table_restaurant_outlined,
            title: l10n.tableManagementEmpty,
            subtitle: l10n.tablesAddTable,
          );
        }
        final floors = <String, List<RestaurantTable>>{};
        for (final t in list) {
          floors.putIfAbsent(t.floor, () => []).add(t);
        }
        final floorKeys = floors.keys.toList()..sort();

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppDimensions.space16,
            AppDimensions.space16,
            AppDimensions.space16,
            96, // clears the FAB
          ),
          children: [
            for (final floor in floorKeys) ...[
              Padding(
                padding: const EdgeInsets.only(
                  bottom: AppDimensions.space8,
                  top: AppDimensions.space4,
                ),
                child: Text(
                  _floorLabel(floor, l10n),
                  style: TextStyle(
                    color: context.design.textMedium,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              for (final t in floors[floor]!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _TableManagementTile(
                    table: t,
                    onEdit: () => showGlassSheet<void>(
                      context: context,
                      builder: (_) =>
                          _TableFormSheet(outletId: outletId, existing: t),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  // Mirrors `TablesPage._floorLabel` / `TablePickerSheet._floorLabel`: a
  // table seeded before floor/area became free text still stores the literal
  // 'floor_N' key, so this screen shows the same localized label those two
  // already do rather than the raw string. A table created through THIS
  // screen never produces one of these keys, so new floors bypass the switch
  // entirely and render exactly as typed.
  String _floorLabel(String floor, AppLocalizations l10n) => switch (floor) {
    'floor_1' => l10n.tablesFloor1,
    'floor_2' => l10n.tablesFloor2,
    'floor_3' => l10n.tablesFloor3,
    'floor_4' => l10n.tablesFloor4,
    _ => floor,
  };
}

class _TableManagementTile extends StatelessWidget {
  const _TableManagementTile({required this.table, required this.onEdit});

  final RestaurantTable table;
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
              Icons.table_restaurant_rounded,
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
                  table.name,
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
                  l10n.tablesCapacity(table.capacity),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: design.textMedium),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppDimensions.space8),
          StatusBadge(status: table.status, compact: true),
          if (!table.active) ...[
            const SizedBox(width: 6),
            _Pill(text: l10n.tablesInactive),
          ],
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

class _TableFormSheet extends ConsumerStatefulWidget {
  const _TableFormSheet({required this.outletId, this.existing});

  final String outletId;
  final RestaurantTable? existing;

  @override
  ConsumerState<_TableFormSheet> createState() => _TableFormSheetState();
}

class _TableFormSheetState extends ConsumerState<_TableFormSheet> {
  late final TextEditingController _nameCtrl = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _capacityCtrl = TextEditingController(
    text: '${widget.existing?.capacity ?? 4}',
  );
  late final TextEditingController _floorCtrl = TextEditingController(
    text: widget.existing?.floor ?? '',
  );
  late bool _active = widget.existing?.active ?? true;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _capacityCtrl.dispose();
    _floorCtrl.dispose();
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
                isEdit ? l10n.tablesEditTable : l10n.tablesAddTable,
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
            label: l10n.tablesTableName,
            autofocus: !isEdit,
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: AppDimensions.space12),
          Row(
            children: [
              Expanded(
                child: GlassTextField(
                  controller: _capacityCtrl,
                  label: l10n.tablesCapacityLabel,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ),
              const SizedBox(width: AppDimensions.space10),
              Expanded(
                child: GlassTextField(
                  controller: _floorCtrl,
                  label: l10n.tablesFloor,
                  hint: l10n.tablesFloorHint,
                  textCapitalization: TextCapitalization.words,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppDimensions.space12),
          _SwitchRow(
            icon: Icons.power_settings_new_rounded,
            title: _active ? l10n.tablesActive : l10n.tablesInactive,
            subtitle: _active ? l10n.tablesActiveHint : l10n.tablesInactiveHint,
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
    final floor = _floorCtrl.text.trim();
    if (floor.isEmpty) {
      setState(() => _error = l10n.commonRequired);
      return;
    }
    final capacity = int.tryParse(_capacityCtrl.text.trim()) ?? 0;
    if (capacity < 1) {
      setState(() => _error = l10n.tablesCapacityInvalid);
      return;
    }

    final repo = TableRepository.instance;
    // Per branch, not globally — every outlet is allowed its own "Meja 01",
    // the same reasoning `PosRegisterRepository.isNameTaken` already applies
    // to tills.
    if (await repo.isNameTaken(
      name,
      outletId: widget.outletId,
      exceptId: widget.existing?.id,
    )) {
      if (!mounted) return;
      setState(() => _error = l10n.tablesNameTaken);
      return;
    }

    final existing = widget.existing;
    await ref
        .read(tableManagementProvider(widget.outletId).notifier)
        .save(
          RestaurantTable(
            id: existing?.id ?? 'table_${DateTime.now().millisecondsSinceEpoch}',
            outletId: widget.outletId,
            name: name,
            capacity: capacity,
            floor: floor,
            // Operational status is untouched here on purpose — it belongs to
            // the floor board, not to this configuration form. A brand new
            // table starts available; editing an existing one keeps whatever
            // it currently is, even while deactivating it.
            status: existing?.status ?? TableStatus.available,
            sortOrder: existing?.sortOrder ?? 100,
            active: _active,
          ),
        );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _confirmDelete() async {
    final l10n = context.l10n;
    final id = widget.existing!.id;
    final repo = TableRepository.instance;

    // A table with orders filed against it cannot be deleted: `table_name`
    // on those rows is a snapshot, not a join, so the delete itself would
    // not corrupt a past receipt — but there would be nothing left for
    // anyone to reopen if the table comes back into use, which is exactly
    // what deactivating is for. Delete stays for a table nobody ever sat a
    // guest at.
    if (await repo.orderCount(id) > 0) {
      if (!mounted) return;
      setState(() => _error = l10n.tablesHasHistory);
      return;
    }
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.tablesDeleteConfirm),
        content: Text(l10n.tablesDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref
        .read(tableManagementProvider(widget.outletId).notifier)
        .remove(id);
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
