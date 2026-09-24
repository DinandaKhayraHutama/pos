import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:convert';

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
    note: l10n.posNote,
    thankYou: l10n.receiptThankYou,
    orderTypes: {
      OrderType.dineIn: l10n.posDineIn,
      OrderType.takeaway: l10n.posTakeaway,
      OrderType.delivery: l10n.posDelivery,
      OrderType.custom: order.salesTypeName ?? l10n.posSalesTypeCustom,
    },
    paymentMethods: {
      PaymentMethod.cash: l10n.posCash,
      PaymentMethod.qris: l10n.posQris,
      PaymentMethod.card: l10n.posCard,
      PaymentMethod.ewallet: l10n.posPaymentEwallet,
      PaymentMethod.transfer: l10n.posPaymentTransfer,
      PaymentMethod.other: l10n.posPaymentOther,
    },
    servedBy: l10n.receiptServedBy,
    taxIncluded: l10n.posTaxIncluded,
    rounding: l10n.posRounding,
    manualPayment: l10n.receiptManualPayment,
  );

  try {
    // A sale made since Fase 3 froze its receipt identity — store name,
    // address, phone, header, footer, logo — at the moment it was rung up, so
    // a reprint says what the original said even after the Backoffice changed
    // any of it, and an address the owner chose to hide stays hidden. An older
    // sale has no snapshot: its branch NAME comes off the order and the
    // ADDRESS is looked up live, as it always was.
    final snapshot = order.receiptSnapshot?.isNotEmpty == true
        ? jsonDecode(order.receiptSnapshot!) as Map<String, dynamic>
        : null;
    final String address;
    if (snapshot != null) {
      address = snapshot['address'] as String? ?? '';
    } else {
      final outletId = order.outletId;
      final outlet = outletId == null
          ? null
          : await OutletRepository.instance.byId(outletId);
      address = outlet?.address?.isNotEmpty == true
          ? outlet!.address!
          : settings.storeAddress;
    }

    final bytes = await buildReceiptPdf(
      order: order,
      store: ReceiptStore(
        name: snapshot?['store_name'] as String? ?? settings.storeName,
        branch: order.outletName,
        address: address,
        phone: snapshot?['phone'] as String?,
        currency: settings.currency,
        header: snapshot?['header'] as String?,
        footer: snapshot?['footer'] as String?,
        logo: await _logo(snapshot?['logo_url'] as String?),
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

/// The receipt logo, or null when there is none or it cannot be fetched.
/// A till printing offline must still print: a missing logo is cosmetic, a
/// receipt that fails to print over one is not.
Future<pw.ImageProvider?> _logo(String? url) async {
  if (url == null || url.isEmpty) return null;
  try {
    return await networkImage(url);
  } catch (_) {
    return null;
  }
}
