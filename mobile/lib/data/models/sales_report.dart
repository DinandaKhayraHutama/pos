import 'category_sales.dart';

/// One slice of a report: money taken and how many orders produced it.
class ReportBucket {
  const ReportBucket({required this.amount, required this.count});
  final int amount;
  final int count;
}

/// A consistent snapshot of sales over a date range.
///
/// Built in a single repository call rather than one query per tile, so every
/// figure on the report screen describes the same instant. Cancelled orders are
/// excluded from the totals and reported separately — they are worth seeing,
/// but they are not revenue.
class SalesReport {
  const SalesReport({
    required this.from,
    required this.to,
    required this.revenue,
    required this.subtotal,
    required this.discount,
    required this.tax,
    required this.serviceCharge,
    required this.orderCount,
    required this.itemsSold,
    required this.cancelledCount,
    required this.cancelledValue,
    required this.refundedCount,
    required this.refundedValue,
    required this.costOfGoods,
    required this.costCoverage,
    required this.byPaymentMethod,
    required this.byOrderType,
    required this.byCashier,
    required this.byCategory,
    required this.perDay,
  });

  final DateTime from;
  final DateTime to;

  final int revenue;
  final int subtotal;
  final int discount;

  /// PB1 amount — field name unchanged, meaning narrowed to PB1 only now
  /// that Service Charge is tracked separately.
  final int tax;
  final int serviceCharge;
  final int orderCount;
  final int itemsSold;

  /// Cancelled orders in range. Not part of [revenue].
  final int cancelledCount;
  final int cancelledValue;

  /// Orders refunded in range, and how much was handed back. Kept apart from
  /// the cancelled pair because striking out a mistake and giving money back
  /// to an unhappy customer are different problems with different fixes.
  final int refundedCount;
  final int refundedValue;

  /// Cost of the goods behind [revenue], summed from the cost frozen on each
  /// order line at the time of sale.
  final int costOfGoods;

  /// Share of sold items whose line carried a cost, 0..1.
  ///
  /// A profit figure computed over a catalogue where half the products have
  /// no cost entered is not wrong so much as meaningless, and it flatters:
  /// every costless item reads as pure margin. The report shows this next to
  /// the profit so the number is read with the right amount of trust.
  final double costCoverage;

  /// Revenue minus cost of goods. Note this is gross profit: rent, wages and
  /// utilities are not in this app, so it must never be presented as net.
  int get grossProfit => revenue - costOfGoods;

  /// Gross margin as a percentage of revenue.
  double get grossMarginPercent =>
      revenue == 0 ? 0 : (grossProfit * 100) / revenue;

  /// Whether the profit figure rests on enough data to be worth showing
  /// without a caveat. Two thirds is a judgement call, not a standard.
  bool get costIsReliable => costCoverage >= 0.66;

  /// Keyed by the enum's `wire` value, so the UI maps them to labels and the
  /// model stays free of localisation.
  final Map<String, ReportBucket> byPaymentMethod;
  final Map<String, ReportBucket> byOrderType;

  /// Keyed by cashier NAME as recorded on the order, not by id — a report has
  /// to keep reading correctly after an employee is renamed or removed.
  final Map<String, ReportBucket> byCashier;

  /// Sales grouped by category, pre-tax AND pre-service-charge, sorted by
  /// [CategorySales.netSales] descending. Grouped by category ID (not name,
  /// unlike [byCashier]) so a rename mid-range still merges into one row —
  /// see `OrderRepository.report` for the full reasoning and the
  /// largest-remainder discount allocation that keeps this list's totals
  /// exact. Neither PB1 nor Service Charge is allocated per category —
  /// both already have their own report line, and a second proportional
  /// split nobody asked for would just be more complexity.
  final List<CategorySales> byCategory;

  /// Revenue per local calendar day. Sparse: days with no sales are absent.
  final Map<DateTime, int> perDay;

  int get averageOrder => orderCount == 0 ? 0 : revenue ~/ orderCount;

  bool get isEmpty => orderCount == 0;
}
