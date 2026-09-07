import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/pos_register.dart';
import '../data/models/shift.dart';
import '../data/repositories/pos_register_repository.dart';
import '../data/repositories/shift_repository.dart';
import 'outlet_provider.dart';
import 'settings_provider.dart';

/// Every till at one branch, retired ones included.
///
/// A family on the outlet rather than a single list, for the same reason the
/// floor plan is: there is no useful "all branches" set of tills, and the
/// management screen has to be able to look at a branch the device is not
/// standing in. Closed tills are included because that screen is where they
/// are reopened.
final posRegistersProvider =
    AsyncNotifierProvider.autoDispose
        .family<PosRegistersNotifier, List<PosRegister>, String>(
          PosRegistersNotifier.new,
        );

class PosRegistersNotifier
    extends AutoDisposeFamilyAsyncNotifier<List<PosRegister>, String> {
  @override
  Future<List<PosRegister>> build(String arg) =>
      PosRegisterRepository.instance.byOutlet(arg);

  Future<void> save(PosRegister register) async {
    await PosRegisterRepository.instance.upsert(register);
    ref.invalidateSelf();
    // Editing a till can change whether this device seats guests at tables —
    // it is the till's setting now — so the resolved POS context goes stale
    // the moment one is saved. There is no global invalidation layer here;
    // this is the explicit call.
    await ref.read(settingsProvider.notifier).refreshPosContext();
    ref.invalidate(registerSlotsProvider);
  }

  Future<void> remove(String id) async {
    await PosRegisterRepository.instance.delete(id);
    ref.invalidateSelf();
    await ref.read(settingsProvider.notifier).refreshPosContext();
    ref.invalidate(registerSlotsProvider);
  }
}

/// A till at the active branch, with whoever is currently signed on to it.
///
/// [session] is what the picker turns into its three states: none means the
/// till is free, one belonging to the signed-in cashier means resume, and one
/// belonging to anybody else means taken — named, rather than merely disabled,
/// because "why can I not open this" is the question a greyed-out row leaves
/// unanswered.
typedef RegisterSlot = ({PosRegister register, Shift? session});

/// The tills a cashier can choose between right now.
///
/// Only the ACTIVE ones: a retired till is not somewhere anyone should be able
/// to sign on, and it is the management screen that brings one back.
final registerSlotsProvider = FutureProvider.autoDispose<List<RegisterSlot>>((
  ref,
) async {
  final outlet = ref.watch(activeOutletProvider).valueOrNull;
  if (outlet == null) return const [];
  final registers = await PosRegisterRepository.instance.byOutlet(
    outlet.id,
    onlyActive: true,
  );
  return [
    for (final r in registers)
      (
        register: r,
        session: await ShiftRepository.instance.openSessionForRegister(r.id),
      ),
  ];
});
