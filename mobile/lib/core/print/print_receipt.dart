import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../data/models/enums.dart';
import '../../data/models/order.dart';
import '../../data/repositories/outlet_repository.dart';
import '../../providers/settings_provider.dart';
import '../localization/l10n.dart';
import '../widgets/app_snack_bar.dart';
import 'receipt_document.dart';

/// Renders [order] as an 80mm receipt and opens the platform print dialog.
///
/// This replaces the placeholder that used to show a "Print receipt" snackbar
/// and do nothing — a button that lies is worse than no button, and this one
/// sat on the screen a sale ends on.
///
/// One implementation covers every platform: `printing` hands the PDF to the
/// OS print dialog on iOS / Android / macOS, and to the browser's print
/// preview on web. Thermal printers accept the same document because it is
/// laid out at [PdfPageFormat.roll80].
///
/// Returns true when the dialog was presented. A false result means the user
/// dismissed it, the browser fell back to downloading the PDF, or the attempt
/// failed — the last of which says so on screen.
///
/// **Failures are surfaced here, not swallowed.** Both call sites fire this and
/// ignore the result, so a throw used to reach nobody: for a while the web
/// plugin was not registered and every tap raised `MissingPluginException` into
/// the void, which looks exactly like a dead button. A print that cannot happen
/// has to admit it.
Future<bool> printOrderReceipt(
  BuildContext context,
  Order order,
  SettingsState settings,
) async {
  final l10n = context.l10n;
  final labels = ReceiptLabels(
    subtotal: l10n.posSubtotal,
    discount: l10n.posDiscount,
    serviceCharge: l10n.posServiceCharge,
    tax: l10n.posTax,
    total: l10n.posTotal,
    amountPaid: l10n.posAmountPaid,
    change: l10n.posChange,
    cashier: l10n.receiptCashier,
    thankYou: l10n.receiptThankYou,
    orderTypes: {
      OrderType.dineIn: l10n.posDineIn,
      OrderType.takeaway: l10n.posTakeaway,
      OrderType.delivery: l10n.posDelivery,
    },
    paymentMethods: {
      PaymentMethod.cash: l10n.posCash,
      PaymentMethod.qris: l10n.posQris,
      PaymentMethod.card: l10n.posCard,
    },
  );

  try {
    // The branch NAME comes off the order, because it is a snapshot of what
    // the shop was called when the sale happened. The ADDRESS is looked up
    // live: a branch that moved should print where it is now, since that is
    // where a customer holding this receipt would go back to.
    final outletId = order.outletId;
    final outlet = outletId == null
        ? null
        : await OutletRepository.instance.byId(outletId);

    final bytes = await buildReceiptPdf(
      order: order,
      store: ReceiptStore(
        name: settings.storeName,
        branch: order.outletName,
        address: outlet?.address?.isNotEmpty == true
            ? outlet!.address!
            : settings.storeAddress,
        currency: settings.currency,
      ),
      labels: labels,
    );

    return await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      // Shown as the suggested filename when the target is "Save as PDF",
      // which is what most web demos will pick.
      name: '${settings.storeName} ${order.number}',
    );
  } catch (error, stack) {
    // Logged as well as shown: the snackbar tells the cashier, the log tells
    // whoever has to work out why.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'nti_pos',
        context: ErrorDescription('while printing ${order.number}'),
      ),
    );
    if (context.mounted) {
      showAppSnackBar(context, l10n.ordersPrintFailed, error: true);
    }
    return false;
  }
}
