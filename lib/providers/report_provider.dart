import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/sales_report.dart';
import '../data/repositories/order_repository.dart';
import 'outlet_provider.dart';

/// The date range the report screen is showing.
///
/// Stored as whole dates: the repository widens `to` to the end of its day, so
/// a sale at 23:50 belongs to the day the user picked rather than falling into
/// a gap.
class ReportRange {
  const ReportRange(this.from, this.to);

  final DateTime from;
  final DateTime to;

  static ReportRange today() {
    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day);
    return ReportRange(d, d);
  }

  static ReportRange lastDays(int days) {
    final now = DateTime.now();
    final to = DateTime(now.year, now.month, now.day);
    return ReportRange(to.subtract(Duration(days: days - 1)), to);
  }

  static ReportRange thisMonth() {
    final now = DateTime.now();
    return ReportRange(
      DateTime(now.year, now.month, 1),
      DateTime(now.year, now.month, now.day),
    );
  }

  bool get isSingleDay =>
      from.year == to.year && from.month == to.month && from.day == to.day;

  @override
  bool operator ==(Object other) =>
      other is ReportRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

final reportRangeProvider = StateProvider<ReportRange>(
  (ref) => ReportRange.lastDays(7),
);

final salesReportProvider = FutureProvider.autoDispose<SalesReport>((ref) {
  final range = ref.watch(reportRangeProvider);
  // Scoped to the branch this device is standing in, like every other figure
  // in the app. An owner comparing branches switches the device's outlet;
  // `report(outletId: null)` would sum the whole chain, which is a view worth
  // building but not one anything asks for yet.
  return OrderRepository.instance.report(
    from: range.from,
    to: range.to,
    outletId: ref.watch(activeOutletProvider).valueOrNull?.id,
  );
});
