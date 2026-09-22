import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/permissions.dart';
import '../data/device/till_coordinator.dart';
import '../data/models/sales_report.dart';
import '../data/models/server_report.dart';
import '../data/repositories/order_repository.dart';
import '../data/repositories/remote_report_repository.dart';
import 'outlet_provider.dart';
import 'settings_provider.dart';

/// The preset a report screen is on.
///
/// The same five the Backoffice offers, resolved on the device's clock. Named
/// here rather than derived from the dates so the chip that is lit survives a
/// rebuild, and so "7 hari" means one thing on both surfaces.
enum ReportPreset { today, yesterday, last7, month, custom }

/// The date range the report screen is showing.
///
/// Stored as whole dates: the repository widens `to` to the end of its day, so
/// a sale at 23:50 belongs to the day the user picked rather than falling into
/// a gap.
class ReportRange {
  const ReportRange(this.from, this.to, {this.preset = ReportPreset.custom});

  final DateTime from;
  final DateTime to;
  final ReportPreset preset;

  static DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  static ReportRange today() =>
      ReportRange(_today, _today, preset: ReportPreset.today);

  static ReportRange yesterday() {
    final d = _today.subtract(const Duration(days: 1));
    return ReportRange(d, d, preset: ReportPreset.yesterday);
  }

  static ReportRange lastDays(int days) => ReportRange(
    _today.subtract(Duration(days: days - 1)),
    _today,
    preset: days == 7 ? ReportPreset.last7 : ReportPreset.custom,
  );

  static ReportRange thisMonth() {
    final t = _today;
    return ReportRange(
      DateTime(t.year, t.month, 1),
      t,
      preset: ReportPreset.month,
    );
  }

  /// The same NUMBER OF DAYS immediately before this range.
  ///
  /// Same length rather than "the same period last month": comparing a 31-day
  /// month against a 28-day one makes February look like a collapse.
  ReportRange get previous {
    final days = to.difference(from).inDays + 1;
    return ReportRange(
      from.subtract(Duration(days: days)),
      from.subtract(const Duration(days: 1)),
    );
  }

  int get days => to.difference(from).inDays + 1;

  bool get isSingleDay =>
      from.year == to.year && from.month == to.month && from.day == to.day;

  @override
  bool operator ==(Object other) =>
      other is ReportRange &&
      other.from == from &&
      other.to == to &&
      other.preset == preset;

  @override
  int get hashCode => Object.hash(from, to, preset);
}

final reportRangeProvider = StateProvider<ReportRange>(
  (ref) => ReportRange.lastDays(7),
);

/// What a report screen has to draw, and where it came from.
///
/// One of [server] or [local] is set, never both. Which one is not a detail:
/// the server figure covers every register in the outlet, the local one covers
/// this device. Showing either under the other's heading is the mistake this
/// type exists to make impossible, so the screen reads [source] and says so.
class ReportView {
  const ReportView({
    this.server,
    this.previous,
    this.local,
    required this.source,
    this.cachedAt,
    this.unsyncedCount = 0,
  });

  final ServerReport? server;

  /// The comparison period, on the same source. Null when there is nothing to
  /// compare against or the comparison could not be fetched.
  final ServerReport? previous;

  /// This device's own figures, used in demo mode and before activation.
  final SalesReport? local;

  final ReportSource source;

  /// When a cached server copy was downloaded.
  final DateTime? cachedAt;

  /// Transactions on this device that have not reached the server. They are
  /// reported BESIDE the totals, never added to them: the server aggregate is
  /// what the outlet sold, and quietly topping it up with one device's queue
  /// would produce a number that matches nothing.
  final int unsyncedCount;

  bool get hasAnything => server != null || local != null;

  /// The figures in one shape, for the sections both sources share and for the
  /// CSV export. Null when there is nothing to show at all.
  ///
  /// The shape is shared; the MEANING is not, which is why nothing renders
  /// this without also rendering [source] beside it.
  SalesReport? get presentable => server?.asPresentation() ?? local;
}

enum ReportSource {
  /// Live from the server: the outlet's own rollups.
  server,

  /// The last server answer this device downloaded.
  cache,

  /// Connected, but this period was never downloaded and cannot be now.
  unavailable,

  /// Demo mode or not activated: this device's own transactions.
  local,

  /// The account may not open this report.
  forbidden,
}

/// The report the screen shows, chosen by what this install actually is.
///
/// A connected till reads the SERVER aggregate — every register in the outlet,
/// computed once, the same figures the Backoffice shows. Demo mode has no
/// server, so it computes the same formulas locally. The two are never mixed.
final salesReportProvider = FutureProvider.autoDispose<ReportView>((ref) async {
  final range = ref.watch(reportRangeProvider);
  final settings = ref.watch(settingsProvider).valueOrNull;
  final outletId = ref.watch(activeOutletProvider).valueOrNull?.id;

  if (TillCoordinator.current == null || settings == null) {
    // Demo mode: this device is the whole shop, and says so.
    final local = await OrderRepository.instance.report(
      from: range.from,
      to: range.to,
      outletId: outletId,
    );
    return ReportView(local: local, source: ReportSource.local);
  }

  // Which body this account may have. The summary one has no costs in it at
  // all, so a manager never receives a buying price to hide.
  final kind = settings.can(AppPermission.viewFinancialReports)
      ? ServerReportKind.sales
      : ServerReportKind.summary;
  if (!settings.can(AppPermission.viewDailySummary) &&
      !settings.can(AppPermission.viewFinancialReports)) {
    return const ReportView(source: ReportSource.forbidden);
  }

  final current = await RemoteReportRepository.fetch(
    employee: settings.employeeId,
    kind: kind,
    from: range.from,
    to: range.to,
    outletId: outletId,
  );
  if (current.forbidden) {
    return const ReportView(source: ReportSource.forbidden);
  }
  if (current.report == null) {
    return ReportView(
      source: ReportSource.unavailable,
      unsyncedCount: await OrderRepository.instance.unsyncedCount(),
    );
  }

  // The comparison is best-effort: a dashboard that refuses to draw because
  // last week could not be fetched is worse than one that draws this week and
  // says there is nothing to compare against.
  final before = range.previous;
  final previous = await RemoteReportRepository.fetch(
    employee: settings.employeeId,
    kind: kind,
    from: before.from,
    to: before.to,
    outletId: outletId,
  );

  return ReportView(
    server: current.report,
    previous: previous.report,
    source: current.fromCache ? ReportSource.cache : ReportSource.server,
    cachedAt: current.cachedAt,
    unsyncedCount: await OrderRepository.instance.unsyncedCount(),
  );
});
