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
    required this.note,
    required this.thankYou,
    required this.orderTypes,
    required this.paymentMethods,
    required this.servedBy,
    required this.taxIncluded,
    required this.rounding,
    required this.manualPayment,
  });

  final String subtotal;
  final String discount;
  final String serviceCharge;
  final String tax;
  final String total;
  final String amountPaid;
  final String change;
  final String cashier;

  /// Label prefixed onto the order note when the order carries one, e.g.
  /// "Catatan: tanpa cabai".
  final String note;
  final String thankYou;
  final Map<OrderType, String> orderTypes;
  final Map<PaymentMethod, String> paymentMethods;
  final String servedBy;

  /// The tax already inside the item prices, printed for information only.
  final String taxIncluded;
  final String rounding;

  /// Suffixed onto a non-cash payment: the till recorded it, it did not take
  /// it, and the customer should know the difference.
  final String manualPayment;
}

/// Store identity printed in the receipt header.
class ReceiptStore {
  const ReceiptStore({
    required this.name,
    required this.address,
    required this.currency,
    this.branch,
    this.phone,
    this.header,
    this.footer,
    this.logo,
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
  final String? phone;
  final String? header;
  final String? footer;
  final pw.ImageProvider? logo;
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
          if (store.logo != null) ...[
            pw.Center(
              child: pw.Image(store.logo!, height: 42, fit: pw.BoxFit.contain),
            ),
            pw.SizedBox(height: 4),
          ],
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
          if (store.phone?.isNotEmpty == true) ...[
            pw.SizedBox(height: 2),
            pw.Center(
              child: pw.Text(
                store.phone!,
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          ],
          if (store.header?.isNotEmpty == true) ...[
            pw.SizedBox(height: 2),
            pw.Center(
              child: pw.Text(
                store.header!,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          ],
          _divider(),
          _line(order.number, _formatDateTime(order.createdAt)),
          _line(
            order.salesTypeName ??
                labels.orderTypes[order.type] ??
                order.type.wire,
            order.table?.tableName ?? order.customerName ?? '',
          ),
          _line(labels.cashier, order.cashierName),
          if (order.servedByName?.isNotEmpty == true)
            _line(labels.servedBy, order.servedByName!),
          if (order.note != null && order.note!.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              '${labels.note}: ${order.note}',
              style: const pw.TextStyle(fontSize: 8),
            ),
          ],
          _divider(),
          for (final item in order.items) ...[
            // displayName, not productName: a receipt that says "Kopi Susu"
            // for a Large the customer paid extra for is the one they bring
            // back to argue about.
            pw.Text(item.displayName, style: const pw.TextStyle(fontSize: 9)),
            if (item.note != null && item.note!.isNotEmpty)
              pw.Text(item.note!, style: const pw.TextStyle(fontSize: 8)),
            _line(
              '${item.quantity} x ${money(item.unitPrice)}',
              money(item.lineTotal),
            ),
            if (item.lineDiscount > 0)
              _line(
                item.lineDiscountName ?? labels.discount,
                '- ${money(item.lineDiscount)}',
              ),
            pw.SizedBox(height: 3),
          ],
          _divider(),
          _line(labels.subtotal, money(order.subtotal)),
          if (order.discount > 0)
            _line(
              // Names the promo when there was one. "Diskon" alone makes a
              // customer ask what the deduction was, and the cashier guess.
              (order.discountName ?? order.promoName)?.isNotEmpty == true
                  ? '${labels.discount} (${order.discountName ?? order.promoName})'
                  : labels.discount,
              '- ${money(order.discount)}',
            ),
          if (order.serviceChargeAmount > 0)
            _line(labels.serviceCharge, money(order.serviceChargeAmount)),
          // Only the tax ADDED to the bill sits in the column, so the rows above
          // the total add up to it. Tax already inside the prices is printed
          // below the total, for information — a customer summing the receipt
          // must not count it twice.
          if (order.tax - order.taxIncluded > 0)
            _line(
              _taxLabel(labels.tax, order),
              money(order.tax - order.taxIncluded),
            ),
          if (order.roundingAmount != 0)
            _line(labels.rounding, money(order.roundingAmount)),
          pw.SizedBox(height: 2),
          _line(labels.total, money(order.total), bold: true, fontSize: 11),
          if (order.taxIncluded > 0)
            _line(
              _taxLabel(labels.taxIncluded, order),
              money(order.taxIncluded),
            ),
          _divider(),
          _line(
            [
              order.paymentMethodName ??
                  labels.paymentMethods[order.paymentMethod] ??
                  order.paymentMethod.wire,
              if (order.paymentMethod != PaymentMethod.cash)
                labels.manualPayment,
            ].join(' '),
            money(order.amountPaid),
          ),
          if (order.paymentMethod == PaymentMethod.cash &&
              order.amountPaid > order.total)
            _line(labels.change, money(order.amountPaid - order.total)),
          _divider(),
          pw.Center(
            child: pw.Text(
              store.footer?.isNotEmpty == true
                  ? store.footer!
                  : labels.thankYou,
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

/// "PB1 10%" when every line of [order] was taxed at one known rate — only a
/// version 2 order records each line's rate. A bill mixing rates, or an
/// older one that never recorded them, prints the bare label rather than a
/// rate some of its lines were not charged.
String _taxLabel(String label, Order order) {
  final rates = {for (final item in order.items) item.taxRateBp};
  if (rates.length != 1) return label;
  final bp = rates.single;
  if (bp == null || bp <= 0) return label;
  final shown = bp % 100 == 0
      ? (bp ~/ 100).toString()
      : (bp / 100).toStringAsFixed(2);
  return '$label $shown%';
}

pw.Widget _divider() => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(vertical: 4),
  child: pw.Divider(height: 0, thickness: 0.5),
);

String _formatDateTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
}
