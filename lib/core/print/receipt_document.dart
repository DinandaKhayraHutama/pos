import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/models/enums.dart';
import '../../data/models/order.dart';
import '../utils/formatters.dart';

/// Every piece of translated text the receipt needs.
///
/// The generator lives in `core/` and must not reach for a [BuildContext], so
/// callers resolve the strings from `context.l10n` and hand them over. Keeps
/// the document a pure function of (order, store, labels) — printable from a
/// background job or a test with no widget tree.
class ReceiptLabels {
  const ReceiptLabels({
    required this.subtotal,
    required this.discount,
    required this.serviceCharge,
    required this.tax,
    required this.total,
    required this.amountPaid,
    required this.change,
    required this.cashier,
    required this.thankYou,
    required this.orderTypes,
    required this.paymentMethods,
  });

  final String subtotal;
  final String discount;
  final String serviceCharge;
  final String tax;
  final String total;
  final String amountPaid;
  final String change;
  final String cashier;
  final String thankYou;
  final Map<OrderType, String> orderTypes;
  final Map<PaymentMethod, String> paymentMethods;
}

/// Store identity printed in the receipt header.
class ReceiptStore {
  const ReceiptStore({
    required this.name,
    required this.address,
    required this.currency,
    this.branch,
  });

  /// The business. Stays the same across every branch.
  final String name;

  /// Which branch sold this, or null for a single-shop business.
  ///
  /// A receipt that cannot say which shop it came from is useless for the
  /// things receipts are for — a return, a complaint, a reconciliation — and
  /// on a chain the customer has no other way to tell. Callers pass the name
  /// snapshotted on the order, not today's, so a branch that was renamed
  /// afterwards does not rewrite what an old receipt says.
  final String? branch;

  /// The branch's street address where there is one, the business's otherwise.
  final String address;

  final String currency;
}

/// Builds an 80mm thermal-roll receipt for [order].
///
/// [PdfPageFormat.roll80] is the standard receipt-printer width, so the same
/// document prints correctly on a thermal printer, saves as a PDF, or goes to
/// a desktop printer. On web it reaches the browser's print dialog, which is
/// how the app gets demoed — no printer driver in the loop.
///
/// KNOWN LIMITATION: this uses the PDF built-in Helvetica, which is Latin-1
/// only — the `pdf` package logs "Helvetica has no Unicode support" for every
/// document. Fine for Indonesian and any ASCII store or product name, wrong for
/// characters outside Latin-1. The fix is to embed the app's own Plus Jakarta
/// Sans via `pw.Font.ttf`, which also makes the receipt carry the brand
/// typeface; it is deliberately not done here because loading it needs
/// `rootBundle`, which would cost this function its independence from Flutter
/// and force a binding in the tests.
Future<Uint8List> buildReceiptPdf({
  required Order order,
  required ReceiptStore store,
  required ReceiptLabels labels,
}) async {
  final doc = pw.Document();
  String money(int v) => MoneyFormatter.format(v, symbol: store.currency);

  doc.addPage(
    pw.Page(
      // Margins are part of the roll format; overriding them risks clipping on
      // a real printer, so only the horizontal inset is tightened.
      pageFormat: PdfPageFormat.roll80.copyWith(
        marginLeft: 8,
        marginRight: 8,
        marginTop: 12,
        marginBottom: 12,
      ),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Center(
            child: pw.Text(
              store.name,
              style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
            ),
          ),
          if (store.branch != null && store.branch!.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Center(
              child: pw.Text(
                store.branch!,
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
          ],
          if (store.address.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Center(
              child: pw.Text(
                store.address,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          ],
          _divider(),
          _line(order.number, _formatDateTime(order.createdAt)),
          _line(
            labels.orderTypes[order.type] ?? order.type.wire,
            order.table?.tableName ?? order.customerName ?? '',
          ),
          _line(labels.cashier, order.cashierName),
          _divider(),
          for (final item in order.items) ...[
            // displayName, not productName: a receipt that says "Kopi Susu"
            // for a Large the customer paid extra for is the one they bring
            // back to argue about.
            pw.Text(item.displayName, style: const pw.TextStyle(fontSize: 9)),
            _line(
              '${item.quantity} x ${money(item.unitPrice)}',
              money(item.lineTotal),
            ),
            pw.SizedBox(height: 3),
          ],
          _divider(),
          _line(labels.subtotal, money(order.subtotal)),
          if (order.discount > 0)
            _line(
              // Names the promo when there was one. "Diskon" alone makes a
              // customer ask what the deduction was, and the cashier guess.
              order.promoName?.isNotEmpty == true
                  ? '${labels.discount} (${order.promoName})'
                  : labels.discount,
              '- ${money(order.discount)}',
            ),
          if (order.serviceChargeAmount > 0)
            _line(labels.serviceCharge, money(order.serviceChargeAmount)),
          if (order.tax > 0) _line(labels.tax, money(order.tax)),
          pw.SizedBox(height: 2),
          _line(labels.total, money(order.total), bold: true, fontSize: 11),
          _divider(),
          _line(
            labels.paymentMethods[order.paymentMethod] ??
                order.paymentMethod.wire,
            money(order.amountPaid),
          ),
          if (order.paymentMethod == PaymentMethod.cash &&
              order.amountPaid > order.total)
            _line(labels.change, money(order.amountPaid - order.total)),
          _divider(),
          pw.Center(
            child: pw.Text(
              labels.thankYou,
              style: const pw.TextStyle(fontSize: 9),
            ),
          ),
        ],
      ),
    ),
  );

  return doc.save();
}

pw.Widget _line(
  String left,
  String right, {
  bool bold = false,
  double fontSize = 9,
}) {
  final style = pw.TextStyle(
    fontSize: fontSize,
    fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
  );
  return pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(child: pw.Text(left, style: style)),
      pw.SizedBox(width: 6),
      pw.Text(right, style: style),
    ],
  );
}

pw.Widget _divider() => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(vertical: 4),
  child: pw.Divider(height: 0, thickness: 0.5),
);

String _formatDateTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
}
