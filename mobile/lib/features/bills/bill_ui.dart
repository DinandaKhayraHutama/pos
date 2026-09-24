import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/localization/l10n.dart';
import '../../core/print/prebill_document.dart';
import '../../core/print/receipt_document.dart';
import '../../core/widgets/app_snack_bar.dart';
import '../../data/device/till_coordinator.dart';
import '../../data/models/bill.dart';
import '../../data/repositories/bill_repository.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/bill_provider.dart';
import '../../providers/cart_provider.dart';
import '../../providers/outlet_provider.dart';
import '../../providers/pricing_provider.dart';
import '../../providers/settings_provider.dart';

/// Shared pieces of the saved-bill screens (paritas F4).

/// What to tell the cashier when a bill action is refused. Every code the
/// repository or the server can answer has a sentence; anything else names
/// its code, so an unexpected refusal is reported rather than swallowed.
String billErrorText(AppLocalizations l10n, Object error) {
  final code = switch (error) {
    BillException(:final code) => code,
    TillOperationException(:final code) => code,
    _ => error.toString(),
  };
  return switch (code) {
    'bill_not_editable' ||
    'bill_not_found' ||
    'bill_closed' => l10n.billErrorNotEditable,
    'bill_other_session' || 'session_required' => l10n.billErrorOtherSession,
    'bill_needs_server' => l10n.billErrorNeedsServer,
    'sync_before_handoff' => l10n.billErrorSyncFirst,
    'bill_not_parked' || 'bill_not_owned' => l10n.billErrorNotParked,
    'table_busy' => l10n.billErrorTableBusy,
    'open_bills_remaining' => l10n.billErrorOpenBillsRemaining,
    'bill_line_decision_missing' => l10n.billErrorDecisionMissing,
    'network' ||
    'server_unavailable' ||
    'cashier_auth_required' => l10n.billErrorNetwork,
    _ => l10n.billErrorGeneric(code),
  };
}

String dispatchStatusLabel(AppLocalizations l10n, DispatchStatus status) =>
    switch (status) {
      DispatchStatus.queued => l10n.kitchenStatusQueued,
      DispatchStatus.preparing => l10n.kitchenStatusPreparing,
      DispatchStatus.ready => l10n.kitchenStatusReady,
      DispatchStatus.served => l10n.kitchenStatusServed,
      DispatchStatus.cancelled => l10n.kitchenStatusCancelled,
    };

/// The label of the button that moves [status] to its next step.
String? dispatchAdvanceLabel(AppLocalizations l10n, DispatchStatus status) =>
    switch (status) {
      DispatchStatus.queued => l10n.kitchenStart,
      DispatchStatus.preparing => l10n.kitchenMarkReady,
      DispatchStatus.ready => l10n.kitchenMarkServed,
      DispatchStatus.served || DispatchStatus.cancelled => null,
    };

/// Runs a bill action and says how it went: [success] on success, the
/// refusal otherwise. Returns whether it succeeded.
Future<bool> runBillAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  final l10n = context.l10n;
  try {
    await action();
    if (success != null && context.mounted) {
      showAppSnackBar(context, success, success: true);
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      showAppSnackBar(context, billErrorText(l10n, error), error: true);
    }
    return false;
  }
}

/// Saves the cart's bill and prints its pre-bill — marked BELUM LUNAS, with
/// the bill number and the revision it printed. Saving first means the paper
/// shows a revision the till actually holds; printing moves nothing.
Future<void> printCartPrebill(BuildContext context, WidgetRef ref) async {
  final l10n = context.l10n;
  final ok = await runBillAction(
    context,
    () => saveCartBill(read: ref.read, invalidate: ref.invalidate),
  );
  if (!ok || !context.mounted) return;
  final cart = ref.read(cartProvider);
  final bill = cart.bill;
  if (bill == null) return;
  final quote = ref.read(cartQuoteProvider);
  final settings = ref.read(settingsProvider).requireValue;
  final outlet = ref.read(activeOutletProvider).valueOrNull;
  final result = quote.result;
  final header = [
    if (cart.table?.name.isNotEmpty == true) cart.table!.name,
    if (cart.customerName?.isNotEmpty == true) cart.customerName!,
  ].join(' · ');
  final data = PrebillData(
    billNumber: bill.number,
    revision: bill.revision,
    printedAt: DateTime.now(),
    header: header,
    cashier: settings.cashierName,
    lines: [
      for (var i = 0; i < cart.lines.length; i++)
        PrebillLine(
          name: cart.lines[i].displayName,
          quantity: cart.lines[i].quantity,
          unitPrice: quote.lines[i].unitPrice,
          gross: quote.lines[i].result.gross,
          note: cart.lines[i].note,
          modifiers: cart.lines[i].modifiers
              .map((m) => m.option.name)
              .join(', '),
        ),
    ],
    subtotal: result.subtotal,
    discount: result.discount,
    discountName: cart.discountLabel,
    serviceCharge: result.serviceCharge,
    addedTax: quote.addedTax,
    taxIncluded: result.taxIncluded,
    rounding: result.rounding,
    total: result.total,
    note: cart.note,
  );
  try {
    final bytes = await buildPrebillPdf(
      data: data,
      store: ReceiptStore(
        name: settings.storeName,
        branch: outlet?.name,
        address: '',
        currency: settings.currency,
      ),
      labels: PrebillLabels(
        title: l10n.billPrebillTitle,
        unpaid: l10n.billPrebillUnpaid,
        revision: l10n.billPrebillRevision(bill.revision),
        estimate: l10n.billPrebillEstimate,
        subtotal: l10n.posSubtotal,
        discount: l10n.posDiscount,
        serviceCharge: l10n.posServiceCharge,
        tax: l10n.posTax,
        taxIncluded: l10n.posTaxIncluded,
        rounding: l10n.posRounding,
        total: l10n.posTotal,
        cashier: l10n.receiptCashier,
        note: l10n.posNote,
      ),
    );
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: '${bill.number} r${bill.revision}',
    );
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'nti_pos',
        context: ErrorDescription('while printing pre-bill ${bill.number}'),
      ),
    );
    if (context.mounted) {
      showAppSnackBar(context, l10n.ordersPrintFailed, error: true);
    }
  }
}
