import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/auth/authorize_sheet.dart';
import '../../core/auth/permissions.dart';
import '../../core/localization/l10n.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/app_snack_bar.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/glass/glass_sheet.dart';
import '../../core/widgets/glass/glass_text_field.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../data/models/shift.dart';
import '../../data/repositories/shift_repository.dart';
import '../../providers/pos_register_provider.dart';
import '../../providers/shift_provider.dart';
import '../../providers/outlet_provider.dart';
import '../../providers/settings_provider.dart';

/// Opening and closing the till, plus the closing history.
///
/// Cash only, by design: card and QRIS settle with the processor, so counting
/// them here would produce an "expected" number nobody can check against the
/// drawer. They are still shown, so the cashier sees the whole session.
class ShiftPage extends ConsumerWidget {
  const ShiftPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final shift = ref.watch(currentShiftProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: GlassAppBar(
            // The drawer being counted belongs to one branch's till, so the
            // screen that closes it has to say which.
            title: [
              l10n.shiftTitle,
              ref.watch(activeOutletProvider).valueOrNull?.name,
            ].whereType<String>().join(' · '),
          ),
          body: shift.when(
            loading: () => const LoadingIndicator(),
            error: (e, _) => Center(child: Text('$e')),
            data: (open) => ListView(
              padding: const EdgeInsets.all(AppDimensions.space16),
              children: [
                if (open == null)
                  const PosSessionOpenCard()
                else
                  _OpenShiftSummary(shift: open),
                // Manager and above: what should be in every drawer on the
                // floor right now, without waiting for anyone to close.
                if (ref
                        .watch(settingsProvider)
                        .valueOrNull
                        ?.can(AppPermission.viewCashDrawer) ??
                    false) ...[
                  const SizedBox(height: AppDimensions.space20),
                  const _CashDrawerSection(),
                ],
                const SizedBox(height: AppDimensions.space20),
                const _ShiftHistory(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What should be in each open drawer right now.
///
/// A manager's read-only view. It deliberately does not offer to close
/// anyone's shift: the count is the cashier's to make and to sign, and a
/// supervisor closing it for them would put a variance on someone's record
/// that they never saw.
class _CashDrawerSection extends ConsumerWidget {
  const _CashDrawerSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final drawers = ref.watch(openDrawersProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 18,
              color: design.textMedium,
            ),
            const SizedBox(width: AppDimensions.space8),
            Text(
              l10n.shiftDrawerNow,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: design.textHigh,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          l10n.shiftDrawerNowHint,
          style: TextStyle(fontSize: 11, color: design.textLow),
        ),
        const SizedBox(height: AppDimensions.space8),
        drawers.when(
          loading: () => LoadingIndicator.skeleton(lines: 2),
          error: (e, _) => Text('$e'),
          data: (rows) {
            if (rows.isEmpty) {
              return Text(
                l10n.shiftNoneOpen,
                style: TextStyle(fontSize: 12, color: design.textMedium),
              );
            }
            return GlassCard.solid(
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: AppDimensions.space20),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Which till, then who is on it. A supervisor
                              // checking drawers is walking the counter, so
                              // the till is what they are matching against.
                              Text(
                                [
                                  rows[i].shift.posName,
                                  rows[i].shift.employeeName,
                                ].whereType<String>().join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: design.textHigh,
                                ),
                              ),
                              Text(
                                '${l10n.shiftOpenedAt(DateFormat('HH:mm').format(rows[i].shift.openedAt))}'
                                ' · ${l10n.shiftOrders} ${rows[i].totals.orderCount}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: design.textMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          MoneyFormatter.format(
                            rows[i].shift.openingCash + rows[i].totals.cash,
                          ),
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: design.primary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Pick a till, put the float in the drawer, start selling.
///
/// The step a cashier now takes before the sell screen will open at all. Each
/// till is in one of three states, and saying which matters more than simply
/// enabling or disabling a row: free, held by ME (resume — the common case
/// after a restart or a sign-out), or held by somebody else, whose name is
/// shown because "why can I not open this" is what a greyed-out row leaves
/// unanswered.
///
/// PUBLIC and used from two places: here, when someone reaches the shift
/// screen with nothing open, and from `PosPage`, which shows this same card
/// in place of the catalogue instead of redirecting away — the sell screen
/// lives inside `MainShell`'s `ShellRoute`, and a redirect to the pushed
/// `/shift` route left the bottom nav (and the whole shell) unmounted, which
/// is exactly the "stuck with no way to switch tabs" bug this avoids. Do not
/// fork this widget; a second copy is a second place for the register lock,
/// the busy-guard and the "resume mine" logic to drift apart.
class PosSessionOpenCard extends ConsumerStatefulWidget {
  const PosSessionOpenCard({super.key});

  @override
  ConsumerState<PosSessionOpenCard> createState() => _PosSessionOpenCardState();
}

class _PosSessionOpenCardState extends ConsumerState<PosSessionOpenCard> {
  final _cashCtrl = TextEditingController();
  String? _selectedId;
  bool _busy = false;

  @override
  void dispose() {
    _cashCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final slots = ref.watch(registerSlotsProvider);
    final me = ref.watch(settingsProvider).valueOrNull?.employeeId ?? '';

    return GlassCard.solid(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.sessionPickTitle,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: design.textHigh,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.sessionPickHint,
            style: TextStyle(color: design.textMedium, fontSize: 13),
          ),
          const SizedBox(height: AppDimensions.space16),
          slots.when(
            loading: () => LoadingIndicator.skeleton(lines: 2),
            error: (e, _) =>
                Text('$e', style: TextStyle(color: design.error, fontSize: 12)),
            data: (list) {
              if (list.isEmpty) {
                return Text(
                  l10n.sessionNoRegisters,
                  style: TextStyle(color: design.textMedium, fontSize: 13),
                );
              }
              // Only a free till can be selected here. One of mine is resumed
              // in a single tap — there is no float to count for a drawer that
              // is already open — and one held by somebody else is not mine to
              // take.
              return Column(
                children: [
                  for (final slot in list)
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: AppDimensions.space8,
                      ),
                      child: _RegisterSlotTile(
                        slot: slot,
                        mine: slot.session?.employeeId == me,
                        selected: slot.register.id == _selectedId,
                        onTap: _busy
                            ? null
                            : () => _onSlotTapped(slot, slot.session?.employeeId == me),
                      ),
                    ),
                  if (_selectedId != null) ...[
                    const SizedBox(height: AppDimensions.space8),
                    GlassTextField(
                      controller: _cashCtrl,
                      label: l10n.shiftOpeningCash,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      prefixText: 'Rp ',
                    ),
                    const SizedBox(height: AppDimensions.space16),
                    FilledButton.icon(
                      onPressed: _busy ? null : _open,
                      icon: const Icon(Icons.lock_open_rounded),
                      label: Text(l10n.shiftOpen),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  void _onSlotTapped(RegisterSlot slot, bool mine) {
    if (mine) {
      _resume(slot.session!.id);
      return;
    }
    if (slot.session != null) return; // held by someone else
    setState(() => _selectedId = slot.register.id);
  }

  /// Signs this device back on to a session that is already open.
  ///
  /// No cash is counted: the float went in when it was opened, and asking
  /// again would invite a second, different number for one drawer.
  Future<void> _resume(String sessionId) async {
    setState(() => _busy = true);
    await ref.read(settingsProvider.notifier).openPosSession(sessionId);
    if (mounted) _leaveForTill();
  }

  Future<void> _open() async {
    final settings = ref.read(settingsProvider).valueOrNull;
    final slots = ref.read(registerSlotsProvider).valueOrNull;
    if (settings == null || slots == null || _selectedId == null) return;
    final register = slots
        .firstWhere((s) => s.register.id == _selectedId)
        .register;
    final outlet = ref.read(activeOutletProvider).valueOrNull;

    setState(() => _busy = true);
    try {
      // An empty float is legitimate (a card-only till), so this parses to 0
      // rather than refusing to open.
      final shift = await ShiftRepository.instance.open(
        employeeId: settings.employeeId.isEmpty
            ? 'cashier'
            : settings.employeeId,
        employeeName: settings.cashierName,
        openingCash: int.tryParse(_cashCtrl.text.trim()) ?? 0,
        posId: register.id,
        posName: register.name,
        outletId: outlet?.id,
        outletName: outlet?.name,
      );
      await ref.read(settingsProvider.notifier).openPosSession(shift.id);
      if (mounted) _leaveForTill();
    } on RegisterBusyException catch (e) {
      // Somebody claimed the till between this screen loading and the tap.
      // Re-read rather than only complaining, so the list the cashier is
      // looking at stops offering a till that is gone.
      ref.invalidate(registerSlotsProvider);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _selectedId = null;
      });
      showAppSnackBar(context, context.l10n.sessionBusy(e.holderName));
    }
  }

  /// Refreshes what the session changed and takes the cashier to the till.
  ///
  /// The `go('/')` matters only when this card is reached via the PUSHED
  /// `/shift` route (e.g. from Settings) — there is no redirect to carry
  /// someone back to the sell screen once opening a session stops blocking
  /// it, so this does that explicitly. When the same card is embedded
  /// directly inside `PosPage`'s own gate, `context` is already at `/`: the
  /// settings update above already flips `hasPosSession`, `PosPage` rebuilds
  /// on its own, and this call is a harmless same-location no-op.
  void _leaveForTill() {
    ref.invalidate(currentShiftProvider);
    ref.invalidate(shiftHistoryProvider);
    // The floor-wide drawer view is derived from the open shifts, so it goes
    // stale the moment one opens or closes.
    ref.invalidate(openDrawersProvider);
    ref.invalidate(registerSlotsProvider);
    setState(() => _busy = false);
    if (ref.read(settingsProvider).valueOrNull?.can(AppPermission.sell) ==
        true) {
      context.go('/');
    }
  }
}

class _RegisterSlotTile extends StatelessWidget {
  const _RegisterSlotTile({
    required this.slot,
    required this.mine,
    required this.selected,
    required this.onTap,
  });

  final RegisterSlot slot;

  /// Whether the session on this till is the signed-in cashier's own — the
  /// difference between "resume" and "somebody else has it".
  final bool mine;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final taken = slot.session != null && !mine;

    final (label, tone) = switch ((taken, mine)) {
      (true, _) => (l10n.sessionInUse(slot.session!.employeeName), design.error),
      (_, true) => (l10n.sessionResume, design.success),
      _ => (
        slot.register.tableService
            ? l10n.settingsTableServiceOn
            : l10n.settingsTableServiceOff,
        design.textMedium,
      ),
    };

    return Opacity(
      opacity: taken ? 0.55 : 1,
      child: GlassCard.solid(
        onTap: taken ? null : onTap,
        padding: const EdgeInsets.all(AppDimensions.space12),
        child: Row(
          children: [
            Icon(
              slot.register.tableService
                  ? Icons.table_restaurant_rounded
                  : Icons.takeout_dining_rounded,
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
                    slot.register.name,
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
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: tone),
                  ),
                ],
              ),
            ),
            if (taken)
              Icon(Icons.lock_rounded, size: 18, color: design.error)
            else if (mine)
              Icon(Icons.play_arrow_rounded, size: 20, color: design.success)
            else if (selected)
              Icon(Icons.check_circle_rounded, size: 18, color: design.primary),
          ],
        ),
      ),
    );
  }
}

class _OpenShiftSummary extends ConsumerWidget {
  const _OpenShiftSummary({required this.shift});
  final Shift shift;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final totals = ref.watch(currentShiftTotalsProvider);
    final time = DateFormat('d MMM, HH:mm').format(shift.openedAt);

    return GlassCard.solid(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The till first, then who opened it. Which drawer this is
                    // decides what the cashier is about to count, and after a
                    // handover the name below is no longer the person reading
                    // the screen.
                    Text(
                      shift.posName ?? l10n.shiftNoRegister,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: design.textHigh,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${shift.employeeName} · ${l10n.shiftOpenedAt(time)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: design.textMedium, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.lock_open_rounded, color: design.success),
            ],
          ),
          const Divider(height: AppDimensions.space24),
          totals.when(
            loading: () => const LoadingIndicator(),
            error: (e, _) => Text('$e'),
            data: (t) {
              final sums = t ?? const ShiftTotals(cash: 0, nonCash: 0, orderCount: 0);
              return Column(
                children: [
                  _row(context, l10n.shiftOpeningCash, shift.openingCash),
                  _row(context, l10n.shiftCashSales, sums.cash),
                  _row(context, l10n.shiftNonCashSales, sums.nonCash, muted: true),
                  const Divider(height: AppDimensions.space20),
                  _row(
                    context,
                    l10n.shiftExpectedCash,
                    shift.openingCash + sums.cash,
                    bold: true,
                  ),
                  const SizedBox(height: AppDimensions.space8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.shiftOrders,
                        style: TextStyle(
                          color: design.textMedium,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '${sums.orderCount}',
                        style: TextStyle(
                          color: design.textHigh,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppDimensions.space16),
          FilledButton.icon(
            onPressed: () => _openCloseSheet(context, ref, shift),
            icon: const Icon(Icons.lock_rounded),
            label: Text(l10n.shiftClose),
          ),
        ],
      ),
    );
  }

  void _openCloseSheet(BuildContext context, WidgetRef ref, Shift shift) {
    showGlassSheet<void>(
      context: context,
      builder: (_) => _CloseShiftSheet(shift: shift),
    );
  }
}

Widget _row(
  BuildContext context,
  String label,
  int value, {
  bool bold = false,
  bool muted = false,
}) {
  final design = context.design;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: muted ? design.textLow : design.textMedium,
            fontSize: 13,
          ),
        ),
        Text(
          MoneyFormatter.format(value),
          style: TextStyle(
            color: muted ? design.textMedium : design.textHigh,
            fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
            fontSize: bold ? 16 : 14,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}

class _CloseShiftSheet extends ConsumerStatefulWidget {
  const _CloseShiftSheet({required this.shift});
  final Shift shift;

  @override
  ConsumerState<_CloseShiftSheet> createState() => _CloseShiftSheetState();
}

class _CloseShiftSheetState extends ConsumerState<_CloseShiftSheet> {
  final _countedCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Rebuild as the cashier types so the variance updates live — seeing the
    // difference appear while counting is the whole value of this screen.
    _countedCtrl.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _countedCtrl.removeListener(_onChanged);
    _countedCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final totals = ref.watch(currentShiftTotalsProvider).valueOrNull;
    final expected =
        widget.shift.openingCash + (totals?.cash ?? 0);
    final counted = int.tryParse(_countedCtrl.text.trim());
    final variance = counted == null ? null : counted - expected;

    return Padding(
      padding: EdgeInsets.only(
        left: AppDimensions.space16,
        right: AppDimensions.space16,
        top: AppDimensions.space8,
        bottom:
            MediaQuery.of(context).viewInsets.bottom + AppDimensions.space16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                l10n.shiftClose,
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
          _row(context, l10n.shiftExpectedCash, expected, bold: true),
          const SizedBox(height: AppDimensions.space12),
          GlassTextField(
            controller: _countedCtrl,
            label: l10n.shiftCountedCash,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            prefixText: 'Rp ',
          ),
          if (variance != null) ...[
            const SizedBox(height: AppDimensions.space12),
            _VarianceBanner(variance: variance),
          ],
          const SizedBox(height: AppDimensions.space12),
          GlassTextField(controller: _noteCtrl, label: l10n.shiftNote),
          const SizedBox(height: AppDimensions.space16),
          FilledButton(
            // Requires an actual count: closing with a blank field would
            // record a variance equal to the whole drawer.
            onPressed: counted == null || _busy ? null : _confirmAndClose,
            child: Text(l10n.shiftClose),
          ),
        ],
      ),
    );
  }

  /// Re-confirms the signed-in cashier's own PIN before anything is saved.
  ///
  /// The count above is only a draft until this passes: a wrong PIN — or
  /// backing out of the prompt — leaves the session open and nothing written,
  /// exactly as if Close had never been tapped. Only a correct match falls
  /// through to [_close], which is what actually persists the counted cash
  /// and closes the session.
  Future<void> _confirmAndClose() async {
    final employeeId = ref.read(settingsProvider).valueOrNull?.employeeId ?? '';
    if (employeeId.isEmpty) return;
    setState(() => _busy = true);
    final confirmed = await requestSessionClosePin(
      context,
      employeeId: employeeId,
    );
    if (!mounted) return;
    if (confirmed == null) {
      // Wrong PIN or dismissed: the prompt itself already showed the error
      // for a wrong PIN, so there is nothing more to say here — just hand
      // control back so the cashier can retry Close or keep adjusting the
      // count.
      setState(() => _busy = false);
      return;
    }
    await _close();
  }

  Future<void> _close() async {
    final note = _noteCtrl.text.trim();
    final settings = ref.read(settingsProvider).valueOrNull;
    await ShiftRepository.instance.close(
      shift: widget.shift,
      countedCash: int.parse(_countedCtrl.text.trim()),
      // Whoever is on the till right now, which after a handover is not the
      // person who opened it. Recorded on every close, not only the ones where
      // it differs — a name that appears sometimes is a name nobody trusts.
      closedById: settings?.employeeId ?? '',
      closedByName: settings?.cashierName ?? '',
      note: note.isEmpty ? null : note,
    );
    // Order matters: the row has to be closed before the device forgets it, or
    // the resolver re-adopts the session as "my own open shift".
    await ref.read(settingsProvider.notifier).closePosSession();
    ref.invalidate(currentShiftProvider);
    ref.invalidate(shiftHistoryProvider);
    // The floor-wide drawer view is derived from the open shifts, so it goes
    // stale the moment one opens or closes. The picker too — the till this
    // session was holding is free again.
    ref.invalidate(openDrawersProvider);
    ref.invalidate(registerSlotsProvider);
    if (mounted) Navigator.of(context).pop();
  }
}

class _VarianceBanner extends StatelessWidget {
  const _VarianceBanner({required this.variance});
  final int variance;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final (label, fg, bg) = switch (variance) {
      0 => (l10n.shiftBalanced, design.success, design.successContainer),
      > 0 => (l10n.shiftOver, design.info, design.infoContainer),
      _ => (l10n.shiftShort, design.error, design.errorContainer),
    };

    return Container(
      padding: const EdgeInsets.all(AppDimensions.space12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppDimensions.radiusMd,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${l10n.shiftVariance} · $label',
            style: TextStyle(color: fg, fontWeight: FontWeight.w700),
          ),
          Text(
            MoneyFormatter.format(variance.abs()),
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w900,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShiftHistory extends ConsumerWidget {
  const _ShiftHistory();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final history = ref.watch(shiftHistoryProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.shiftHistory,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: design.textHigh,
          ),
        ),
        const SizedBox(height: AppDimensions.space10),
        history.when(
          loading: () => const LoadingIndicator(),
          error: (e, _) => Text('$e'),
          data: (list) {
            final closed = list.where((s) => !s.isOpen).toList();
            if (closed.isEmpty) {
              return GlassCard.solid(
                child: Text(
                  l10n.shiftHistoryEmpty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: design.textMedium),
                ),
              );
            }
            return Column(
              children: [
                for (final s in closed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppDimensions.space8),
                    child: _HistoryTile(shift: s),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.shift});
  final Shift shift;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    final l10n = context.l10n;
    final variance = shift.variance ?? 0;
    final fg = variance == 0
        ? design.success
        : variance > 0
        ? design.info
        : design.error;

    return GlassCard.solid(
      padding: const EdgeInsets.all(AppDimensions.space12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  [
                    shift.posName,
                    shift.employeeName,
                  ].whereType<String>().join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: design.textHigh,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  // Names the counter only when it was somebody other than
                  // the person who opened it — otherwise the line just repeats
                  // the name directly above it.
                  shift.closedByName != null &&
                          shift.closedByName != shift.employeeName
                      ? '${l10n.shiftClosedAt(DateFormat('d MMM, HH:mm').format(shift.closedAt!))}'
                            ' · ${l10n.shiftClosedBy(shift.closedByName!)}'
                      : l10n.shiftClosedAt(
                          DateFormat('d MMM, HH:mm').format(shift.closedAt!),
                        ),
                  maxLines: 2,
                  style: TextStyle(color: design.textMedium, fontSize: 12),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                MoneyFormatter.format(shift.countedCash ?? 0),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: design.textHigh,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                variance == 0
                    ? l10n.shiftBalanced
                    : '${variance > 0 ? '+' : '-'}${MoneyFormatter.format(variance.abs())}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
