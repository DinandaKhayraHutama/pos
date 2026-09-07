import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/outlet.dart';
import '../data/repositories/outlet_repository.dart';
import 'settings_provider.dart';

/// Every outlet the business has, closed ones included.
///
/// The manager screen needs the closed ones — that is where they are reopened
/// — so filtering to active happens at the call sites that sell.
final outletsProvider =
    AsyncNotifierProvider.autoDispose<OutletsNotifier, List<Outlet>>(
      OutletsNotifier.new,
    );

class OutletsNotifier extends AutoDisposeAsyncNotifier<List<Outlet>> {
  @override
  Future<List<Outlet>> build() => OutletRepository.instance.all();

  Future<void> save(Outlet outlet) async {
    await OutletRepository.instance.upsert(outlet);
    ref.invalidateSelf();
    // This device may be standing in the outlet that just got renamed or
    // closed, and everything downstream reads it from there.
    ref.invalidate(activeOutletProvider);
  }

  Future<void> remove(String id) async {
    await OutletRepository.instance.delete(id);
    ref.invalidateSelf();
    ref.invalidate(activeOutletProvider);
  }
}

/// The outlet THIS device is standing in.
///
/// Everything scoped by branch reads from here: stock, the floor plan, the
/// sales list, the reports. Resolution order, and each fallback is deliberate:
///
///   1. The device's own saved choice, if that outlet is still open. A closed
///      branch must stop being sellable-from, or closing one does nothing.
///   2. Otherwise the first open outlet. A device that has never been told
///      where it is should still take money — refusing to sell until someone
///      visits a settings screen is the worse failure on a Saturday night.
///   3. Null only when every outlet is closed. Callers write no outlet on the
///      order rather than inventing one.
final activeOutletProvider = FutureProvider.autoDispose<Outlet?>((ref) async {
  final chosen = ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.outletId ?? ''),
  );
  final repo = OutletRepository.instance;
  if (chosen.isNotEmpty) {
    final outlet = await repo.byId(chosen);
    if (outlet != null && outlet.active) return outlet;
  }
  return repo.firstActive();
});
