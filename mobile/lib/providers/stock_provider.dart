import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/stock_movement.dart';
import '../data/repositories/stock_repository.dart';
import 'outlet_provider.dart';

/// The stock ledger for the branch this device is standing in. Pass a product
/// id for one product's history, or null for the whole shop.
///
/// Scoped to the outlet on purpose: a running balance that mixes two branches'
/// deliveries stops matching either shelf, which makes the ledger useless for
/// the one job it has.
final stockHistoryProvider = FutureProvider.autoDispose
    .family<List<StockMovement>, String?>((ref, productId) {
      final outletId = ref.watch(activeOutletProvider).valueOrNull?.id ?? '';
      return StockRepository.instance.history(
        outletId: outletId,
        productId: productId,
      );
    });
