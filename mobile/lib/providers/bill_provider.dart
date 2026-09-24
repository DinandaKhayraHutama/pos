import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/device/bill_coordinator.dart';
import '../data/device/till_binding.dart';
import '../data/device/till_coordinator.dart';
import '../data/models/bill.dart';
import '../data/models/enums.dart';
import '../data/models/table.dart';
import '../data/repositories/bill_repository.dart';
import 'cart_provider.dart';
import 'catalog_provider.dart';
import 'device_sync_provider.dart';
import 'order_provider.dart';
import 'outlet_provider.dart';
import 'pricing_provider.dart';
import 'settings_provider.dart';

/// Saved bills (paritas F4): what the till shows and the actions behind the
/// cart's Save / Send to kitchen / Pay buttons.
///
/// The repository enforces every rule; these functions only gather the cart,
/// the quote and who is signed in, and refresh what a write changed. There is
/// no global invalidation layer, so each action names what it touched.

/// Whether this till runs saved bills: always in the demo, and on an
/// activated till once its outlet was switched to them in the Backoffice —
/// only then does every till of the branch understand a bill.
final billsEnabledProvider = Provider.autoDispose<bool>((ref) {
  if (TillBinding.current == null) return true;
  return ref.watch(pricingContextProvider).valueOrNull?.billModelV1 ?? false;
});

/// Open bills this till knows at its outlet: its own, and the ones it parked.
final openBillsProvider = FutureProvider.autoDispose<List<Bill>>((ref) {
  final outletId = ref.watch(activeOutletProvider).valueOrNull?.id;
  return BillRepository.instance.openBills(outletId: outletId);
});

/// One batch the kitchen has not finished, with its bill and lines.
typedef KitchenTicket = ({
  KitchenDispatch dispatch,
  Bill bill,
  List<BillLine> lines,
});

/// The kitchen board: every unfinished batch, oldest first.
final kitchenBoardProvider = FutureProvider.autoDispose<List<KitchenTicket>>((
  ref,
) {
  final outletId = ref.watch(activeOutletProvider).valueOrNull?.id;
  return BillRepository.instance.activeDispatches(outletId: outletId);
});

/// Open seatings at the outlet, by table.
final tableSeatingsProvider =
    FutureProvider.autoDispose<Map<String, TableSeating>>((ref) async {
      final outletId = ref.watch(activeOutletProvider).valueOrNull?.id;
      final seatings = await BillRepository.instance.openSeatings(
        outletId: outletId,
      );
      return {for (final s in seatings) s.tableId: s};
    });

/// One open bill as the server's board lists it.
class RemoteBillSummary {
  const RemoteBillSummary({
    required this.id,
    required this.number,
    required this.ownedByThisDevice,
    required this.parked,
    this.ownerRegisterName,
    this.tableName,
    this.customerName,
    required this.subtotal,
    required this.lineCount,
    required this.openedAt,
    required this.activeDispatches,
  });

  final String id;
  final String number;
  final bool ownedByThisDevice;
  final bool parked;
  final String? ownerRegisterName;
  final String? tableName;
  final String? customerName;
  final int subtotal;
  final int lineCount;
  final DateTime openedAt;

  /// Batches still queued, being prepared or ready.
  final int activeDispatches;

  String get label => tableName?.isNotEmpty == true
      ? tableName!
      : customerName?.isNotEmpty == true
      ? customerName!
      : number;

  static RemoteBillSummary fromWire(Map<String, dynamic> m) {
    final dispatches = (m['dispatches'] as Map?) ?? const {};
    int count(String s) => (dispatches[s] as num?)?.toInt() ?? 0;
    return RemoteBillSummary(
      id: m['id'] as String,
      number: m['number'] as String? ?? '',
      ownedByThisDevice: m['owned_by_this_device'] == true,
      parked: m['parked'] == true,
      ownerRegisterName: m['owner_register_name'] as String?,
      tableName: m['table_name'] as String?,
      customerName: m['customer_name'] as String?,
      subtotal: (m['subtotal'] as num?)?.toInt() ?? 0,
      lineCount: (m['line_count'] as num?)?.toInt() ?? 0,
      openedAt: DateTime.fromMillisecondsSinceEpoch(
        (m['opened_at_ms'] as num?)?.toInt() ?? 0,
      ),
      activeDispatches: count('queued') + count('preparing') + count('ready'),
    );
  }
}

/// The outlet's open bills and seatings as the server holds them — every
/// till's, not only this one's.
class RemoteBillBoard {
  const RemoteBillBoard({
    required this.bills,
    required this.seatings,
    required this.fetchedAt,
    required this.fromCache,
  });

  final List<RemoteBillSummary> bills;
  final List<TableSeating> seatings;
  final DateTime fetchedAt;

  /// True when the server could not be reached and this is the last board
  /// fetched — shown with its age, never as live.
  final bool fromCache;

  static RemoteBillBoard of(
    Map<String, dynamic> board, {
    required DateTime fetchedAt,
    required bool fromCache,
    String? outletId,
  }) => RemoteBillBoard(
    bills: [
      for (final b in (board['bills'] as List? ?? const []))
        RemoteBillSummary.fromWire((b as Map).cast<String, dynamic>()),
    ],
    seatings: [
      for (final s in (board['table_sessions'] as List? ?? const []))
        TableSeating.fromWire(
          (s as Map).cast<String, dynamic>(),
          outletId: outletId,
        ),
    ],
    fetchedAt: fetchedAt,
    fromCache: fromCache,
  );
}

/// The server's board, on an activated till; null in the demo, where this
/// till's own list is the whole truth.
final billBoardProvider = FutureProvider.autoDispose<RemoteBillBoard?>((
  ref,
) async {
  final coordinator = BillCoordinator.current;
  final outletId = TillBinding.current?.outletId;
  if (coordinator == null || outletId == null) return null;
  final employee = ref.watch(settingsProvider).valueOrNull?.employeeId ?? '';
  try {
    final board = await coordinator.board(employee);
    return RemoteBillBoard.of(
      board,
      fetchedAt: DateTime.now(),
      fromCache: false,
      outletId: outletId,
    );
  } catch (_) {
    final cached = await BillRepository.instance.cachedBoard(outletId);
    if (cached == null) rethrow;
    return RemoteBillBoard.of(
      cached.board,
      fetchedAt: cached.fetchedAt,
      fromCache: true,
      outletId: outletId,
    );
  }
});

/// Everything a bill write can change on screen.
void invalidateBillViews(void Function(ProviderOrFamily) invalidate) {
  invalidate(openBillsProvider);
  invalidate(kitchenBoardProvider);
  invalidate(tableSeatingsProvider);
  invalidate(billBoardProvider);
  invalidate(tablesProvider);
  invalidate(activeTablesProvider);
  // A dispatch or a cancellation moved stock the sell screen shows.
  invalidate(productsProvider);
}

/// The cart as a bill draft, and the bill line id each cart line will have —
/// its own when it was saved before, a new one otherwise — so a receipt
/// written in the same transaction can name them.
({BillDraft draft, List<String> lineIds}) billDraftFromCart({
  required T Function<T>(ProviderListenable<T>) read,
}) {
  final cart = read(cartProvider);
  final settings = read(settingsProvider).requireValue;
  final outlet = read(activeOutletProvider).valueOrNull;
  final quote = read(cartQuoteProvider);
  const uuid = Uuid();
  final lineIds = [for (final line in cart.lines) line.billLineId ?? uuid.v4()];
  final table = settings.tableServiceEnabled ? cart.table : null;
  final pricing = BillPricing(
    version: quote.version,
    taxMode: quote.taxMode,
    serviceRateBp: quote.serviceRateBp,
    serviceTaxable: quote.serviceTaxable,
    roundingUnit: quote.roundingUnit,
    roundingMode: quote.roundingMode,
    defaultTaxRateBp: quote.defaultTaxRateBp,
    billDiscount: quote.billDiscount,
    discountSource: cart.discountSource.name,
    promoId: cart.discountSource == DiscountSource.promo
        ? cart.promo?.id
        : null,
    promoName: cart.discountSource == DiscountSource.promo
        ? cart.promo?.name
        : null,
    discountId: cart.discountSource == DiscountSource.named
        ? cart.namedDiscountId
        : null,
    discountName: cart.discountSource == DiscountSource.named
        ? cart.namedDiscountName
        : null,
    discountAuthorizedById: cart.discountAuthorizedById,
    discountAuthorizedByName: cart.discountAuthorizedBy,
  );
  final draft = BillDraft(
    billId: cart.bill?.id,
    type: cart.type.wire,
    salesTypeId: cart.salesTypeId ?? quote.salesType?.id,
    salesTypeName: cart.salesTypeName ?? quote.salesType?.name,
    tableId: table?.id,
    tableName: table?.name,
    tableSessionId: table == null ? null : cart.tableSessionId,
    customerId: cart.customerId,
    customerName: cart.customerName,
    servedById: cart.servedById,
    servedByName: cart.servedByName,
    note: cart.note,
    pricing: pricing,
    lines: [
      for (var i = 0; i < cart.lines.length; i++)
        if (!cart.lines[i].dispatched)
          _lineDraft(cart.lines[i], quote.lines[i], lineIds[i], quote.isV2),
    ],
    cashierId: settings.employeeId.isEmpty ? 'cashier' : settings.employeeId,
    cashierName: settings.cashierName,
    outletId: outlet?.id,
    posId: settings.posRegisterId.isEmpty ? null : settings.posRegisterId,
    posName: settings.posRegisterName.isEmpty ? null : settings.posRegisterName,
    posSessionId: settings.posSessionId.isEmpty ? null : settings.posSessionId,
  );
  return (draft: draft, lineIds: lineIds);
}

BillLineDraft _lineDraft(
  CartLine line,
  QuotedLine quoted,
  String id,
  bool v2,
) => BillLineDraft(
  id: id,
  productId: line.custom ? null : line.product.id,
  productName: line.product.name,
  variantId: line.variant?.id,
  variantName: line.variant?.name,
  modifiers: [
    for (final m in line.modifiers)
      BillLineModifier(
        groupId: m.group.id,
        groupName: m.group.name,
        optionId: m.option.id,
        optionName: m.option.name,
        priceDelta: m.option.priceDelta,
      ),
  ],
  unitPrice: quoted.unitPrice,
  basePrice: quoted.basePrice,
  priceSource: quoted.priceSource,
  taxRateBp: quoted.taxRateBp,
  unitCost: line.frozen?.unitCost ?? (line.custom ? null : line.product.cost),
  quantity: line.quantity,
  note: line.note,
  custom: line.custom,
  discount: v2 ? line.discount?.toJson() : null,
  lineDiscountId: v2 ? line.discountId : null,
  lineDiscountName: v2 ? line.discountName : null,
  lineDiscountAuthorizedById: v2 ? line.discountApprovedBy?.id : null,
  lineDiscountAuthorizedByName: v2 ? line.discountApprovedBy?.name : null,
);

/// Saves the cart as a bill — and, with [dispatch], sends its new lines to
/// the kitchen in the same transaction. The cart then shows the bill as it
/// was stored: saved lines at their frozen prices, sent lines locked.
Future<Bill> saveCartBill({
  required T Function<T>(ProviderListenable<T>) read,
  required void Function(ProviderOrFamily) invalidate,
  bool dispatch = false,
}) async {
  final (:draft, lineIds: _) = billDraftFromCart(read: read);
  final bill = dispatch
      ? await BillRepository.instance.saveAndDispatch(draft)
      : await BillRepository.instance.save(draft);
  read(cartProvider.notifier).loadBill(bill);
  invalidateBillViews(invalidate);
  read(deviceSyncControllerProvider)?.nudge();
  return bill;
}

/// Opens a bill of this till in the cart.
Future<void> openBillInCart({
  required T Function<T>(ProviderListenable<T>) read,
  required String billId,
}) async {
  final bill = await BillRepository.instance.byId(billId);
  if (bill == null || !bill.isEditable) {
    throw const BillException('bill_not_editable');
  }
  read(cartProvider.notifier).loadBill(bill);
}

/// Cancels the bill the cart holds, or [billId]. See
/// [BillRepository.cancel] for the restock/waste decision.
Future<void> cancelBill({
  required T Function<T>(ProviderListenable<T>) read,
  required void Function(ProviderOrFamily) invalidate,
  required String billId,
  required String reason,
  required String authorizedBy,
  String? authorizedById,
  required Map<String, bool> restock,
}) async {
  final settings = read(settingsProvider).requireValue;
  await BillRepository.instance.cancel(
    billId,
    reason: reason,
    authorizedBy: authorizedBy,
    authorizedById: authorizedById,
    restock: restock,
    employeeId: settings.employeeId,
    employeeName: settings.cashierName,
    sessionId: settings.posSessionId.isEmpty ? null : settings.posSessionId,
  );
  if (read(cartProvider).bill?.id == billId) {
    read(cartProvider.notifier).clear();
  }
  invalidateBillViews(invalidate);
  read(deviceSyncControllerProvider)?.nudge();
}

/// Parks a bill of this till on the server so another till — or this one,
/// after a shift change — can claim it. Pushes first: the server must hold
/// every revision and dispatch before it lets the bill go.
Future<void> parkBill({
  required T Function<T>(ProviderListenable<T>) read,
  required void Function(ProviderOrFamily) invalidate,
  required String billId,
}) async {
  final coordinator = BillCoordinator.current;
  if (coordinator == null) throw const BillException('bill_needs_server');
  if (await BillRepository.instance.hasUnsentChanges(billId)) {
    await read(deviceSyncControllerProvider)?.syncNow();
  }
  final settings = read(settingsProvider).requireValue;
  await coordinator.park(settings.employeeId, billId);
  if (read(cartProvider).bill?.id == billId) {
    read(cartProvider.notifier).clear();
  }
  invalidateBillViews(invalidate);
}

/// Claims a parked bill for this till's open drawer and opens it in the cart.
Future<Bill> claimBill({
  required T Function<T>(ProviderListenable<T>) read,
  required void Function(ProviderOrFamily) invalidate,
  required String billId,
}) async {
  final coordinator = BillCoordinator.current;
  if (coordinator == null) throw const BillException('bill_needs_server');
  final settings = read(settingsProvider).requireValue;
  if (!settings.hasPosSession) throw const BillException('bill_other_session');
  final bill = await coordinator.claim(
    settings.employeeId,
    billId,
    sessionId: settings.posSessionId,
  );
  read(cartProvider.notifier).loadBill(bill);
  invalidateBillViews(invalidate);
  return bill;
}

/// Seats [table] for a new bill — online on an activated till, so two tills
/// cannot seat it at once; locally in the demo — and puts it on the cart.
Future<TableSeating> seatTable({
  required T Function<T>(ProviderListenable<T>) read,
  required void Function(ProviderOrFamily) invalidate,
  required RestaurantTable table,
  int? guestCount,
}) async {
  final settings = read(settingsProvider).requireValue;
  final existing = await BillRepository.instance.openSeating(table.id);
  late final TableSeating seating;
  if (existing != null) {
    // Seated already — by this till or, as the board says, another: a new
    // bill joins the same visit.
    seating = existing;
  } else if (BillCoordinator.current case final coordinator?) {
    try {
      seating = await coordinator.seat(
        settings.employeeId,
        table.id,
        guestCount: guestCount,
      );
    } on TillOperationException catch (e) {
      if (e.code != 'table_busy') rethrow;
      // Another till seated these guests: a bill for them joins the same
      // visit. Reading the board mirrors its open seatings here.
      await coordinator.board(settings.employeeId);
      final joined = await BillRepository.instance.openSeating(table.id);
      if (joined == null) rethrow;
      seating = joined;
    }
  } else {
    seating = TableSeating(
      id: const Uuid().v4(),
      tableId: table.id,
      tableName: table.name,
      outletId: table.outletId,
      guestCount: guestCount,
      openedAt: DateTime.now(),
      openedByName: settings.cashierName,
    );
    await BillRepository.instance.recordSeating(seating);
  }
  read(cartProvider.notifier).seatAt(table, seating.id);
  invalidateBillViews(invalidate);
  return seating;
}

/// Clears a table once none of its bills is still open. Paying never does
/// this by itself: the guests may still be sitting there.
Future<void> clearTable({
  required T Function<T>(ProviderListenable<T>) read,
  required void Function(ProviderOrFamily) invalidate,
  required TableSeating seating,
}) async {
  final settings = read(settingsProvider).requireValue;
  if (BillCoordinator.current case final coordinator?) {
    await coordinator.clear(settings.employeeId, seating.id);
  } else {
    if (await BillRepository.instance.openBillsAtSeating(seating.id) > 0) {
      throw const BillException('open_bills_remaining');
    }
    await BillRepository.instance.recordSeating(
      TableSeating(
        id: seating.id,
        tableId: seating.tableId,
        tableName: seating.tableName,
        outletId: seating.outletId,
        guestCount: seating.guestCount,
        openedAt: seating.openedAt,
        openedByName: seating.openedByName,
        closedAt: DateTime.now(),
      ),
    );
  }
  invalidateBillViews(invalidate);
}
