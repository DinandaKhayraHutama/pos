<?php

declare(strict_types=1);

namespace App\Domain\Reporting;

/**
 * Splits each order's discount across the categories it touched.
 *
 * A port of the device's `aggregateCategorySales`, kept as pure logic over raw
 * rows so it can be tested without a database — the Dart original shipped two
 * bugs that only its unit tests caught, and both are re-guarded here.
 *
 * ## Why largest-remainder rather than plain division
 *
 * Allocating `discount × lineTotal / subtotal` per category and flooring leaves
 * a remainder of up to `(categories in that order − 1)` rupiah unaccounted for,
 * every order. Over a month that drifts, and the category breakdown stops
 * reconciling to `subtotal − discount` — a report whose columns do not add up,
 * with no error anywhere to say so.
 *
 * So the floors are summed, the leftover is handed whole to the category with
 * the largest line total in that order, and ties break on category id so the
 * result is deterministic. `Σ netSales` then reconciles EXACTLY.
 */
class CategorySalesAggregator
{
    /**
     * @param  iterable<array<string, mixed>>  $rows  one row per (order, category)
     * @return list<CategorySales>
     */
    public function aggregate(iterable $rows): array
    {
        /** @var array<string, list<array<string, mixed>>> $byOrder */
        $byOrder = [];
        foreach ($rows as $row) {
            $byOrder[(string) $row['order_id']][] = $row;
        }

        $gross = [];
        $net = [];
        $items = [];

        foreach ($byOrder as $orderRows) {
            $first = $orderRows[0];
            $discount = (int) ($first['order_discount'] ?? 0);
            $subtotal = (int) ($first['order_subtotal'] ?? 0);

            $shares = $this->allocate($orderRows, $discount, $subtotal);

            foreach ($orderRows as $index => $row) {
                $key = $this->keyOf($row);
                $lineTotal = (int) $row['line_total'];

                $gross[$key] = ($gross[$key] ?? 0) + $lineTotal;
                // Gross MINUS the share — not the share itself. That inversion
                // was one of the two bugs the Dart version shipped.
                $net[$key] = ($net[$key] ?? 0) + ($lineTotal - $shares[$index]);
                $items[$key] = ($items[$key] ?? 0) + (int) $row['qty'];
            }
        }

        $names = $this->resolveNames($byOrder);
        $totalNet = array_sum($net);

        $out = [];
        foreach ($gross as $key => $grossSales) {
            $out[] = new CategorySales(
                categoryId: $key,
                name: $names[$key] ?? '',
                grossSales: $grossSales,
                netSales: $net[$key],
                itemsSold: $items[$key],
                contributionPercent: $totalNet === 0
                    ? 0.0
                    : ($net[$key] * 100) / $totalNet,
            );
        }

        usort($out, fn (CategorySales $a, CategorySales $b) => $b->netSales <=> $a->netSales);

        return $out;
    }

    /**
     * The discount each row of one order carries.
     *
     * @param  list<array<string, mixed>>  $orderRows
     * @return list<int>
     */
    private function allocate(array $orderRows, int $discount, int $subtotal): array
    {
        $shares = [];
        $allocated = 0;

        foreach ($orderRows as $row) {
            // `subtotal == 0` implies `discount == 0`, because the cart clamps a
            // discount to what there is to discount. Guarded anyway: dividing
            // by zero here would take down a whole report.
            $share = $subtotal === 0
                ? 0
                : intdiv($discount * (int) $row['line_total'], $subtotal);

            $shares[] = $share;
            $allocated += $share;
        }

        $remainder = $discount - $allocated;
        if ($remainder === 0 || $orderRows === []) {
            return $shares;
        }

        // The whole remainder goes to one row: the largest line total, ties
        // broken by category id so two runs over the same data agree.
        $winner = 0;
        foreach ($orderRows as $index => $row) {
            $best = $orderRows[$winner];
            $isLarger = (int) $row['line_total'] > (int) $best['line_total'];
            $isTieAndSorts = (int) $row['line_total'] === (int) $best['line_total']
                && strcmp($this->keyOf($row), $this->keyOf($best)) < 0;

            if ($isLarger || $isTieAndSorts) {
                $winner = $index;
            }
        }

        $shares[$winner] += $remainder;

        return $shares;
    }

    /**
     * What to call each category.
     *
     * The live name always wins and closes the key off; otherwise the NEWEST
     * snapshot name is used, and an older one must never overwrite a newer one.
     * That ordering guard was the second bug the Dart version shipped: a
     * deleted category was showing whichever name happened to be read first.
     *
     * @param  array<string, list<array<string, mixed>>>  $byOrder
     * @return array<string, string>
     */
    private function resolveNames(array $byOrder): array
    {
        $names = [];
        $liveResolved = [];
        $newestAt = [];

        foreach ($byOrder as $orderRows) {
            foreach ($orderRows as $row) {
                $key = $this->keyOf($row);

                if (! empty($row['live_name'])) {
                    $names[$key] = (string) $row['live_name'];
                    $liveResolved[$key] = true;

                    continue;
                }

                if (($liveResolved[$key] ?? false) || empty($row['snapshot_name'])) {
                    continue;
                }

                $at = (int) ($row['order_placed_at'] ?? 0);
                if (! isset($newestAt[$key]) || $at >= $newestAt[$key]) {
                    $names[$key] = (string) $row['snapshot_name'];
                    $newestAt[$key] = $at;
                }
            }
        }

        return $names;
    }

    /**
     * Grouped by category ID, never by name.
     *
     * A category renamed mid-range must stay ONE continuous bucket, and two
     * different categories that happen to share a name must stay two rows.
     */
    private function keyOf(array $row): string
    {
        $id = $row['category_id'] ?? null;

        return ($id === null || $id === '')
            ? CategorySales::UNCATEGORISED_ID
            : (string) $id;
    }
}
