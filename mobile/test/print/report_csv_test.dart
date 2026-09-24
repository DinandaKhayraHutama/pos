import 'package:flutter_test/flutter_test.dart';

import 'package:nti_pos/core/print/report_csv.dart';
import 'package:nti_pos/data/models/category_sales.dart';
import 'package:nti_pos/data/models/sales_report.dart';

/// Guards the formula-injection fix in `report_csv.dart`'s `_escape`.
///
/// A cashier, category, or (once Fase 2 adds them) customer/brand name is
/// text a person typed, and the CSV writer must not let a name that starts
/// with `=`, `+`, `-`, `@`, tab, or CR run as a spreadsheet formula when the
/// file is opened in Excel or Sheets. Mirrors
/// `backend-go/internal/domain/reporting/csv_test.go`'s coverage of
/// `safeText`, so the two implementations stay in lockstep.
void main() {
  final headers = List.generate(13, (i) => 'H$i');
  String paymentLabel(String key) => key;
  String orderTypeLabel(String key) => key;

  SalesReport reportWithCashier(String cashierName) => SalesReport(
    from: DateTime(2026, 1, 1),
    to: DateTime(2026, 1, 1),
    revenue: 0,
    subtotal: 0,
    discount: 0,
    grossSales: 0,
    allDiscount: 0,
    salesReturns: 0,
    tax: 0,
    serviceCharge: 0,
    orderCount: 0,
    itemsSold: 0,
    cancelledCount: 0,
    cancelledValue: 0,
    refundedCount: 0,
    refundedValue: 0,
    costOfGoods: 0,
    costCoverage: 0,
    byPaymentMethod: const {},
    byOrderType: const {},
    byCashier: {cashierName: const ReportBucket(amount: 1000, count: 1)},
    byCategory: const [],
    perDay: const {},
  );

  String csvFor(String cashierName) => buildReportCsv(
    reportWithCashier(cashierName),
    paymentLabel: paymentLabel,
    orderTypeLabel: orderTypeLabel,
    uncategorizedLabel: 'Uncategorized',
    headers: headers,
  );

  for (final dangerous in ['=', '+', '-', '@', '\t', '\r']) {
    test(
      'a cashier name starting with "$dangerous" is quote-guarded',
      () {
        final csv = csvFor('${dangerous}HYPERLINK("http://evil","x")');
        expect(
          csv,
          contains("'${dangerous}HYPERLINK"),
          reason: 'the leading character must be neutralised with a leading '
              "single quote, matching the backend's safeText",
        );
      },
    );
  }

  test('an ordinary cashier name is left untouched', () {
    final csv = csvFor('Budi Santoso');
    expect(csv, contains('Budi Santoso'));
    expect(csv, isNot(contains("'Budi")));
  });

  test('a name needing both the formula guard and comma-quoting gets both', () {
    final csv = csvFor('=SUM(A1:A9), oops');
    // RFC4180 quoting wraps the whole (already formula-guarded) cell in
    // double quotes because it contains a comma.
    expect(csv, contains('"\'=SUM(A1:A9), oops"'));
  });

  test('a category name is guarded the same way', () {
    final report = SalesReport(
      from: DateTime(2026, 1, 1),
      to: DateTime(2026, 1, 1),
      revenue: 0,
      subtotal: 0,
      discount: 0,
      grossSales: 0,
      allDiscount: 0,
      salesReturns: 0,
      tax: 0,
      serviceCharge: 0,
      orderCount: 0,
      itemsSold: 0,
      cancelledCount: 0,
      cancelledValue: 0,
      refundedCount: 0,
      refundedValue: 0,
      costOfGoods: 0,
      costCoverage: 0,
      byPaymentMethod: const {},
      byOrderType: const {},
      byCashier: const {},
      byCategory: const [
        CategorySales(
          categoryId: 'c1',
          categoryName: '=cmd|"/C calc"!A1',
          itemsSold: 1,
          grossSales: 1000,
          netSales: 1000,
          contributionPercent: 100,
        ),
      ],
      perDay: const {},
    );
    final csv = buildReportCsv(
      report,
      paymentLabel: paymentLabel,
      orderTypeLabel: orderTypeLabel,
      uncategorizedLabel: 'Uncategorized',
      headers: headers,
    );
    expect(csv, contains("'=cmd"));
  });
}
