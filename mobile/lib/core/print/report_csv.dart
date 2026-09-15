import '../../data/models/sales_report.dart';

/// Renders a [SalesReport] as CSV for a spreadsheet.
///
/// Deliberately plain text rather than a PDF: the point of exporting a report
/// is that someone wants to do arithmetic on it, and a PDF would have to be
/// retyped. Excel-friendly by default — see the separator note below.
///
/// [labelFor] maps a bucket key (an enum `wire` value) to a display label, so
/// this stays free of localisation.
String buildReportCsv(
  SalesReport report, {
  required String Function(String key) paymentLabel,
  required String Function(String key) orderTypeLabel,
  required String uncategorizedLabel,
  required List<String> headers,
}) {
  final b = StringBuffer();

  // Excel picks the delimiter from this line when opening a .csv directly.
  // Without it, a locale that uses ',' as the decimal separator (Indonesian
  // included) splits every row on the wrong character and the file opens as
  // one column of garbage.
  b.writeln('sep=,');

  void row(List<Object?> cells) {
    b.writeln(cells.map(_escape).join(','));
  }

  row([headers[0], _date(report.from), _date(report.to)]);
  b.writeln();

  row([headers[1], headers[2]]);
  row(['Revenue', report.revenue]);
  row(['Subtotal', report.subtotal]);
  row(['Discount', report.discount]);
  row(['Service Charge', report.serviceCharge]);
  row(['PB1', report.tax]);
  row(['Orders', report.orderCount]);
  row(['Items sold', report.itemsSold]);
  row(['Average order', report.averageOrder]);
  row(['Cancelled orders', report.cancelledCount]);
  row(['Cancelled value', report.cancelledValue]);
  row(['Refunded orders', report.refundedCount]);
  row(['Refunded value', report.refundedValue]);
  row(['Cost of goods', report.costOfGoods]);
  row(['Gross profit', report.grossProfit]);
  // Exported alongside the profit, not just shown on screen: a spreadsheet
  // that carries the figure without the caveat is a figure someone will
  // quote in a meeting.
  row(['Gross margin %', report.grossMarginPercent.toStringAsFixed(1)]);
  row(['Cost coverage %', (report.costCoverage * 100).round()]);
  b.writeln();

  row([headers[3], headers[4], headers[2]]);
  for (final e in report.byPaymentMethod.entries) {
    row([paymentLabel(e.key), e.value.count, e.value.amount]);
  }
  b.writeln();

  row([headers[5], headers[4], headers[2]]);
  for (final e in report.byOrderType.entries) {
    row([orderTypeLabel(e.key), e.value.count, e.value.amount]);
  }
  b.writeln();

  // Pre-tax, same as the on-screen section: netSales summed across every
  // row here reconciles to Subtotal minus Discount, not to report.revenue.
  row([headers[8], headers[9], headers[10], headers[11], headers[12]]);
  for (final c in report.byCategory) {
    row([
      c.categoryName.isEmpty ? uncategorizedLabel : c.categoryName,
      c.itemsSold,
      c.grossSales,
      c.netSales,
      c.contributionPercent.toStringAsFixed(1),
    ]);
  }
  b.writeln();

  row([headers[6], headers[4], headers[2]]);
  for (final e in report.byCashier.entries) {
    row([e.key, e.value.count, e.value.amount]);
  }
  b.writeln();

  row([headers[7], headers[2]]);
  final days = report.perDay.keys.toList()..sort();
  for (final d in days) {
    row([_date(d), report.perDay[d]]);
  }

  return b.toString();
}

String _date(DateTime d) =>
    '${d.year}-${_two(d.month)}-${_two(d.day)}';

String _two(int v) => v.toString().padLeft(2, '0');

/// Quotes a cell only when it needs it, and doubles any embedded quote — a
/// store or product name containing a comma would otherwise shift every
/// following column by one.
String _escape(Object? value) {
  final s = '$value';
  if (!s.contains(',') && !s.contains('"') && !s.contains('\n')) return s;
  return '"${s.replaceAll('"', '""')}"';
}
