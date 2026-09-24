import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../utils/formatters.dart';
import 'receipt_document.dart';

/// Labels for a pre-bill, resolved from the app's localizations by the caller
/// so this builder stays free of Flutter.
class PrebillLabels {
  const PrebillLabels({
    required this.title,
    required this.unpaid,
    required this.revision,
    required this.estimate,
    required this.subtotal,
    required this.discount,
    required this.serviceCharge,
    required this.tax,
    required this.taxIncluded,
    required this.rounding,
    required this.total,
    required this.cashier,
    required this.note,
  });

  final String title;

  /// "BELUM LUNAS" — printed large, so nobody mistakes this for a receipt.
  final String unpaid;

  /// "Revisi 3".
  final String revision;
  final String estimate;
  final String subtotal;
  final String discount;
  final String serviceCharge;
  final String tax;
  final String taxIncluded;
  final String rounding;
  final String total;
  final String cashier;
  final String note;
}

class PrebillLine {
  const PrebillLine({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.gross,
    this.note,
    this.modifiers,
  });

  final String name;
  final int quantity;
  final int unitPrice;
  final int gross;
  final String? note;
  final String? modifiers;
}

/// What a pre-bill shows: one saved revision of a bill, priced exactly as the
/// cart quotes it.
class PrebillData {
  const PrebillData({
    required this.billNumber,
    required this.revision,
    required this.printedAt,
    required this.header,
    required this.cashier,
    required this.lines,
    required this.subtotal,
    required this.discount,
    required this.serviceCharge,
    required this.addedTax,
    required this.taxIncluded,
    required this.rounding,
    required this.total,
    this.discountName,
    this.note,
  });

  final String billNumber;
  final int revision;
  final DateTime printedAt;

  /// Table and/or customer — whatever names the bill on the floor.
  final String header;
  final String cashier;
  final List<PrebillLine> lines;
  final int subtotal;
  final int discount;
  final String? discountName;
  final int serviceCharge;
  final int addedTax;
  final int taxIncluded;
  final int rounding;
  final int total;
  final String? note;
}

/// A pre-bill (paritas F4): the bill as it stands, for the guest to check
/// before paying. It is NOT a receipt and must never read like one — it says
/// BELUM LUNAS in its title and across its total, carries the bill number and
/// the revision it printed, and no payment, change or receipt number. Printing
/// it again moves nothing: it is built from what is on screen, not from a
/// write.
Future<Uint8List> buildPrebillPdf({
  required PrebillData data,
  required ReceiptStore store,
  required PrebillLabels labels,
}) async {
  final doc = pw.Document();
  String money(int v) => MoneyFormatter.format(v, symbol: store.currency);
  String two(int v) => v.toString().padLeft(2, '0');
  final at = data.printedAt;
  final printed =
      '${two(at.day)}/${two(at.month)}/${at.year} ${two(at.hour)}:${two(at.minute)}';

  pw.Widget line(
    String left,
    String right, {
    bool bold = false,
    double size = 9,
  }) {
    final style = pw.TextStyle(
      fontSize: size,
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

  pw.Widget divider() => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 4),
    child: pw.Divider(height: 0, thickness: 0.5),
  );

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.roll80.copyWith(
        marginLeft: 8,
        marginRight: 8,
        marginTop: 12,
        marginBottom: 12,
      ),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Center(
            child: pw.Text(
              store.name,
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
          ),
          if (store.branch?.isNotEmpty == true)
            pw.Center(
              child: pw.Text(
                store.branch!,
                style: const pw.TextStyle(fontSize: 9),
              ),
            ),
          pw.SizedBox(height: 6),
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(vertical: 4),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 1)),
            child: pw.Column(
              children: [
                pw.Text(
                  labels.title,
                  style: pw.TextStyle(
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.Text(
                  labels.unpaid,
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 4),
          line(data.billNumber, labels.revision),
          line(printed, data.header),
          line(labels.cashier, data.cashier),
          if (data.note?.isNotEmpty == true)
            pw.Text(
              '${labels.note}: ${data.note}',
              style: const pw.TextStyle(fontSize: 8),
            ),
          divider(),
          for (final l in data.lines) ...[
            pw.Text(l.name, style: const pw.TextStyle(fontSize: 9)),
            if (l.modifiers?.isNotEmpty == true)
              pw.Text(l.modifiers!, style: const pw.TextStyle(fontSize: 8)),
            if (l.note?.isNotEmpty == true)
              pw.Text(l.note!, style: const pw.TextStyle(fontSize: 8)),
            line('${l.quantity} x ${money(l.unitPrice)}', money(l.gross)),
            pw.SizedBox(height: 3),
          ],
          divider(),
          line(labels.subtotal, money(data.subtotal)),
          if (data.discount > 0)
            line(
              data.discountName?.isNotEmpty == true
                  ? '${labels.discount} (${data.discountName})'
                  : labels.discount,
              '- ${money(data.discount)}',
            ),
          if (data.serviceCharge > 0)
            line(labels.serviceCharge, money(data.serviceCharge)),
          if (data.addedTax > 0) line(labels.tax, money(data.addedTax)),
          if (data.rounding != 0) line(labels.rounding, money(data.rounding)),
          pw.SizedBox(height: 2),
          line(
            '${labels.total} (${labels.unpaid})',
            money(data.total),
            bold: true,
            size: 11,
          ),
          if (data.taxIncluded > 0)
            line(labels.taxIncluded, money(data.taxIncluded)),
          divider(),
          pw.Center(
            child: pw.Text(
              labels.estimate,
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 8),
            ),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}
