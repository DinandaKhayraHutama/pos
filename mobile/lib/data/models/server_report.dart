/// The sales report as the server computes it.
///
/// This is deliberately NOT [SalesReport]: that one is computed from this
/// device's own SQLite and covers what this till rang up, while this one is
/// the outlet's rollup and covers every register in it. Folding them into one
/// type is how a screen ends up showing a device total under an outlet
/// heading — the exact failure the source labels on the report screen exist to
/// prevent. They answer different questions and keep different shapes.
library;

import 'category_sales.dart';
import 'sales_report.dart';

/// One grouped figure: an outlet, a cashier, a payment method, a category.
class ServerLine {
  const ServerLine({
    required this.key,
    required this.label,
    required this.revenue,
    required this.netSales,
    required this.count,
  });

  factory ServerLine.fromJson(Map<String, dynamic> json) => ServerLine(
    key: (json['key'] ?? '') as String,
    label: (json['label'] ?? '') as String,
    revenue: _int(json['revenue']),
    netSales: _int(json['net_sales']),
    count: _int(json['count']),
  );

  final String key;
  final String label;

  /// Money collected, tax and service charge included.
  final int revenue;

  /// The sale itself, before tax and service charge. Zero for a payment
  /// method: money arrives as a receipt total, and splitting a tender into
  /// "net" would invent a number nobody took.
  final int netSales;
  final int count;
}

class ServerProductLine {
  const ServerProductLine({
    required this.key,
    required this.label,
    required this.quantity,
    required this.grossSales,
    required this.netSales,
    required this.costOfGoods,
  });

  factory ServerProductLine.fromJson(Map<String, dynamic> json) =>
      ServerProductLine(
        key: (json['key'] ?? '') as String,
        label: (json['label'] ?? '') as String,
        quantity: _int(json['quantity']),
        grossSales: _int(json['gross_sales']),
        netSales: _int(json['net_sales']),
        costOfGoods: _int(json['cost_of_goods']),
      );

  final String key;
  final String label;
  final int quantity;
  final int grossSales;
  final int netSales;
  final int costOfGoods;
}

class ServerCategoryLine {
  const ServerCategoryLine({
    required this.key,
    required this.label,
    required this.grossSales,
    required this.netSales,
    required this.items,
    required this.contribution,
  });

  factory ServerCategoryLine.fromJson(Map<String, dynamic> json) =>
      ServerCategoryLine(
        key: (json['key'] ?? '') as String,
        label: (json['label'] ?? '') as String,
        grossSales: _int(json['gross_sales']),
        netSales: _int(json['net_sales']),
        items: _int(json['items']),
        contribution: _double(json['contribution']),
      );

  final String key;
  final String label;
  final int grossSales;
  final int netSales;
  final int items;
  final double contribution;
}

/// A category and the items sold inside it. The items always sum to the
/// category's own net: both come out of one allocation on the server.
class ServerCategoryProducts {
  const ServerCategoryProducts({
    required this.key,
    required this.label,
    required this.items,
  });

  factory ServerCategoryProducts.fromJson(Map<String, dynamic> json) =>
      ServerCategoryProducts(
        key: (json['key'] ?? '') as String,
        label: (json['label'] ?? '') as String,
        items: ((json['items'] as List?) ?? const [])
            .map((v) => ServerProductLine.fromJson(_map(v)))
            .toList(),
      );

  final String key;
  final String label;
  final List<ServerProductLine> items;
}

class ServerHourLine {
  const ServerHourLine({
    required this.hour,
    required this.netSales,
    required this.count,
  });

  factory ServerHourLine.fromJson(Map<String, dynamic> json) => ServerHourLine(
    hour: _int(json['hour']),
    netSales: _int(json['net_sales']),
    count: _int(json['count']),
  );

  final int hour;
  final int netSales;
  final int count;
}

/// One day of the week across the period.
class ServerWeekdayLine {
  const ServerWeekdayLine({
    required this.weekday,
    required this.label,
    required this.netSales,
    required this.count,
    required this.days,
  });

  factory ServerWeekdayLine.fromJson(Map<String, dynamic> json) =>
      ServerWeekdayLine(
        weekday: _int(json['weekday']),
        label: (json['label'] ?? '') as String,
        netSales: _int(json['net_sales']),
        count: _int(json['count']),
        days: _int(json['days']),
      );

  /// Sunday is 0, matching the server and Go's own numbering.
  final int weekday;
  final String label;
  final int netSales;
  final int count;

  /// How many calendar days of this weekday actually traded, so a range that
  /// is not a whole number of weeks can be averaged rather than ranked.
  final int days;
}

class ServerDayLine {
  const ServerDayLine({
    required this.date,
    required this.netSales,
    required this.count,
  });

  factory ServerDayLine.fromJson(Map<String, dynamic> json) => ServerDayLine(
    date: DateTime.parse(json['date'] as String),
    netSales: _int(json['net_sales']),
    count: _int(json['count']),
  );

  final DateTime date;
  final int netSales;
  final int count;
}

/// The whole report body.
class ServerReport {
  const ServerReport({
    required this.from,
    required this.to,
    required this.outletId,
    required this.outletName,
    required this.allOutlets,
    required this.timezone,
    required this.calculationVersion,
    required this.computedAt,
    required this.pendingSlices,
    required this.incomplete,
    required this.anomalyCount,
    required this.grossSales,
    required this.discounts,
    required this.salesReturns,
    required this.netSales,
    required this.tax,
    required this.serviceCharge,
    this.taxIncluded = 0,
    this.rounding = 0,
    required this.revenue,
    required this.orderCount,
    required this.averageSale,
    required this.itemsSold,
    required this.cancelledCount,
    required this.cancelledAmount,
    required this.refundedCount,
    required this.refundedAmount,
    this.costOfGoods,
    this.grossProfit,
    this.costCoverage,
    this.margin,
    this.byHour = const [],
    this.byWeekday = const [],
    this.byDay = const [],
    this.byOutlet = const [],
    this.byPayment = const [],
    this.bySalesType = const [],
    this.byCashier = const [],
    this.byCategory = const [],
    this.byBrand = const [],
    this.byProduct = const [],
    this.byProductInCategory = const [],
  });

  factory ServerReport.fromJson(Map<String, dynamic> json) {
    final period = _map(json['period']);
    final scope = _map(json['scope']);
    final sales = _map(json['sales']);
    // The cost half is ABSENT, not zero, when the account may not see it.
    // Nullable fields keep that distinction all the way to the screen: a
    // missing profit is a section that is not drawn, never a zero rupiah one.
    final profit = json['profit'] == null ? null : _map(json['profit']);
    return ServerReport(
      from: DateTime.parse(period['from'] as String),
      to: DateTime.parse(period['to'] as String),
      outletId: (scope['outlet_id'] ?? '') as String,
      outletName: (scope['outlet_name'] ?? '') as String,
      allOutlets: (scope['all_outlets'] ?? false) as bool,
      timezone: (json['timezone'] ?? '') as String,
      calculationVersion: _int(json['calculation_version']),
      computedAt: json['computed_at_ms'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(_int(json['computed_at_ms'])),
      pendingSlices: _int(json['pending_slices']),
      incomplete: (json['incomplete'] ?? false) as bool,
      anomalyCount: _int(json['anomaly_count']),
      grossSales: _int(sales['gross_sales']),
      discounts: _int(sales['discounts']),
      salesReturns: _int(sales['sales_returns']),
      netSales: _int(sales['net_sales']),
      tax: _int(sales['tax']),
      serviceCharge: _int(sales['service_charge']),
      // Absent from a server older than 2.8.0, which never had either.
      taxIncluded: _int(sales['tax_included']),
      rounding: _int(sales['rounding']),
      revenue: _int(sales['revenue']),
      orderCount: _int(sales['order_count']),
      averageSale: _int(sales['average_sale']),
      itemsSold: _int(sales['items_sold']),
      cancelledCount: _int(sales['cancelled_count']),
      cancelledAmount: _int(sales['cancelled_amount']),
      refundedCount: _int(sales['refunded_count']),
      refundedAmount: _int(sales['refunded_amount']),
      costOfGoods: profit == null ? null : _int(profit['cost_of_goods']),
      grossProfit: profit == null ? null : _int(profit['gross_profit']),
      costCoverage: profit == null ? null : _double(profit['cost_coverage']),
      margin: profit?['margin'] == null ? null : _double(profit!['margin']),
      byHour: _list(json['by_hour'], ServerHourLine.fromJson),
      byWeekday: _list(json['by_weekday'], ServerWeekdayLine.fromJson),
      byDay: _list(json['by_day'], ServerDayLine.fromJson),
      byOutlet: _list(json['by_outlet'], ServerLine.fromJson),
      byPayment: _list(json['by_payment'], ServerLine.fromJson),
      bySalesType: _list(json['by_sales_type'], ServerLine.fromJson),
      byCashier: _list(json['by_cashier'], ServerLine.fromJson),
      byCategory: _list(json['by_category'], ServerCategoryLine.fromJson),
      byBrand: _list(json['by_brand'], ServerCategoryLine.fromJson),
      byProduct: _list(json['by_product'], ServerProductLine.fromJson),
      byProductInCategory: _list(
        json['by_product_in_category'],
        ServerCategoryProducts.fromJson,
      ),
    );
  }

  final DateTime from;
  final DateTime to;
  final String outletId;
  final String outletName;
  final bool allOutlets;
  final String timezone;

  /// Which rules produced these figures. 2 is the F1 waterfall.
  final int calculationVersion;

  /// When the server last recomputed the rollups behind this. Null when the
  /// period holds no computed rollup at all.
  final DateTime? computedAt;

  /// Day-outlet slices in range with changes not yet rolled up.
  final int pendingSlices;

  /// True while some day in range is still computed under the old rules, so
  /// the waterfall columns are not final.
  final bool incomplete;

  /// Receipts whose own arithmetic does not close. Reported, never repaired.
  final int anomalyCount;

  final int grossSales;
  final int discounts;
  final int salesReturns;
  final int netSales;
  final int tax;
  final int serviceCharge;

  /// Fase 3: tax already inside inclusive prices, out of [netSales].
  final int taxIncluded;

  /// Fase 3: rounding collected; part of [revenue], never of sales.
  final int rounding;
  final int revenue;
  final int orderCount;
  final int averageSale;
  final int itemsSold;
  final int cancelledCount;
  final int cancelledAmount;
  final int refundedCount;
  final int refundedAmount;

  /// Null when this account may not see what the merchant pays for stock.
  final int? costOfGoods;
  final int? grossProfit;
  final double? costCoverage;

  /// Null when there are no net sales to divide by. An undefined margin is
  /// shown as "—"; drawing it as 0% reads as a bad period rather than an
  /// empty one.
  final double? margin;

  final List<ServerHourLine> byHour;
  final List<ServerWeekdayLine> byWeekday;
  final List<ServerDayLine> byDay;
  final List<ServerLine> byOutlet;
  final List<ServerLine> byPayment;
  final List<ServerLine> bySalesType;
  final List<ServerLine> byCashier;
  final List<ServerCategoryLine> byCategory;
  final List<ServerCategoryLine> byBrand;
  final List<ServerProductLine> byProduct;
  final List<ServerCategoryProducts> byProductInCategory;

  bool get hasCostData => costOfGoods != null;

  /// Whether the profit figure rests on enough data to be worth showing
  /// without a caveat — the same nine-in-ten threshold the server uses.
  bool get costCoverageLow =>
      costCoverage != null && itemsSold > 0 && costCoverage! < 0.9;

  bool get isEmpty =>
      orderCount == 0 && cancelledCount == 0 && refundedCount == 0;

  /// The same figures in [SalesReport]'s shape, for the report sections both
  /// sources share.
  ///
  /// A RENDERING convenience and nothing more. It does not make the two the
  /// same thing: this one still covers every register in the outlet and that
  /// one covers this device, which is why the screen always shows where its
  /// numbers came from. `byOrderType` is the server's sales-type grouping,
  /// keyed by the label it gives each — empty from a server older than 2.8.0,
  /// which draws no section rather than a fabricated one.
  SalesReport asPresentation() => SalesReport(
    from: from,
    to: to,
    revenue: revenue,
    // Rebuilt so SalesReport.netSales (subtotal − discount − included tax)
    // reads back the server's own net.
    subtotal: netSales + discounts + taxIncluded,
    discount: discounts,
    grossSales: grossSales,
    allDiscount: discounts,
    salesReturns: salesReturns,
    tax: tax,
    serviceCharge: serviceCharge,
    taxIncluded: taxIncluded,
    rounding: rounding,
    orderCount: orderCount,
    itemsSold: itemsSold,
    cancelledCount: cancelledCount,
    cancelledValue: cancelledAmount,
    refundedCount: refundedCount,
    refundedValue: refundedAmount,
    costOfGoods: costOfGoods ?? 0,
    costCoverage: costCoverage ?? 0,
    byPaymentMethod: {
      for (final p in byPayment)
        p.key: ReportBucket(amount: p.revenue, count: p.count),
    },
    byOrderType: {
      for (final t in bySalesType)
        t.label: ReportBucket(amount: t.revenue, count: t.count),
    },
    byCashier: {
      for (final c in byCashier)
        c.label: ReportBucket(amount: c.netSales, count: c.count),
    },
    byCategory: [
      for (final c in byCategory)
        CategorySales(
          categoryId: c.key,
          categoryName: c.label,
          grossSales: c.grossSales,
          netSales: c.netSales,
          itemsSold: c.items,
          contributionPercent: c.contribution,
        ),
    ],
    perDay: {for (final d in byDay) d.date: d.netSales},
  );
}

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

int _int(Object? v) => v is num ? v.toInt() : 0;

double _double(Object? v) => v is num ? v.toDouble() : 0;

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) read) =>
    ((raw as List?) ?? const []).map((v) => read(_map(v))).toList();
