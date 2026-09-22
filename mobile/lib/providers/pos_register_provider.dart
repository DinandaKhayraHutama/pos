import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/app_database.dart';
import '../data/device/till_binding.dart';
import '../data/device/till_coordinator.dart';
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
final posRegistersProvider = AsyncNotifierProvider.autoDispose
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
/// [session] is what the picker turns into its states: none means the till is
/// free, one belonging to the signed-in cashier means resume, and one
/// belonging to anybody else means taken — named, rather than merely disabled,
/// because "why can I not open this" is the question a greyed-out row leaves
/// unanswered.
///
/// [resumable] is the fourth state, and it exists because the first three were
/// a lie on a coordinated till: an open `shifts` row is not permission to sell
/// into it. When the server holds no confirmed claim for this device and
/// cashier — a session pushed through the legacy path, a force-closed drawer,
/// one handed to someone else — the drawer is the signed-in cashier's own and
/// still cannot be resumed here. The picker used to offer Resume anyway, and
/// the tap resolved straight back to "no session": nothing happened, nothing
/// was said, and there was no way off the screen.
typedef RegisterSlot = ({PosRegister register, Shift? session, bool resumable});

/// The tills a cashier can choose between right now.
///
/// Only the ACTIVE ones: a retired till is not somewhere anyone should be able
/// to sign on, and it is the management screen that brings one back.
///
/// On an activated device, only the register it is bound to. The server files
/// everything this device pushes under that register, so offering a sibling
/// till here would let a cashier record a drawer the server attributes
/// elsewhere. `ShiftRepository.open` refuses it too; this keeps the choice
/// from being offered at all.
final registerSlotsProvider = FutureProvider.autoDispose<List<RegisterSlot>>((
  ref,
) async {
  final outlet = ref.watch(activeOutletProvider).valueOrNull;
  if (outlet == null) return const [];
  final binding = TillBinding.current;
  // Narrowed with `select`: the permit answer depends on WHO is signed in and
  // nothing else, so a theme or locale change must not re-run these queries.
  final me = ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.employeeId ?? ''),
  );
  final registers = await PosRegisterRepository.instance.byOutlet(
    outlet.id,
    onlyActive: true,
  );
  final db = await AppDatabase.instance.db;
  final slots = <RegisterSlot>[];
  for (final r in registers) {
    if (binding != null && r.id != binding.registerId) continue;
    final session = await ShiftRepository.instance.openSessionForRegister(r.id);
    slots.add((
      register: r,
      session: session,
      // Asked of the same helper the resolver uses, so the tile cannot offer
      // an action that resolves back to nothing.
      resumable:
          session == null ||
          await TillCoordinator.holdsPermit(db, session.id, me),
    ));
  }
  return slots;
});
