<?php

declare(strict_types=1);

use App\Domain\Reporting\CategorySales;
use App\Domain\Reporting\CategorySalesAggregator;

/**
 * The discount split, as pure logic over raw rows.
 *
 * A port of the device's `order_repository_report_test.dart`. Kept without a
 * database on purpose: the Dart original shipped two bugs that only tests at
 * this level caught — net computed as the discount SHARE rather than gross
 * minus it, and a name-resolution guard that stopped a newer snapshot name from
 * replacing an older one.
 */
function row(array $overrides = []): array
{
    return array_merge([
        'order_id' => 'o1',
        'order_discount' => 0,
        'order_subtotal' => 10000,
        'order_placed_at' => 1000,
        'category_id' => 'cat_food',
        'snapshot_name' => 'Makanan',
        'live_name' => 'Makanan',
        'line_total' => 10000,
        'qty' => 1,
    ], $overrides);
}

function aggregate(array $rows): array
{
    return (new CategorySalesAggregator)->aggregate($rows);
}

// ------------------------------------------------------------------- money

it('carries a single order straight through', function () {
    $out = aggregate([row()]);

    expect($out)->toHaveCount(1)
        ->and($out[0]->grossSales)->toBe(10000)
        ->and($out[0]->netSales)->toBe(10000)
        ->and($out[0]->itemsSold)->toBe(1)
        ->and($out[0]->contributionPercent)->toBe(100.0);
});

it('leaves gross equal to net when nothing was discounted', function () {
    $out = aggregate([row(['line_total' => 25000, 'order_subtotal' => 25000])]);

    expect($out[0]->grossSales)->toBe($out[0]->netSales);
});

it('splits a discount in proportion to each category share', function () {
    $out = aggregate([
        row(['category_id' => 'food', 'line_total' => 10000, 'order_subtotal' => 30000, 'order_discount' => 3000]),
        row(['category_id' => 'drinks', 'line_total' => 20000, 'order_subtotal' => 30000, 'order_discount' => 3000]),
    ]);

    $byId = collect($out)->keyBy('categoryId');
    expect($byId['food']->netSales)->toBe(9000)
        ->and($byId['drinks']->netSales)->toBe(18000);
});

it('accounts for every rupiah of a discount that does not divide evenly', function () {
    // Three categories at 10000 on a 30000 subtotal, discount 100. Each floors
    // to 33, summing to 99 — the missing rupiah is the whole reason
    // largest-remainder exists rather than plain division.
    $out = aggregate([
        row(['category_id' => 'a', 'line_total' => 10000, 'order_subtotal' => 30000, 'order_discount' => 100]),
        row(['category_id' => 'b', 'line_total' => 10000, 'order_subtotal' => 30000, 'order_discount' => 100]),
        row(['category_id' => 'c', 'line_total' => 10000, 'order_subtotal' => 30000, 'order_discount' => 100]),
    ]);

    expect(array_sum(array_map(fn ($c) => $c->netSales, $out)))->toBe(30000 - 100)
        ->and(array_sum(array_map(fn ($c) => $c->grossSales, $out)))->toBe(30000);
});

it('reconciles each order independently across several orders', function () {
    $out = aggregate([
        row(['order_id' => 'o1', 'category_id' => 'food', 'line_total' => 10000, 'order_subtotal' => 10000, 'order_discount' => 1000]),
        row(['order_id' => 'o2', 'category_id' => 'food', 'line_total' => 20000, 'order_subtotal' => 20000, 'order_discount' => 2000]),
    ]);

    expect($out[0]->grossSales)->toBe(30000)
        ->and($out[0]->netSales)->toBe(27000);
});

it('never divides by zero on an order with no subtotal', function () {
    $out = aggregate([row(['line_total' => 0, 'order_subtotal' => 0, 'order_discount' => 0])]);

    expect($out)->toHaveCount(1)
        ->and($out[0]->netSales)->toBe(0);
});

it('reports zero contribution rather than dividing by zero net', function () {
    $out = aggregate([row(['line_total' => 0, 'order_subtotal' => 0])]);

    expect($out[0]->contributionPercent)->toBe(0.0);
});

it('sorts by net sales, largest first', function () {
    $out = aggregate([
        row(['category_id' => 'small', 'line_total' => 5000, 'order_subtotal' => 25000]),
        row(['category_id' => 'big', 'line_total' => 20000, 'order_subtotal' => 25000]),
    ]);

    expect($out[0]->categoryId)->toBe('big')
        ->and($out[1]->categoryId)->toBe('small');
});

// --------------------------------------------------- grouping and naming

it('groups by id, so a rename mid-range stays one row', function () {
    $out = aggregate([
        row(['order_id' => 'o1', 'snapshot_name' => 'Makanan', 'live_name' => 'Makanan Utama']),
        row(['order_id' => 'o2', 'snapshot_name' => 'Makanan Utama', 'live_name' => 'Makanan Utama']),
    ]);

    expect($out)->toHaveCount(1)
        ->and($out[0]->name)->toBe('Makanan Utama');
});

it('keeps two categories that happen to share a name apart', function () {
    $out = aggregate([
        row(['category_id' => 'a', 'snapshot_name' => 'Es Teh', 'live_name' => 'Es Teh']),
        row(['category_id' => 'b', 'snapshot_name' => 'Es Teh', 'live_name' => 'Es Teh']),
    ]);

    expect($out)->toHaveCount(2);
});

it('falls back to the newest snapshot name for a deleted category', function () {
    // Rows arrive oldest-first, so an implementation that keeps the first name
    // it sees shows the stale one. That was a real bug in the Dart version.
    $out = aggregate([
        row(['order_id' => 'o1', 'order_placed_at' => 1000, 'snapshot_name' => 'Lama', 'live_name' => null]),
        row(['order_id' => 'o2', 'order_placed_at' => 2000, 'snapshot_name' => 'Baru', 'live_name' => null]),
    ]);

    expect($out[0]->name)->toBe('Baru');
});

it('lets a live name win over any snapshot', function () {
    $out = aggregate([
        row(['order_id' => 'o1', 'order_placed_at' => 2000, 'snapshot_name' => 'Snapshot', 'live_name' => null]),
        row(['order_id' => 'o2', 'order_placed_at' => 1000, 'snapshot_name' => 'Older', 'live_name' => 'Live']),
    ]);

    expect($out[0]->name)->toBe('Live');
});

it('buckets a line with no category at all', function () {
    $out = aggregate([row(['category_id' => null, 'snapshot_name' => null, 'live_name' => null])]);

    // Left with an empty name for the UI to localise, the same way the device
    // keeps wire keys untranslated.
    expect($out[0]->categoryId)->toBe(CategorySales::UNCATEGORISED_ID)
        ->and($out[0]->name)->toBe('');
});

it('keeps the uncategorised bucket separate from a real category', function () {
    $out = aggregate([
        row(['category_id' => 'food', 'line_total' => 10000, 'order_subtotal' => 20000]),
        row(['category_id' => null, 'live_name' => null, 'snapshot_name' => null, 'line_total' => 10000, 'order_subtotal' => 20000]),
    ]);

    expect($out)->toHaveCount(2);
});

it('returns nothing for no rows rather than failing', function () {
    expect(aggregate([]))->toBe([]);
});
