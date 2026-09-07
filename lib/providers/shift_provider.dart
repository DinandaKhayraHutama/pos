import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/shift.dart';
import '../data/repositories/shift_repository.dart';
import 'outlet_provider.dart';
import 'settings_provider.dart';

/// The POS session this DEVICE is signed on to, or null when nobody has
/// opened one.
///
/// Keyed off the device's session id rather than the signed-in employee, which
/// is what makes a handover work: the cashier changes, the drawer does not.
/// The id itself is resolved in `SettingsNotifier` — including the "adopt my
/// own open session" fallback — so this only has to load the row.
final currentShiftProvider = FutureProvider.autoDispose<Shift?>((ref) async {
  final sessionId = ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.posSessionId ?? ''),
  );
  if (sessionId.isEmpty) return null;
  return ShiftRepository.instance.byId(sessionId);
});

/// Live totals for the open session. Null when none is open.
final currentShiftTotalsProvider = FutureProvider.autoDispose<ShiftTotals?>((
  ref,
) async {
  final shift = await ref.watch(currentShiftProvider.future);
  if (shift == null) return null;
  return ShiftRepository.instance.totalsFor(shift);
});

/// Every open till session with its expected drawer contents.
///
/// The manager's cash-drawer view, scoped to the branch the device is standing
/// in — like every other aggregate in the app, and for the same reason: a
/// supervisor in Bintaro counting Kemang's drawers is a number nobody can
/// reconcile.
///
/// Totals are fetched per shift rather than in one grouped query because
/// [ShiftRepository.totalsFor] already bounds each one by its own session —
/// reimplementing that as a join would be a second place for the attribution
/// rule to drift.
final openDrawersProvider =
    FutureProvider.autoDispose<List<({Shift shift, ShiftTotals totals})>>((
      ref,
    ) async {
      final outletId = ref.watch(activeOutletProvider).valueOrNull?.id;
      final shifts = await ShiftRepository.instance.openShifts(
        outletId: outletId,
      );
      return [
        for (final s in shifts)
          (shift: s, totals: await ShiftRepository.instance.totalsFor(s)),
      ];
    });

/// Closing history, newest first, for this branch.
final shiftHistoryProvider = FutureProvider.autoDispose<List<Shift>>((
  ref,
) async {
  final outletId = ref.watch(activeOutletProvider).valueOrNull?.id;
  return ShiftRepository.instance.recent(outletId: outletId);
});
