/// One category's slice of a [SalesReport], fully computed by
/// `OrderRepository.report` — nothing here is recalculated by the UI or the
/// CSV export, matching how [SalesReport.grossMarginPercent] etc. are
/// already precomputed.
///
/// [grossSales] and [netSales] are both pre-tax (tax is a store-wide line on
/// the report already, never allocated per category) — [netSales] is
/// [grossSales] minus this category's share of whatever order-level discount
/// applied, allocated with a largest-remainder split so that summed across
/// every category in a report, `Σ grossSales == Σ orders.subtotal` and
/// `Σ netSales == Σ (orders.subtotal - orders.discount)` exactly, not just
/// approximately.
class CategorySales {
  const CategorySales({
    required this.categoryId,
    required this.categoryName,
    required this.itemsSold,
    required this.grossSales,
    required this.netSales,
    required this.contributionPercent,
  });

  /// Sentinel used when a line's category cannot be recovered at all (no
  /// snapshot, no live category) — see `OrderRepository.report`.
  static const uncategorizedId = '__uncategorized__';

  final String categoryId;
  final String categoryName;
  final int itemsSold;
  final int grossSales;
  final int netSales;

  /// This category's [netSales] as a percentage of every category's
  /// [netSales] combined, 0..100.
  final double contributionPercent;
}
