import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/localization/l10n.dart';
import '../../core/export/file_export.dart';
import '../../core/print/report_csv.dart';
import '../../core/theme/app_dimensions.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_background.dart';
import '../../core/widgets/glass/glass_app_bar.dart';
import '../../core/widgets/glass/glass_card.dart';
import '../../core/widgets/loading_indicator.dart';
import '../../data/models/enums.dart';
import '../../data/models/sales_report.dart';
import '../../data/models/server_report.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../providers/report_provider.dart';
import '../../core/widgets/app_snack_bar.dart';

/// Sales over a chosen date range, broken down by payment method, order type
/// and cashier, with a CSV export.
class ReportPage extends ConsumerWidget {
  const ReportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final report = ref.watch(salesReportProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: GlassAppBar(
            title: l10n.reportTitle,
            actions: [
              IconButton(
                tooltip: l10n.reportExport,
                onPressed: report.valueOrNull?.presentable == null
                    ? null
                    : () => _export(context, report.value!),
                icon: const Icon(Icons.download_rounded),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(AppDimensions.space16),
            children: [
              const _RangePicker(),
              const SizedBox(height: AppDimensions.space16),
              report.when(
                loading: () => const LoadingIndicator(),
                error: (e, _) => Text('$e'),
                data: (view) => _ReportView(view: view),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context, ReportView view) async {
    final l10n = context.l10n;
    final report = view.presentable!;
    final server = view.server;
    final csv = buildReportCsv(
      report,
      // What the file actually covers, and when those figures were produced.
      // A connected export is the outlet's; a demo one is this device's.
      scope: switch (view.source) {
        ReportSource.server || ReportSource.cache =>
          server!.allOutlets
              ? l10n.reportOutletComparison
              : (server.outletName.isEmpty ? '' : server.outletName),
        _ => l10n.reportSourceLocal,
      },
      computedAt: server?.computedAt == null
          ? ''
          : DateFormatter.dateTime(server!.computedAt!),
      calculationVersion: server?.calculationVersion ?? 2,
      paymentLabel: (k) => switch (PaymentMethodX.fromWire(k)) {
        PaymentMethod.cash => l10n.posCash,
        PaymentMethod.qris => l10n.posQris,
        PaymentMethod.card => l10n.posCard,
        PaymentMethod.ewallet => l10n.posPaymentEwallet,
        PaymentMethod.transfer => l10n.posPaymentTransfer,
        PaymentMethod.other => l10n.posPaymentOther,
      },
      orderTypeLabel: (k) => salesTypeLabel(l10n, k),
      uncategorizedLabel: l10n.reportUncategorized,
      headers: [
        l10n.reportPeriod,
        l10n.reportMetric,
        l10n.reportAmount,
        l10n.reportMethod,
        l10n.reportCount,
        l10n.reportType,
        l10n.reportCashier,
        l10n.reportDate,
        l10n.productCategory,
        l10n.reportItemsSold,
        l10n.reportGrossSales,
        l10n.reportNetSales,
        l10n.reportContribution,
      ],
    );

    await saveTextFile(
      filename:
          'sales-report-${DateFormat('yyyyMMdd').format(report.from)}.csv',
      content: csv,
    );
    if (context.mounted) showAppSnackBar(context, l10n.reportExported);
  }
}

class _RangePicker extends ConsumerWidget {
  const _RangePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final design = context.design;
    final range = ref.watch(reportRangeProvider);

    // The same five the Backoffice offers, so "7 hari" means one thing on
    // both surfaces and two people comparing screens are comparing periods.
    final presets = <(String, ReportRange)>[
      (l10n.reportToday, ReportRange.today()),
      (l10n.historyPeriodYesterday, ReportRange.yesterday()),
      (l10n.reportLast7, ReportRange.lastDays(7)),
      (l10n.reportLast30, ReportRange.lastDays(30)),
      (l10n.reportThisMonth, ReportRange.thisMonth()),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, value) in presets)
              ChoiceChip(
                label: Text(label),
                selected: range == value,
                onSelected: (_) =>
                    ref.read(reportRangeProvider.notifier).state = value,
              ),
            ActionChip(
              avatar: const Icon(Icons.date_range_rounded, size: 16),
              label: Text(l10n.reportCustomRange),
              onPressed: () => _pick(context, ref, range),
            ),
          ],
        ),
        const SizedBox(height: AppDimensions.space8),
        Text(
          range.isSingleDay
              ? DateFormat('d MMM yyyy').format(range.from)
              : '${DateFormat('d MMM').format(range.from)} – '
                    '${DateFormat('d MMM yyyy').format(range.to)}',
          style: TextStyle(color: design.textMedium, fontSize: 12),
        ),
      ],
    );
  }

  Future<void> _pick(
    BuildContext context,
    WidgetRef ref,
    ReportRange current,
  ) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      // Sales cannot exist in the future, and the seed reaches a week back —
      // a two-year window covers any realistic demo without an endless scroll.
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: DateTimeRange(start: current.from, end: current.to),
    );
    if (picked == null) return;
    ref.read(reportRangeProvider.notifier).state = ReportRange(
      picked.start,
      picked.end,
    );
  }
}

/// Draws whichever report this install actually has, always under a line that
/// says where it came from.
///
/// The label is not decoration. A server report covers every register in the
/// outlet; a local one covers this device. They look identical on screen, so
/// without the label an owner comparing two tablets is comparing two different
/// questions and does not know it.
class _ReportView extends StatelessWidget {
  const _ReportView({required this.view});
  final ReportView view;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;

    if (view.source == ReportSource.forbidden) {
      return GlassCard.solid(
        child: Text(
          l10n.reportNotPermitted,
          textAlign: TextAlign.center,
          style: TextStyle(color: design.textMedium),
        ),
      );
    }
    final report = view.presentable;
    if (report == null) {
      return GlassCard.solid(
        child: Text(
          l10n.reportSourceUnavailable,
          textAlign: TextAlign.center,
          style: TextStyle(color: design.textMedium),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SourceBanner(view: view),
        const SizedBox(height: AppDimensions.space12),
        if (report.isEmpty && view.unsyncedCount == 0)
          GlassCard.solid(
            child: Text(
              l10n.reportEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(color: design.textMedium),
            ),
          )
        else
          _ReportBody(report: report, view: view),
      ],
    );
  }
}

/// Where these figures came from, how fresh they are, and what is missing.
class _SourceBanner extends StatelessWidget {
  const _SourceBanner({required this.view});
  final ReportView view;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final lines = <String>[
      switch (view.source) {
        ReportSource.server => l10n.reportSourceServer(
          view.server?.computedAt == null
              ? '—'
              : DateFormatter.dateTime(view.server!.computedAt!),
        ),
        ReportSource.cache => l10n.reportSourceCache(
          view.cachedAt == null ? '—' : DateFormatter.dateTime(view.cachedAt!),
        ),
        ReportSource.unavailable => l10n.reportSourceUnavailable,
        ReportSource.local => l10n.reportSourceLocal,
        ReportSource.forbidden => l10n.reportNotPermitted,
      },
      if (view.server?.incomplete ?? false) l10n.reportIncomplete,
      // Named beside the totals, never added to them: the server figure is
      // what the outlet sold as the server knows it, and quietly topping it up
      // with one device's queue produces a number that matches nothing.
      if (view.unsyncedCount > 0) l10n.reportUnsyncedNotice(view.unsyncedCount),
    ];

    return GlassCard.solid(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: design.textMedium,
                  ),
                  const SizedBox(width: AppDimensions.space8),
                  Expanded(
                    child: Text(
                      line,
                      style: TextStyle(fontSize: 12, color: design.textMedium),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report, required this.view});
  final SalesReport report;
  final ReportView view;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final server = view.server;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeadlineTiles(report: report, view: view),
        const SizedBox(height: AppDimensions.space16),
        _Section(
          title: l10n.reportWaterfall,
          child: Column(
            children: [
              // Read top to bottom: each line is produced from the one above
              // it. Tiles would say nothing about that order, which is the
              // whole point of showing it this way.
              _MoneyRow(label: l10n.reportGrossSales, value: report.grossSales),
              _MoneyRow(label: l10n.reportDiscount, value: -report.allDiscount),
              _MoneyRow(
                label: l10n.reportSalesReturns,
                value: -report.salesReturns,
              ),
              // Tax already inside inclusive prices was never the merchant's
              // sale; it comes out here and goes back in with PB1 below.
              if (report.taxIncluded != 0)
                _MoneyRow(
                  label: l10n.posTaxIncluded,
                  value: -report.taxIncluded,
                ),
              const Divider(height: AppDimensions.space20),
              _MoneyRow(
                label: l10n.reportNetSales,
                value: report.netSales,
                bold: true,
              ),
              _MoneyRow(label: l10n.reportTax, value: report.tax),
              _MoneyRow(
                label: l10n.reportServiceCharge,
                value: report.serviceCharge,
              ),
              if (report.rounding != 0)
                _MoneyRow(label: l10n.posRounding, value: report.rounding),
              const Divider(height: AppDimensions.space20),
              _MoneyRow(
                label: l10n.reportTotalReceipts,
                value: report.revenue,
                bold: true,
              ),
              const SizedBox(height: 6),
              _PlainRow(
                label: l10n.reportItemsSold,
                value: '${report.itemsSold}',
              ),
              _PlainRow(
                label: l10n.reportCancelled,
                value:
                    '${report.cancelledCount} · ${MoneyFormatter.format(report.cancelledValue)}',
              ),
              // Only when it happened. A permanent "Refunded: 0" row trains
              // the eye to skip the line, which is the one line an owner
              // should never skip.
              if (report.refundedCount > 0)
                _PlainRow(
                  label: l10n.reportRefunded,
                  value:
                      '${report.refundedCount} · ${MoneyFormatter.format(report.refundedValue)}',
                ),
            ],
          ),
        ),
        // The profit half is drawn only when the account may see it. When the
        // server withheld it the figures are ABSENT from the response, not
        // zero, so there is nothing here to accidentally render as free money.
        if (server == null || server.hasCostData) ...[
          const SizedBox(height: AppDimensions.space12),
          _ProfitSection(report: report),
        ],
        const SizedBox(height: AppDimensions.space12),
        _BucketSection(
          title: l10n.reportByPayment,
          buckets: report.byPaymentMethod,
          labelFor: (k) => switch (PaymentMethodX.fromWire(k)) {
            PaymentMethod.cash => l10n.posCash,
            PaymentMethod.qris => l10n.posQris,
            PaymentMethod.card => l10n.posCard,
            PaymentMethod.ewallet => l10n.posPaymentEwallet,
            PaymentMethod.transfer => l10n.posPaymentTransfer,
            PaymentMethod.other => l10n.posPaymentOther,
          },
          total: report.revenue,
        ),
        // The server does not group by order type, so a connected till shows
        // no section rather than an invented one.
        if (report.byOrderType.isNotEmpty) ...[
          const SizedBox(height: AppDimensions.space12),
          _BucketSection(
            title: l10n.reportByType,
            buckets: report.byOrderType,
            labelFor: (k) => salesTypeLabel(l10n, k),
            total: report.revenue,
          ),
        ],
        const SizedBox(height: AppDimensions.space12),
        _CategorySection(report: report),
        if (server != null && server.byBrand.isNotEmpty) ...[
          const SizedBox(height: AppDimensions.space12),
          _ServerBrandSection(lines: server.byBrand),
        ],
        if (server != null && server.byProductInCategory.isNotEmpty) ...[
          const SizedBox(height: AppDimensions.space12),
          _TopItemsSection(groups: server.byProductInCategory),
        ],
        if (server != null && server.byWeekday.isNotEmpty) ...[
          const SizedBox(height: AppDimensions.space12),
          _WeekdaySection(lines: server.byWeekday),
        ],
        // Only worth a section when there is more than one branch to compare.
        if (server != null && server.byOutlet.length > 1) ...[
          const SizedBox(height: AppDimensions.space12),
          _OutletSection(lines: server.byOutlet),
        ],
        const SizedBox(height: AppDimensions.space12),
        _BucketSection(
          title: l10n.reportByCashier,
          buckets: report.byCashier,
          labelFor: (k) => k,
          total: report.netSales,
        ),
        const SizedBox(height: AppDimensions.space12),
        _DailySection(report: report),
      ],
    );
  }
}

/// Revenue minus cost of goods, with the honesty attached.
///
/// Two caveats travel with the number and neither is optional. It is GROSS
/// profit — rent, wages and utilities are not in this app, and an owner who
/// reads this as take-home will make a bad decision with it. And it is only
/// as good as the cost data behind it: every product with no cost recorded
/// reads as pure margin, so a half-costed catalogue reports a figure that
/// flatters. The coverage line says how much of it is real.
class _ProfitSection extends StatelessWidget {
  const _ProfitSection({required this.report});
  final SalesReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final profit = report.grossProfit;

    return _Section(
      title: l10n.reportProfit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MoneyRow(label: l10n.reportRevenue, value: report.revenue),
          _MoneyRow(label: l10n.reportCostOfGoods, value: -report.costOfGoods),
          const Divider(height: AppDimensions.space20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.reportProfit,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: design.textMedium,
                ),
              ),
              Text(
                MoneyFormatter.format(profit),
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 20,
                  // Red when the range lost money. It can genuinely happen —
                  // a day of heavy discounting — and painting it in the
                  // brand colour would hide the one result worth reacting to.
                  color: profit < 0 ? design.error : design.success,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _PlainRow(
            label: l10n.reportMargin,
            value: '${report.grossMarginPercent.toStringAsFixed(1)}%',
          ),
          const SizedBox(height: AppDimensions.space10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                report.costIsReliable
                    ? Icons.info_outline_rounded
                    : Icons.warning_amber_rounded,
                size: 14,
                color: report.costIsReliable ? design.textLow : design.warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${l10n.reportProfitCaveat} '
                  '${l10n.reportCostCoverage((report.costCoverage * 100).round())}',
                  style: TextStyle(
                    fontSize: 11,
                    color: report.costIsReliable
                        ? design.textLow
                        : design.warning,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Top items within each category.
///
/// The items in a group always sum to that category's own net sales: the
/// server allocates the order discount across categories and then across the
/// products inside each one, in a single pass, so the two breakdowns cannot
/// round a rupiah apart.
class _TopItemsSection extends StatelessWidget {
  const _TopItemsSection({required this.groups});
  final List<ServerCategoryProducts> groups;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return _Section(
      title: context.l10n.reportTopItemsInCategory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final group in groups) ...[
            Padding(
              padding: const EdgeInsets.only(top: AppDimensions.space8),
              child: Text(
                group.label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: design.textMedium,
                ),
              ),
            ),
            for (final item in group.items)
              _PlainRow(
                label: '${item.label} · ${item.quantity}',
                value: MoneyFormatter.format(item.netSales),
              ),
          ],
        ],
      ),
    );
  }
}

/// Net sales by day of the week.
///
/// The weekday comes from the BUSINESS date on the server, not from a
/// timestamp: a sale rung up after midnight belongs to the trading day it was
/// part of. The day count says how many of each weekday actually traded, so a
/// period that is not a whole number of weeks can be read honestly.
class _WeekdaySection extends StatelessWidget {
  const _WeekdaySection({required this.lines});
  final List<ServerWeekdayLine> lines;

  @override
  Widget build(BuildContext context) => _Section(
    title: context.l10n.reportByWeekday,
    child: Column(
      children: [
        for (final line in lines)
          _PlainRow(
            label: '${line.label} · ${line.days}',
            value: MoneyFormatter.format(line.netSales),
          ),
      ],
    ),
  );
}

/// Branches over the same period, ranked by net sales rather than takings: a
/// branch that charges service would otherwise come out ahead on tariff alone.
class _OutletSection extends StatelessWidget {
  const _OutletSection({required this.lines});
  final List<ServerLine> lines;

  @override
  Widget build(BuildContext context) => _Section(
    title: context.l10n.reportOutletComparison,
    child: Column(
      children: [
        for (final line in lines)
          _PlainRow(
            label: '${line.label} · ${line.count}',
            value: MoneyFormatter.format(line.netSales),
          ),
      ],
    ),
  );
}

class _HeadlineTiles extends StatelessWidget {
  const _HeadlineTiles({required this.report, required this.view});
  final SalesReport report;
  final ReportView view;

  /// The movement against the comparison period, or a dash.
  ///
  /// A zero base is NOT a 100% rise: there is nothing to compare against, and
  /// a made-up percentage turns a first day of trade into a triumph.
  String _delta(BuildContext context, int current, int? previous) {
    final l10n = context.l10n;
    if (previous == null || previous == 0) return l10n.reportNoComparison;
    final change = (current - previous) * 100 / previous;
    final sign = change < 0 ? '' : '+';
    return '$sign${change.toStringAsFixed(1)}%';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final previous = view.previous;
    // IntrinsicHeight is required, not decorative: `stretch` asks children to
    // fill the cross axis, and inside a ListView the row's height is unbounded
    // — the tall tile then gets an infinite constraint and the whole page
    // fails to lay out. Same shape as the dashboard's stats row.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: _Tile(
              label: l10n.reportNetSales,
              value: MoneyFormatter.format(report.netSales),
              detail: previous == null
                  ? null
                  : _delta(context, report.netSales, previous.netSales),
              big: true,
            ),
          ),
          const SizedBox(width: AppDimensions.space10),
          Expanded(
            child: Column(
              children: [
                _Tile(
                  label: l10n.reportOrders,
                  value: '${report.orderCount}',
                  detail: previous == null
                      ? null
                      : _delta(context, report.orderCount, previous.orderCount),
                ),
                const SizedBox(height: AppDimensions.space10),
                _Tile(
                  label: l10n.reportAverage,
                  value: MoneyFormatter.compact(report.averageOrder),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.value,
    this.detail,
    this.big = false,
  });
  final String label;
  final String value;

  /// A second line under the value — the comparison against the previous
  /// period. Null draws nothing rather than an empty row.
  final String? detail;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return GlassCard.solid(
      padding: const EdgeInsets.all(AppDimensions.space14),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(color: design.textMedium, fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: TextStyle(
                  color: design.textHigh,
                  fontSize: big ? 26 : 18,
                  fontWeight: FontWeight.w900,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 2),
              Text(
                detail!,
                style: TextStyle(color: design.textLow, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppDimensions.space8),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: design.textHigh,
            ),
          ),
        ),
        GlassCard.solid(child: child),
      ],
    );
  }
}

class _BucketSection extends StatelessWidget {
  const _BucketSection({
    required this.title,
    required this.buckets,
    required this.labelFor,
    required this.total,
  });

  final String title;
  final Map<String, ReportBucket> buckets;
  final String Function(String key) labelFor;
  final int total;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    if (buckets.isEmpty) return const SizedBox.shrink();

    return _Section(
      title: title,
      child: Column(
        children: [
          for (final e in buckets.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimensions.space10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          labelFor(e.key),
                          style: TextStyle(
                            color: design.textHigh,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Text(
                        '${e.value.count}',
                        style: TextStyle(color: design.textLow, fontSize: 12),
                      ),
                      const SizedBox(width: AppDimensions.space10),
                      Text(
                        MoneyFormatter.format(e.value.amount),
                        style: TextStyle(
                          color: design.textHigh,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Share of revenue as a bar: a column of numbers hides which
                  // channel actually carries the business.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppDimensions.radius4),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : e.value.amount / total,
                      minHeight: 4,
                      backgroundColor: design.primary.withValues(alpha: 0.12),
                      valueColor: AlwaysStoppedAnimation(design.primary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Sales by category, pre-tax and pre-service-charge. Grouped by category ID
/// rather than name (see `SalesReport.byCategory`), so renaming a category
/// mid-range still reads as one row instead of splitting the history in two.
/// The caveat matters for the same reason `_ProfitSection`'s does:
/// [CategorySales.netSales] summed across every row reconciles to Subtotal
/// minus Discount, not to [SalesReport.revenue] (which includes both PB1 and
/// Service Charge) — reading it as the latter makes the two sections look
/// contradictory when they are not.
class _ServerBrandSection extends StatelessWidget {
  const _ServerBrandSection({required this.lines});
  final List<ServerCategoryLine> lines;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return _Section(
      title: context.l10n.reportByBrand,
      child: Column(
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimensions.space10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      line.label,
                      style: TextStyle(
                        color: design.textHigh,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${line.items}',
                    style: TextStyle(color: design.textLow),
                  ),
                  const SizedBox(width: AppDimensions.space10),
                  Text(
                    MoneyFormatter.format(line.netSales),
                    style: TextStyle(
                      color: design.textHigh,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({required this.report});
  final SalesReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    if (report.byCategory.isEmpty) return const SizedBox.shrink();

    return _Section(
      title: l10n.reportByCategory,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in report.byCategory)
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimensions.space10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          c.categoryName.isEmpty
                              ? l10n.reportUncategorized
                              : c.categoryName,
                          style: TextStyle(
                            color: design.textHigh,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Text(
                        '${c.itemsSold}',
                        style: TextStyle(color: design.textLow, fontSize: 12),
                      ),
                      const SizedBox(width: AppDimensions.space10),
                      Text(
                        MoneyFormatter.format(c.netSales),
                        style: TextStyle(
                          color: design.textHigh,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        l10n.reportGrossSales,
                        style: TextStyle(color: design.textLow, fontSize: 11),
                      ),
                      Text(
                        MoneyFormatter.format(c.grossSales),
                        style: TextStyle(color: design.textLow, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Share of net sales as a bar, same visual language as the
                  // other breakdowns — the number beside it is the exact
                  // contribution %, the bar is the at-a-glance read.
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            AppDimensions.radius4,
                          ),
                          child: LinearProgressIndicator(
                            value: c.contributionPercent / 100,
                            minHeight: 4,
                            backgroundColor: design.primary.withValues(
                              alpha: 0.12,
                            ),
                            valueColor: AlwaysStoppedAnimation(design.primary),
                          ),
                        ),
                      ),
                      const SizedBox(width: AppDimensions.space10),
                      Text(
                        '${c.contributionPercent.toStringAsFixed(1)}%',
                        style: TextStyle(
                          color: design.textLow,
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 14, color: design.textLow),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.reportCategoryCaveat,
                  style: TextStyle(fontSize: 11, color: design.textLow),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DailySection extends StatelessWidget {
  const _DailySection({required this.report});
  final SalesReport report;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final design = context.design;
    final days = report.perDay.keys.toList()..sort();
    if (days.isEmpty) return const SizedBox.shrink();
    final max = report.perDay.values.reduce((a, b) => a > b ? a : b);

    return _Section(
      title: l10n.reportDaily,
      child: Column(
        children: [
          for (final d in days)
            Padding(
              padding: const EdgeInsets.only(bottom: AppDimensions.space8),
              child: Row(
                children: [
                  SizedBox(
                    width: 62,
                    child: Text(
                      DateFormat('d MMM').format(d),
                      style: TextStyle(color: design.textMedium, fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        AppDimensions.radius4,
                      ),
                      child: LinearProgressIndicator(
                        value: max == 0 ? 0 : report.perDay[d]! / max,
                        minHeight: 8,
                        backgroundColor: design.primary.withValues(alpha: 0.12),
                        valueColor: AlwaysStoppedAnimation(design.primary),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppDimensions.space10),
                  Text(
                    MoneyFormatter.compact(report.perDay[d]!),
                    style: TextStyle(
                      color: design.textHigh,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow({
    required this.label,
    required this.value,
    this.bold = false,
  });
  final String label;
  final int value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: design.textMedium, fontSize: 13)),
          Text(
            MoneyFormatter.format(value),
            style: TextStyle(
              color: design.textHigh,
              fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
              fontSize: bold ? 16 : 13,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlainRow extends StatelessWidget {
  const _PlainRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final design = context.design;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: design.textMedium, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              color: design.textHigh,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Names a sales-type bucket of a report. The three built-in wire types are
/// translated; anything else is already a name — a merchant's own type
/// ("GoFood"), or the label the server gave it — and is shown as it is.
@visibleForTesting
String salesTypeLabel(AppLocalizations l10n, String key) => switch (key) {
  'dineIn' => l10n.posDineIn,
  'takeaway' => l10n.posTakeaway,
  'delivery' => l10n.posDelivery,
  'custom' => l10n.posSalesTypeCustom,
  _ => key,
};
