<?php

declare(strict_types=1);

namespace App\Domain\Reporting;

use App\Domain\Orders\OrderStatus;
use App\Models\Order;
use Carbon\CarbonInterface;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\DB;

/**
 * The sales report, across one outlet or the whole chain.
 *
 * A port of the device's `OrderRepository.report()`. Two rules carry over and
 * are the only things here that are easy to get wrong:
 *
 * **Never join `order_items` in a total.** The join fans each order into one
 * row per line, so every `SUM` over `orders` is multiplied by the number of
 * lines. The figures still look plausible — just too big — which is why this is
 * the mistake to guard rather than to notice later.
 *
 * **Every aggregate carries the same revenue filter.** `Order::scopeRevenue()`,
 * always. Six queries excluding refunds and a seventh that does not is a set of
 * columns that quietly fails to add up.
 *
 * `outletId: null` means the whole chain, deliberately — that is how an owner
 * compares branches.
 */
class SalesReporter
{
    public function __construct(private readonly CategorySalesAggregator $categories) {}

    /**
     * @return array<string, mixed>
     */
    public function report(
        CarbonInterface $from,
        CarbonInterface $to,
        ?string $outletId = null,
    ): array {
        // `to` is inclusive of its whole day: a report "1st to 7th" that stopped
        // at midnight on the 7th would silently omit the 7th's takings.
        $start = $from->copy()->startOfDay();
        $end = $to->copy()->startOfDay()->addDay();

        $totals = $this->totals($start, $end, $outletId);
        $items = $this->itemTotals($start, $end, $outletId);

        return [
            'from' => $start->toIso8601String(),
            'to' => $end->toIso8601String(),
            'outlet_id' => $outletId,

            'revenue' => $totals->revenue,
            'subtotal' => $totals->subtotal,
            'discount' => $totals->discount,
            'tax' => $totals->tax,
            'service_charge' => $totals->service_charge,
            'order_count' => $totals->order_count,
            'average_order' => $totals->order_count > 0
                ? intdiv((int) $totals->revenue, (int) $totals->order_count)
                : 0,

            'items_sold' => (int) $items->items,
            'cost_of_goods' => (int) $items->cogs,
            'gross_profit' => (int) $totals->revenue - (int) $items->cogs,

            // What fraction of the items sold actually carried a cost. Without
            // it, a half-costed catalogue reports a margin that looks excellent
            // and means nothing.
            'cost_coverage' => (int) $items->items > 0
                ? (int) $items->costed_items / (int) $items->items
                : 0.0,

            'by_payment' => $this->groupedBy('payment_method', $start, $end, $outletId),
            'by_type' => $this->groupedBy('type', $start, $end, $outletId),
            'by_cashier' => $this->byCashier($start, $end, $outletId),
            'by_outlet' => $this->byOutlet($start, $end, $outletId),
            'daily' => $this->daily($start, $end, $outletId),
            'by_category' => array_map(
                fn (CategorySales $c): array => $c->toArray(),
                $this->categories->aggregate($this->categoryRows($start, $end, $outletId)),
            ),
            'undone' => $this->undone($start, $end, $outletId),
        ];
    }

    private function base(CarbonInterface $start, CarbonInterface $end, ?string $outletId): Builder
    {
        return Order::query()
            ->revenue()
            ->where('placed_at', '>=', $start)
            ->where('placed_at', '<', $end)
            ->when($outletId !== null, fn (Builder $q) => $q->where('outlet_id', $outletId));
    }

    private function totals(CarbonInterface $start, CarbonInterface $end, ?string $outletId): object
    {
        // No join to `order_items` — see the class note.
        return $this->base($start, $end, $outletId)
            ->selectRaw('
                COALESCE(SUM(total), 0)                 AS revenue,
                COALESCE(SUM(subtotal), 0)              AS subtotal,
                COALESCE(SUM(discount), 0)              AS discount,
                COALESCE(SUM(tax), 0)                   AS tax,
                COALESCE(SUM(service_charge_amount), 0) AS service_charge,
                COUNT(*)                                AS order_count
            ')
            ->first();
    }

    private function itemTotals(CarbonInterface $start, CarbonInterface $end, ?string $outletId): object
    {
        return $this->base($start, $end, $outletId)
            ->join('order_items', 'order_items.order_id', '=', 'orders.id')
            ->selectRaw('
                COALESCE(SUM(order_items.quantity), 0) AS items,
                COALESCE(SUM(COALESCE(order_items.unit_cost, 0) * order_items.quantity), 0) AS cogs,
                COALESCE(SUM(CASE WHEN order_items.unit_cost IS NULL THEN 0 ELSE order_items.quantity END), 0) AS costed_items
            ')
            ->first();
    }

    /** @return list<array<string, mixed>> */
    private function groupedBy(string $column, CarbonInterface $start, CarbonInterface $end, ?string $outletId): array
    {
        return $this->base($start, $end, $outletId)
            ->selectRaw("{$column} AS k, SUM(total) AS v, COUNT(*) AS c")
            ->groupBy($column)
            ->orderByDesc('v')
            ->get()
            ->map(fn ($r): array => [
                'key' => $r->k,
                'value' => (int) $r->v,
                'count' => (int) $r->c,
            ])
            ->all();
    }

    /** @return list<array<string, mixed>> */
    private function byCashier(CarbonInterface $start, CarbonInterface $end, ?string $outletId): array
    {
        // Grouped by id, labelled by the snapshot name — so a cashier who has
        // since been renamed still reads correctly, and two people who happen
        // to share a name stay two rows.
        return $this->base($start, $end, $outletId)
            ->selectRaw('cashier_id, MAX(cashier_name) AS k, SUM(total) AS v, COUNT(*) AS c')
            ->groupBy('cashier_id')
            ->orderByDesc('v')
            ->get()
            ->map(fn ($r): array => [
                'key' => $r->k,
                'value' => (int) $r->v,
                'count' => (int) $r->c,
            ])
            ->all();
    }

    /**
     * Per branch — the figure a chain owner opens the report for.
     *
     * Present even when the report is already narrowed to one outlet, so the
     * shape of the response never depends on the filter.
     *
     * @return list<array<string, mixed>>
     */
    private function byOutlet(CarbonInterface $start, CarbonInterface $end, ?string $outletId): array
    {
        return $this->base($start, $end, $outletId)
            ->selectRaw('outlet_id, MAX(outlet_name) AS k, SUM(total) AS v, COUNT(*) AS c')
            ->groupBy('outlet_id')
            ->orderByDesc('v')
            ->get()
            ->map(fn ($r): array => [
                'outlet_id' => $r->outlet_id,
                'key' => $r->k,
                'value' => (int) $r->v,
                'count' => (int) $r->c,
            ])
            ->all();
    }

    /** @return list<array<string, mixed>> */
    private function daily(CarbonInterface $start, CarbonInterface $end, ?string $outletId): array
    {
        return $this->base($start, $end, $outletId)
            ->selectRaw('DATE(placed_at) AS day, SUM(total) AS v, COUNT(*) AS c')
            ->groupBy('day')
            ->orderBy('day')
            ->get()
            ->map(fn ($r): array => [
                'day' => (string) $r->day,
                'value' => (int) $r->v,
                'count' => (int) $r->c,
            ])
            ->all();
    }

    /**
     * Rows for the category split.
     *
     * One row per (order, category). No join to `products`: the category is
     * already snapshotted onto the line, so a deleted product cannot take its
     * own history off the report.
     *
     * @return list<array<string, mixed>>
     */
    private function categoryRows(CarbonInterface $start, CarbonInterface $end, ?string $outletId): array
    {
        return $this->base($start, $end, $outletId)
            ->join('order_items', 'order_items.order_id', '=', 'orders.id')
            ->leftJoin('categories', 'categories.id', '=', 'order_items.category_id')
            ->selectRaw('
                orders.id        AS order_id,
                orders.discount  AS order_discount,
                orders.subtotal  AS order_subtotal,
                orders.placed_at AS order_placed_at,
                order_items.category_id     AS category_id,
                order_items.category_name   AS snapshot_name,
                categories.name             AS live_name,
                SUM(order_items.unit_price * order_items.quantity) AS line_total,
                SUM(order_items.quantity)                          AS qty
            ')
            ->groupBy(
                'orders.id', 'orders.discount', 'orders.subtotal', 'orders.placed_at',
                'order_items.category_id', 'order_items.category_name', 'categories.name',
            )
            ->get()
            ->map(fn ($r): array => [
                'order_id' => $r->order_id,
                'order_discount' => (int) $r->order_discount,
                'order_subtotal' => (int) $r->order_subtotal,
                'order_placed_at' => strtotime((string) $r->order_placed_at),
                'category_id' => $r->category_id,
                'snapshot_name' => $r->snapshot_name,
                'live_name' => $r->live_name,
                'line_total' => (int) $r->line_total,
                'qty' => (int) $r->qty,
            ])
            ->all();
    }

    /**
     * What was undone in the window.
     *
     * The ONE query that deliberately does not use the revenue filter — these
     * are exactly the rows it excludes, and a manager needs to see them.
     *
     * @return list<array<string, mixed>>
     */
    private function undone(CarbonInterface $start, CarbonInterface $end, ?string $outletId): array
    {
        return Order::query()
            ->whereIn('status', [OrderStatus::Cancelled->value, OrderStatus::Refunded->value])
            ->where('placed_at', '>=', $start)
            ->where('placed_at', '<', $end)
            ->when($outletId !== null, fn (Builder $q) => $q->where('outlet_id', $outletId))
            ->selectRaw('status AS k, SUM(COALESCE(refunded_amount, total)) AS v, COUNT(*) AS c')
            ->groupBy('status')
            ->get()
            ->map(fn ($r): array => [
                'key' => $r->k,
                'value' => (int) $r->v,
                'count' => (int) $r->c,
            ])
            ->all();
    }

    /** Revenue, order count and items sold for one day — the dashboard tiles. */
    public function summaryForDay(CarbonInterface $day, ?string $outletId = null): array
    {
        $report = $this->report($day, $day, $outletId);

        return [
            'revenue' => $report['revenue'],
            'order_count' => $report['order_count'],
            'items_sold' => $report['items_sold'],
        ];
    }

    /**
     * Best sellers over a window.
     *
     * @return list<array<string, mixed>>
     */
    public function topProducts(
        CarbonInterface $from,
        CarbonInterface $to,
        ?string $outletId = null,
        int $limit = 5,
    ): array {
        return $this->base($from->copy()->startOfDay(), $to->copy()->startOfDay()->addDay(), $outletId)
            ->join('order_items', 'order_items.order_id', '=', 'orders.id')
            ->selectRaw('
                order_items.product_id,
                MAX(order_items.product_name) AS name,
                SUM(order_items.quantity) AS qty,
                SUM(order_items.unit_price * order_items.quantity) AS revenue
            ')
            ->groupBy('order_items.product_id')
            ->orderByDesc(DB::raw('SUM(order_items.quantity)'))
            ->limit($limit)
            ->get()
            ->map(fn ($r): array => [
                'product_id' => $r->product_id,
                'name' => $r->name,
                'qty' => (int) $r->qty,
                'revenue' => (int) $r->revenue,
            ])
            ->all();
    }
}
