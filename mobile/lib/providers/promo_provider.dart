import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/promo.dart';
import '../data/repositories/promo_repository.dart';
import 'outlet_provider.dart';

/// Every promo, retired ones included — the management screen needs them to
/// bring one back.
final promosProvider =
    AsyncNotifierProvider.autoDispose<PromosNotifier, List<Promo>>(
      PromosNotifier.new,
    );

class PromosNotifier extends AutoDisposeAsyncNotifier<List<Promo>> {
  @override
  Future<List<Promo>> build() => PromoRepository.instance.all();

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(PromoRepository.instance.all);
  }

  Future<void> upsert(Promo promo) async {
    await PromoRepository.instance.upsert(promo);
    await refresh();
  }

  Future<void> delete(String id) async {
    await PromoRepository.instance.delete(id);
    await refresh();
  }
}

/// Only the promos a cashier may actually pick at the till: active, and live
/// at the branch this device stands in. A promo the owner narrowed to other
/// branches is not this till's to offer.
final activePromosProvider = FutureProvider.autoDispose<List<Promo>>((
  ref,
) async {
  final outlet = await ref.watch(activeOutletProvider.future);
  if (outlet == null) return [];
  return PromoRepository.instance.all(onlyActive: true, outletId: outlet.id);
});
