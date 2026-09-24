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
    required this.grossSales,
    required this.allDiscount,
    required this.salesReturns,
    required this.tax,
    required this.serviceCharge,
    this.taxIncluded = 0,
    this.rounding = 0,
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

  /// Money collected on the sales that counted: net sales plus PB1 plus
  /// service charge. The field name is the old one and its meaning has not
  /// changed; what changed is that it is no longer the basis of profit.
  final int revenue;
  final int subtotal;
  final int discount;

  /// The waterfall, read top to bottom.
  ///
  /// [grossSales] keeps a transaction that was later refunded IN, and
  /// [salesReturns] takes it out again, so a refund is visible as a return
  /// rather than the day quietly shrinking. Identically:
  /// grossSales − allDiscount − salesReturns == subtotal − discount over the
  /// transactions revenue already counts. The same definitions the server
  /// uses, so a demo and a connected till compute the same figures.
  final int grossSales;
  final int allDiscount;
  final int salesReturns;

  /// PB1 amount — field name unchanged, meaning narrowed to PB1 only now
  /// that Service Charge is tracked separately.
  final int tax;
  final int serviceCharge;

  /// Fase 3: the part of [tax] already inside inclusive prices. It is in
  /// [subtotal], so it comes out of net sales; zero on a legacy receipt.
  final int taxIncluded;

  /// Fase 3: the final rounding collected — part of [revenue], never of
  /// sales. May be negative.
  final int rounding;
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

  /// Net sales, the figure the waterfall produces: gross − discounts −
  /// returns − included tax, the server's definition.
  int get netSales => subtotal - discount - taxIncluded;

  /// NET SALES minus cost of goods — not revenue minus cost of goods.
  ///
  /// PB1 and service charge are collected on somebody else's behalf. Counting
  /// them into the basis of profit inflated every margin in the app by
  /// whatever the tariff happened to be, which is the correction F1 exists
  /// for. Still GROSS profit: rent, wages and utilities are not in this app,
  /// so it must never be presented as net.
  int get grossProfit => netSales - costOfGoods;

  /// Gross margin as a percentage of net sales, and whether it means
  /// anything. A margin over no sales is undefined rather than zero, and
  /// rendering it as 0% invites reading an empty period as a bad one.
  (double, bool) get grossMargin =>
      netSales == 0 ? (0, false) : ((grossProfit * 100) / netSales, true);

  /// Gross margin as a percentage of net sales, zero when undefined. Prefer
  /// [grossMargin], which says which of the two it is.
  double get grossMarginPercent => grossMargin.$1;

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

  /// Average SALE per transaction — net sales over the transactions that
  /// counted, not takings over them. Two outlets on different tariffs are
  /// otherwise not comparable.
  int get averageOrder => orderCount == 0 ? 0 : netSales ~/ orderCount;

  bool get isEmpty => orderCount == 0;
}
