import '../../data/models/sales_report.dart';

/// Renders a [SalesReport] as CSV for a spreadsheet.
///
/// Deliberately plain text rather than a PDF: the point of exporting a report
/// is that someone wants to do arithmetic on it, and a PDF would have to be
/// retyped. Excel-friendly by default — see the separator note below.
///
/// [labelFor] maps a bucket key (an enum `wire` value) to a display label, so
/// this stays free of localisation.
/// [scope] says WHAT these figures cover — one outlet's server totals, or this
/// device's own transactions — and [computedAt] when they were produced. A
/// spreadsheet outlives the screen it came from, and a column of rupiah with
/// no scope on it is a column somebody will misread next quarter.
String buildReportCsv(
  SalesReport report, {
  required String Function(String key) paymentLabel,
  required String Function(String key) orderTypeLabel,
  required String uncategorizedLabel,
  required List<String> headers,
  String scope = '',
  String computedAt = '',
  int calculationVersion = 2,
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
  if (scope.isNotEmpty) row(['Scope', scope]);
  if (computedAt.isNotEmpty) row(['Computed at', computedAt]);
  row(['Calculation version', calculationVersion]);
  b.writeln();

  // The waterfall, in the same order and under the same labels as the screen
  // and the Backoffice export. Gross keeps a transaction that was later
  // refunded IN and the return takes it out again; PB1 and service charge are
  // added AFTER net sales, so they raise receipts and never profit.
  row([headers[1], headers[2]]);
  row(['Gross sales', report.grossSales]);
  row(['Discount', report.allDiscount]);
  row(['Sales returns', report.salesReturns]);
  if (report.taxIncluded != 0) {
    row(['Tax included in prices', report.taxIncluded]);
  }
  row(['Net sales', report.netSales]);
  row(['PB1', report.tax]);
  row(['Service Charge', report.serviceCharge]);
  if (report.rounding != 0) row(['Rounding', report.rounding]);
  row(['Total sales receipts', report.revenue]);
  row(['Orders', report.orderCount]);
  row(['Items sold', report.itemsSold]);
  row(['Average sale per order', report.averageOrder]);
  row(['Cancelled orders', report.cancelledCount]);
  row(['Cancelled value', report.cancelledValue]);
  row(['Refunded orders', report.refundedCount]);
  row(['Refunded money', report.refundedValue]);
  row(['Cost of goods', report.costOfGoods]);
  row(['Gross profit', report.grossProfit]);
  // Exported alongside the profit, not just shown on screen: a spreadsheet
  // that carries the figure without the caveat is a figure someone will
  // quote in a meeting. An undefined margin is a dash, never 0.0 — a period
  // with no sales did not make zero percent, it made nothing to divide by.
  final (margin, hasMargin) = report.grossMargin;
  row(['Gross margin %', hasMargin ? margin.toStringAsFixed(1) : '—']);
  row(['Cost coverage %', (report.costCoverage * 100).round()]);
  b.writeln();

  row([headers[3], headers[4], headers[2]]);
  for (final e in report.byPaymentMethod.entries) {
    row([paymentLabel(e.key), e.value.count, e.value.amount]);
  }
  b.writeln();

  // The server does not group by order type, so a connected export omits the
  // section rather than printing an empty one somebody would read as "no
  // dine-in sales".
  if (report.byOrderType.isNotEmpty) {
    row([headers[5], headers[4], headers[2]]);
    for (final e in report.byOrderType.entries) {
      row([orderTypeLabel(e.key), e.value.count, e.value.amount]);
    }
    b.writeln();
  }

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

String _date(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

String _two(int v) => v.toString().padLeft(2, '0');

/// Quotes a cell only when it needs it, and doubles any embedded quote — a
/// store or product name containing a comma would otherwise shift every
/// following column by one. [_safeText] runs first, matching the backend's
/// `RenderCSV`: its leading-quote guard and this function's RFC4180 quoting
/// are independent concerns, so a formula-guarded value that also contains a
/// comma still ends up quoted correctly.
String _escape(Object? value) {
  final s = _safeText('$value');
  if (!s.contains(',') && !s.contains('"') && !s.contains('\n')) return s;
  return '"${s.replaceAll('"', '""')}"';
}

/// Stops a spreadsheet from running a name as a formula. A customer or brand
/// called "=HYPERLINK(...)" typed at a till is data, and a leading quote is
/// how a spreadsheet is told so. Mirrors `reporting.safeText` in
/// `backend-go/internal/domain/reporting/csv.go` — the two must agree, since
/// both this file's CSV and the backend's cover values a cashier can type.
String _safeText(String s) {
  if (s.isEmpty) return s;
  const dangerous = {'=', '+', '-', '@', '\t', '\r'};
  return dangerous.contains(s[0]) ? "'$s" : s;
}
