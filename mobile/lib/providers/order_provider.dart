import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' show DatabaseExecutor;

import '../core/auth/permissions.dart';
import '../core/pricing/pricing.dart';
import '../data/models/enums.dart';
import '../data/models/order.dart';
import '../data/models/table.dart';
import '../data/repositories/order_repository.dart';
import '../data/repositories/remote_order_repository.dart';
import '../data/device/till_coordinator.dart';
import '../data/repositories/sales_config_repository.dart';
import '../data/repositories/table_repository.dart';
import '../data/repositories/bill_repository.dart';
import 'bill_provider.dart';
import 'device_sync_provider.dart';
import 'cart_provider.dart';
import 'catalog_provider.dart';
import 'settings_provider.dart';
import 'shift_provider.dart';
import 'outlet_provider.dart';
import 'pricing_provider.dart';
import 'report_provider.dart';

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
        since: seesEverything ? null : DateTime(now.year, now.month, now.day),
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
  String? paymentMethodId,
  String? paymentMethodName,
  String? paymentReference,
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
  // One quote, read here and nowhere else: the figures on the screen the
  // cashier confirmed, the ones recorded, and the ones sent to the server
  // are the same object, so they cannot disagree.
  final context =
      read(pricingContextProvider).valueOrNull ?? PricingContext.empty;
  final quote = read(cartQuoteProvider);
  final result = quote.result;
  final approver = cart.discountAuthorizedBy;

  Future<Order> write({
    DatabaseExecutor? within,
    String? billId,
    List<String>? lineIds,
  }) => OrderRepository.instance.create(
    within: within,
    billId: billId,
    type: cart.type,
    items: [
      for (var i = 0; i < cart.lines.length; i++)
        _draftFor(
          cart.lines[i],
          quote.lines[i],
          quote.isV2,
          billLineId: lineIds?[i],
        ),
    ],
    subtotal: result.subtotal,
    discount: result.discount,
    tax: result.tax,
    serviceChargeAmount: result.serviceCharge,
    // The rates snapshot, in the percent the columns have always held.
    pb1Rate: quote.defaultTaxRateBp / 100,
    serviceChargeRate: quote.serviceRateBp / 100,
    total: result.total,
    amountPaid: amountPaid ?? result.total,
    paymentMethod: paymentMethod,
    paymentMethodId: paymentMethodId,
    paymentMethodName: paymentMethodName,
    paymentReference: paymentReference,
    // A promo's name, and only a promo's. The approver of a manual discount
    // used to be written here and printed as "Diskon (<manager>)" — a name
    // is an audit fact, not what the discount was.
    promoName: cart.discountSource == DiscountSource.promo
        ? cart.promo?.name
        : null,
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
    customerId: cart.customerId,
    note: cart.note,
    // A legacy order carries none of the version 2 terms: the server refuses
    // a version 1 receipt that brings a snapshot, included tax or rounding.
    pricingVersion: quote.isV2 ? pricingVersionV2 : null,
    pricing: quote.pricingSnapshot,
    taxIncluded: quote.isV2 ? result.taxIncluded : 0,
    roundingAmount: quote.isV2 ? result.rounding : 0,
    timezoneOffsetMinutes: merchantOffsetMinutes(),
    salesTypeId: quote.salesType?.id,
    salesTypeName: quote.salesType?.name,
    servedById: cart.servedById,
    servedByName: cart.servedByName,
    discountId: cart.discountSource == DiscountSource.named
        ? cart.namedDiscountId
        : null,
    discountName: switch (cart.discountSource) {
      DiscountSource.named => cart.namedDiscountName,
      DiscountSource.promo => cart.promo?.name,
      _ => null,
    },
    discountAuthorizedById: cart.discountAuthorizedById,
    discountAuthorizedByName: approver,
    receiptHeader: context.config?.receiptHeader,
    receiptFooter: context.config?.receiptFooter,
    receiptLogoUrl: context.config?.receiptLogoUrl,
    receiptStoreName: settings.storeName,
    receiptAddress: context.config?.showAddress == false
        ? null
        : (outlet?.address?.isNotEmpty == true
              ? outlet!.address
              : settings.storeAddress),
    // The outlet's phone comes with the device binding; a standalone till
    // has none to print.
    receiptPhone: context.config?.showPhone == true
        ? TillCoordinator.current?.binding.outlet['phone'] as String?
        : null,
  );

  // Paritas F4: where saved bills run, every sale is a bill — a direct sale
  // included. One transaction saves it, sends whatever the kitchen does not
  // have yet (consuming that stock, once), writes the receipt naming each
  // bill line, and closes the bill. The receipt itself consumes nothing.
  final Order order;
  if (read(billsEnabledProvider)) {
    final (:draft, :lineIds) = billDraftFromCart(read: read);
    order = await BillRepository.instance.settle(
      draft,
      writeReceipt: (txn, bill) =>
          write(within: txn, billId: bill.id, lineIds: lineIds),
    );
    invalidateBillViews(invalidate);
    read(deviceSyncControllerProvider)?.nudge();
  } else {
    order = await write();
  }

  read(lastPlacedOrderProvider.notifier).state = order;
  read(cartProvider.notifier).clear();
  // Refresh orders list
  invalidate(ordersProvider);

  // Every placed order changes revenue / count / avg + top products, so
  // refresh the dashboard unconditionally.
  invalidate(dashboardSummaryProvider);
  invalidate(dashboardReportProvider);
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

/// The line as the order stores it. A version 2 line carries its whole
/// breakdown so reports and F5 split/refund read the same shares the receipt
/// printed; a legacy line carries none — its floored shares never added up
/// to the header, and nothing downstream may treat them as if they did.
OrderItemDraft _draftFor(
  CartLine line,
  QuotedLine quoted,
  bool v2, {
  String? billLineId,
}) => OrderItemDraft(
  billLineId: billLineId,
  productId: line.product.id,
  productName: line.product.name,
  variantName: line.variant?.name,
  // The variant and modifier deltas are already in here. The line has to
  // reprint at what the customer paid, not at today's catalogue price.
  unitPrice: quoted.unitPrice,
  // A saved bill's line keeps the cost it was frozen with.
  unitCost: line.frozen?.unitCost ?? (line.custom ? null : line.product.cost),
  quantity: line.quantity,
  note: line.note,
  custom: line.custom,
  modifiers: line.modifiers
      .map(
        (m) => (
          groupName: m.group.name,
          optionName: m.option.name,
          priceDelta: m.option.priceDelta,
        ),
      )
      .toList(),
  basePrice: v2 ? quoted.basePrice : null,
  priceSource: v2 ? quoted.priceSource : null,
  taxRateBp: v2 ? quoted.taxRateBp : null,
  discountSpec: v2 ? quoted.discount?.toJson() : null,
  lineDiscountId: v2 ? line.discountId : null,
  lineDiscountName: v2 ? line.discountName : null,
  lineDiscountAuthorizedById: v2 ? line.discountApprovedBy?.id : null,
  lineDiscountAuthorizedByName: v2 ? line.discountApprovedBy?.name : null,
  lineDiscount: v2 ? quoted.result.lineDiscount : 0,
  billDiscountShare: v2 ? quoted.result.billDiscountShare : 0,
  serviceShare: v2 ? quoted.result.serviceShare : 0,
  taxAmount: v2 ? quoted.result.taxAmount : 0,
  taxIncluded: v2 ? quoted.result.taxIncluded : 0,
  netAmount: v2 ? quoted.result.netAmount : null,
);

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
  final employee = ref.watch(settingsProvider).valueOrNull?.employeeId ?? '';
  return await OrderRepository.instance.byId(id) ??
      await RemoteOrderRepository.byId(id, employee);
});
