import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/permissions.dart';
import '../data/models/enums.dart';
import '../data/models/order.dart';
import '../data/models/table.dart';
import '../data/repositories/order_repository.dart';
import '../data/repositories/remote_order_repository.dart';
import '../data/device/till_coordinator.dart';
import '../data/repositories/table_repository.dart';
import 'cart_provider.dart';
import 'catalog_provider.dart';
import 'settings_provider.dart';
import 'shift_provider.dart';
import 'outlet_provider.dart';

/// Tracks the most recently created order so we can navigate to its receipt.
final lastPlacedOrderProvider = StateProvider<Order?>((ref) => null);

/// Orders list, optionally filtered by status.
final ordersProvider = AsyncNotifierProvider.autoDispose
    .family<OrdersNotifier, List<Order>, OrderStatus?>(OrdersNotifier.new);

class OrdersNotifier
    extends AutoDisposeFamilyAsyncNotifier<List<Order>, OrderStatus?> {
  @override
  Future<List<Order>> build(OrderStatus? arg) {
    // Watched, not read: signing a different person in has to re-scope the
    // list. Reading it once would leave a manager looking at the cashier's
    // day after a handover.
    final settings = ref.watch(settingsProvider).valueOrNull;
    // And moving the device to another branch has to re-scope it too — a
    // manager in Kemang reading Bintaro's orders would void the wrong sale.
    final outletId = ref.watch(activeOutletProvider).valueOrNull?.id;
    return _load(arg, settings, outletId);
  }

  /// Scopes the query to the signed-in role.
  ///
  /// A cashier sees their own sales for today; anyone with [viewAllOrders]
  /// sees the whole history. The rule is in the SQL, not in a UI filter — the
  /// point is that a cashier's device never loads a colleague's takings, not
  /// that it declines to draw them.
  Future<List<Order>> _load(
    OrderStatus? status,
    SettingsState? settings,
    String? outletId,
  ) async {
    final seesEverything = settings?.can(AppPermission.viewAllOrders) ?? true;
    if (TillCoordinator.current != null && settings != null) {
      // ONE page, for today. This provider feeds the dashboard's recent list
      // and the void/refund actions, both of which are about the current day;
      // paging the whole period belongs to orderHistoryProvider, which the
      // history screen uses. The old code looped until the server ran out of
      // pages, which on a busy month froze the app for minutes before showing
      // anything.
      final remote = await RemoteOrderRepository.page(
        settings.employeeId,
        RemoteOrderFilter.today(),
      );
      final now = DateTime.now();
      final local = await OrderRepository.instance.recent(
        status: status,
        cashierId: seesEverything ? null : settings.employeeId,
        since: seesEverything
            ? null
            : DateTime(now.year, now.month, now.day),
        outletId: outletId,
      );
      // Local wins on a shared id: a status this device changed is newer than
      // the server's copy of it, and a sale still in the outbox exists here
      // and nowhere else.
      final combined = {
        for (final order in remote.orders) order.id: order,
        for (final order in local) order.id: order,
      };
      return combined.values
          .where((o) => status == null || o.status == status)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    if (seesEverything) {
      return OrderRepository.instance.recent(
        status: status,
        outletId: outletId,
      );
    }
    final now = DateTime.now();
    return OrderRepository.instance.recent(
      status: status,
      cashierId: settings!.employeeId.isEmpty ? 'cashier' : settings.employeeId,
      since: DateTime(now.year, now.month, now.day),
      outletId: outletId,
    );
  }

  Future<void> refresh() async {
    final settings = ref.read(settingsProvider).valueOrNull;
    final outletId = ref.read(activeOutletProvider).valueOrNull?.id;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _load(arg, settings, outletId));
  }

  Future<void> setStatus(String id, OrderStatus status) async {
    await OrderRepository.instance.setStatus(id, status);
    await refresh();
  }

  /// Voids an order. [authorizedBy] is the name the PIN prompt resolved.
  Future<void> voidOrder({
    required String id,
    required String authorizedBy,
    required String authorizedById,
    required String reason,
  }) async {
    await OrderRepository.instance.voidOrder(
      orderId: id,
      authorizedBy: authorizedBy,
      authorizedById: authorizedById,
      reason: reason,
    );
    await refresh();
  }

  Future<void> refundOrder({
    required String id,
    required String authorizedBy,
    required String authorizedById,
    required String reason,
    int? amount,
  }) async {
    await OrderRepository.instance.refundOrder(
      orderId: id,
      authorizedBy: authorizedBy,
      authorizedById: authorizedById,
      reason: reason,
      amount: amount,
    );
    await refresh();
  }
}

/// Places a new order from the active cart.
final checkoutProvider = FutureProvider.autoDispose<CheckoutResult>((
  ref,
) async {
  // Never auto-run; we expose its function via [CheckoutController] below.
  throw UnimplementedError();
});

class CheckoutResult {
  final Order order;
  const CheckoutResult(this.order);
}

/// Helper invoked from the POS UI to finalize the cart.
///
/// Accepts [read] and [invalidate] function callbacks rather than a
/// `WidgetRef` so the same body runs in production (via `ref.read` /
/// `ref.invalidate` tear-offs) and in unit tests (via a `ProviderContainer`
/// without needing a widget tree). Both surfaces share identical signatures.
///
/// [paymentMethod] and [amountPaid] come from the checkout sheet. They used
/// to be hardcoded to cash and to the exact total, which meant the method the
/// cashier picked — and the change they had just counted out — were thrown
/// away: every order in the database read as cash, exact. The payment
/// breakdown on the sales report was measuring nothing.
Future<Order> placeOrderFromCart({
  required T Function<T>(ProviderListenable<T>) read,
  required void Function(ProviderOrFamily) invalidate,
  PaymentMethod paymentMethod = PaymentMethod.cash,
  int? amountPaid,
}) async {
  final cart = read(cartProvider);
  final settings = read(settingsProvider).requireValue;
  if (cart.isEmpty) throw StateError('Cart is empty');

  // A table can still be sitting in the cart if this till does not run table
  // service — the cart deliberately survives most things, including a handover
  // to a cashier standing at the takeaway counter. Writing it onto the sale
  // would seat a guest at a board nobody can open any more, and that table
  // would stay occupied forever, so the till's current setting wins over the
  // stale selection.
  final table = settings.tableServiceEnabled ? cart.table : null;
  final outlet = read(activeOutletProvider).valueOrNull;

  final pb1Rate = settings.pb1Rate;
  final serviceChargeRate = settings.serviceChargeEnabled
      ? settings.serviceChargeRate
      : 0.0;
  final serviceChargeAmount = cart.serviceChargeFor(serviceChargeRate);
  final pb1Amount = cart.pb1For(
    pb1Rate: pb1Rate,
    serviceChargeRate: serviceChargeRate,
  );
  final total = cart.totalFor(
    pb1Rate: pb1Rate,
    serviceChargeRate: serviceChargeRate,
  );

  final order = await OrderRepository.instance.create(
    type: cart.type,
    items: cart.lines
        .map(
          (l) => OrderItemDraft(
            productId: l.product.id,
            productName: l.product.name,
            variantName: l.variant?.name,
            // The variant delta is already in here. The line has to reprint
            // at what the customer paid, not at today's catalogue price.
            unitPrice: l.unitPrice,
            unitCost: l.product.cost,
            quantity: l.quantity,
            note: l.note,
            modifiers: l.modifiers
                .map(
                  (m) => (
                    groupName: m.group.name,
                    optionName: m.option.name,
                    priceDelta: m.option.priceDelta,
                  ),
                )
                .toList(),
          ),
        )
        .toList(),
    subtotal: cart.subtotal,
    discount: cart.discountAmount,
    tax: pb1Amount,
    serviceChargeAmount: serviceChargeAmount,
    pb1Rate: pb1Rate,
    serviceChargeRate: serviceChargeRate,
    total: total,
    amountPaid: amountPaid ?? total,
    paymentMethod: paymentMethod,
    promoName: cart.promo?.name ?? cart.discountAuthorizedBy,
    // Attributed to whoever is signed in. The fallback covers a session that
    // predates per-employee sign-in, where only the name was ever stored.
    cashierId: settings.employeeId.isEmpty ? 'cashier' : settings.employeeId,
    cashierName: settings.cashierName,
    // Which branch took the money. Null only when the business has defined
    // no outlet at all — the sale still goes through, because refusing to sell
    // over a missing bit of configuration is the worse failure.
    outletId: outlet?.id,
    outletName: outlet?.name,
    // Which till took it, and into which drawer. The session id is what lets
    // that drawer be reconciled later against exactly these sales — including
    // this one, if a handover happened mid-order and the name above is no
    // longer the person who opened the session.
    posId: settings.posRegisterId.isEmpty ? null : settings.posRegisterId,
    posName: settings.posRegisterName.isEmpty ? null : settings.posRegisterName,
    posSessionId: settings.posSessionId.isEmpty ? null : settings.posSessionId,
    tableId: table?.id,
    tableName: table?.name,
    customerName: cart.customerName,
    note: cart.note,
  );

  read(lastPlacedOrderProvider.notifier).state = order;
  read(cartProvider.notifier).clear();
  // Refresh orders list
  invalidate(ordersProvider);

  // Every placed order changes revenue / count / avg + top products, so
  // refresh the dashboard unconditionally.
  invalidate(dashboardSummaryProvider);
  invalidate(topProductsProvider);

  // A cash sale just changed what should be in the drawer. Without this the
  // shift screen keeps showing the pre-sale expectation, which is the one
  // number on it that has to be live — a cashier counts against it.
  invalidate(currentShiftTotalsProvider);
  invalidate(openDrawersProvider);

  // The sale drew down stock for every tracked line, so the catalogue the sell
  // screen is showing is now stale — without this the remaining-stock pill and
  // the sold-out overlay keep the pre-sale numbers until something else
  // happens to refresh them.
  invalidate(productsProvider);

  // The repository committed the assigned table's status with the receipt.
  if (cart.type == OrderType.dineIn && table != null) {
    invalidate(tablesProvider);
  }

  return order;
}

// Tables ---------------------------------------------------------------------

/// The floor board's list: every active table at the device's branch, plus
/// any inactive one still mid-service. See `TableRepository.operational`.
final tablesProvider =
    AsyncNotifierProvider.autoDispose<TablesNotifier, List<RestaurantTable>>(
      TablesNotifier.new,
    );

class TablesNotifier extends AutoDisposeAsyncNotifier<List<RestaurantTable>> {
  @override
  Future<List<RestaurantTable>> build() => TableRepository.instance.operational(
    // Watched, not read: moving the device to another branch has to redraw
    // the board, not leave the previous shop's covers on screen.
    ref.watch(activeOutletProvider).valueOrNull?.id ?? '',
  );

  Future<void> refresh() async {
    final outletId = ref.read(activeOutletProvider).valueOrNull?.id ?? '';
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => TableRepository.instance.operational(outletId),
    );
  }

  Future<void> setStatus(String id, TableStatus status) async {
    await TableRepository.instance.setStatus(
      id,
      status,
      employeeName: ref.read(settingsProvider).valueOrNull?.cashierName ?? '',
    );
    await refresh();
  }
}

/// Tables a cashier can actually pick for a NEW dine-in order — strictly
/// active ones, regardless of current status. Separate from [tablesProvider]
/// because the floor board and the "start an order" picker answer different
/// questions: the board asks what is happening on the floor, this asks what
/// is available to seat someone at right now.
final activeTablesProvider =
    AsyncNotifierProvider.autoDispose<
      ActiveTablesNotifier,
      List<RestaurantTable>
    >(ActiveTablesNotifier.new);

class ActiveTablesNotifier
    extends AutoDisposeAsyncNotifier<List<RestaurantTable>> {
  @override
  Future<List<RestaurantTable>> build() => TableRepository.instance.byOutlet(
    ref.watch(activeOutletProvider).valueOrNull?.id ?? '',
    onlyActive: true,
  );
}

/// Every table at one branch, inactive ones included — the management
/// screen's list. A family on the outlet for the same reason
/// `posRegistersProvider` is: the screen has to be able to look at a branch
/// the device is not standing in.
final tableManagementProvider = AsyncNotifierProvider.autoDispose
    .family<TableManagementNotifier, List<RestaurantTable>, String>(
      TableManagementNotifier.new,
    );

class TableManagementNotifier
    extends AutoDisposeFamilyAsyncNotifier<List<RestaurantTable>, String> {
  @override
  Future<List<RestaurantTable>> build(String arg) =>
      TableRepository.instance.byOutlet(arg);

  Future<void> save(RestaurantTable table) async {
    await TableRepository.instance.upsert(table);
    ref.invalidateSelf();
    // No global invalidation layer — the floor board and the order picker
    // both read a different, filtered view of the same rows, so a rename,
    // capacity change or (de)activation has to be pushed to them explicitly.
    ref.invalidate(tablesProvider);
    ref.invalidate(activeTablesProvider);
  }

  Future<void> remove(String id) async {
    await TableRepository.instance.delete(id);
    ref.invalidateSelf();
    ref.invalidate(tablesProvider);
    ref.invalidate(activeTablesProvider);
  }
}

// Dashboard ------------------------------------------------------------------
final dashboardSummaryProvider =
    FutureProvider.autoDispose<({int revenue, int count, int itemsSold})>((
      ref,
    ) async {
      return OrderRepository.instance.summaryForDay(
        DateTime.now(),
        outletId: ref.watch(activeOutletProvider).valueOrNull?.id,
      );
    });

final topProductsProvider =
    FutureProvider.autoDispose<
      List<({String name, String? iconKey, int qty, int revenue})>
    >((ref) async {
      return OrderRepository.instance.topProducts(
        daysBack: 7,
        outletId: ref.watch(activeOutletProvider).valueOrNull?.id,
      );
    });

// Single order detail --------------------------------------------------------
final orderDetailProvider = FutureProvider.autoDispose.family<Order?, String>((
  ref,
  id,
) async {
  final employee=ref.watch(settingsProvider).valueOrNull?.employeeId ?? '';
  return await OrderRepository.instance.byId(id) ?? await RemoteOrderRepository.byId(id,employee);
});
