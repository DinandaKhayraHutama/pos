<?php

declare(strict_types=1);

use App\Domain\Reporting\SalesReporter;
use App\Models\Employee;
use App\Models\Order;
use App\Models\OrderItem;
use App\Models\Outlet;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Str;

/**
 * The sales report, against a real database.
 *
 * The aggregator's arithmetic has its own unit tests; what these cover is the
 * SQL around it — above all the fan-out trap, where joining `order_items` into
 * a total multiplies every sum by the number of lines and produces figures that
 * look plausible and are simply too big.
 */
beforeEach(function () {
    $this->context = app(TenantContext::class);
    $this->reporter = app(SalesReporter::class);

    $this->tenant = Tenant::create(['name' => 'Warung A', 'slug' => 'warung-a']);
    Employee::factory()->owner()->create([
        'tenant_id' => $this->tenant->id, 'email' => 'a@example.test',
    ]);
    $this->context->set($this->tenant);

    $this->bintaro = Outlet::create(['name' => 'Bintaro']);
    $this->kemang = Outlet::create(['name' => 'Kemang']);
});

afterEach(fn () => $this->context->clear());

function sale(array $overrides = [], array $lines = []): Order
{
    $order = new Order;
    $order->forceFill(array_merge([
        'id' => (string) Str::uuid(),
        'tenant_id' => test()->tenant->id,
        'outlet_id' => test()->bintaro->id,
        'outlet_name' => 'Bintaro',
        'number' => 'K1-0001',
        'placed_at' => now(),
        'type' => 'dineIn',
        'status' => 'paid',
        'subtotal' => 30000,
        'discount' => 0,
        'tax' => 3000,
        'service_charge_amount' => 0,
        'total' => 33000,
        'amount_paid' => 33000,
        'payment_method' => 'cash',
        'cashier_id' => '11111111-1111-4111-8111-111111111111',
        'cashier_name' => 'Siti',
    ], $overrides));
    $order->save();

    foreach ($lines ?: [['unit_price' => 15000, 'quantity' => 2, 'unit_cost' => 7000]] as $line) {
        $item = new OrderItem;
        $item->forceFill(array_merge([
            'id' => (string) Str::uuid(),
            'tenant_id' => test()->tenant->id,
            'order_id' => $order->id,
            'product_id' => (string) Str::uuid(),
            'product_name' => 'Nasi Goreng',
            'category_id' => null,
            'category_name' => 'Makanan',
        ], $line));
        $item->save();
    }

    return $order;
}

// ------------------------------------------------------------ the fan-out

it('does not multiply revenue by the number of lines', function () {
    // One 33000 sale with three lines. A total that joins order_items reports
    // 99000 — plausible-looking, and wrong.
    sale(lines: [
        ['unit_price' => 10000, 'quantity' => 1],
        ['unit_price' => 10000, 'quantity' => 1],
        ['unit_price' => 10000, 'quantity' => 1],
    ]);

    $report = $this->reporter->report(now(), now());

    expect((int) $report['revenue'])->toBe(33000)
        ->and((int) $report['order_count'])->toBe(1);
});

it('still counts items across every line', function () {
    sale(lines: [
        ['unit_price' => 10000, 'quantity' => 2],
        ['unit_price' => 10000, 'quantity' => 3],
    ]);

    expect($this->reporter->report(now(), now())['items_sold'])->toBe(5);
});

// ------------------------------------------------------------ what counts

it('excludes voided and refunded sales from revenue', function () {
    sale();
    sale(['status' => 'cancelled']);
    sale(['status' => 'refunded']);

    $report = $this->reporter->report(now(), now());

    expect((int) $report['revenue'])->toBe(33000)
        ->and((int) $report['order_count'])->toBe(1);
});

it('reports what was undone separately', function () {
    sale(['status' => 'cancelled']);
    sale(['status' => 'refunded', 'refunded_amount' => 20000]);

    // The one query that deliberately ignores the revenue filter: a manager has
    // to see exactly what it excluded.
    $undone = collect($this->reporter->report(now(), now())['undone'])->keyBy('key');

    expect($undone['cancelled']['value'])->toBe(33000)
        ->and($undone['refunded']['value'])->toBe(20000);
});

// ------------------------------------------------------------ the window

it('includes the whole of the closing day', function () {
    sale(['placed_at' => now()->startOfDay()->addHours(23)->addMinutes(59)]);

    // A window that stopped at midnight on the closing day would silently drop
    // that day's evening trade.
    expect((int) $this->reporter->report(now(), now())['revenue'])->toBe(33000);
});

it('leaves out sales from before the window', function () {
    sale(['placed_at' => now()->subDays(3)]);

    expect((int) $this->reporter->report(now(), now())['revenue'])->toBe(0);
});

// ------------------------------------------------------- across the chain

it('sums every branch when no outlet is named', function () {
    sale(['outlet_id' => $this->bintaro->id, 'outlet_name' => 'Bintaro']);
    sale(['outlet_id' => $this->kemang->id, 'outlet_name' => 'Kemang']);

    // `outletId: null` means the whole chain, deliberately — that is how an
    // owner compares branches.
    expect((int) $this->reporter->report(now(), now())['revenue'])->toBe(66000);
});

it('narrows to one branch when asked', function () {
    sale(['outlet_id' => $this->bintaro->id, 'outlet_name' => 'Bintaro']);
    sale(['outlet_id' => $this->kemang->id, 'outlet_name' => 'Kemang']);

    $report = $this->reporter->report(now(), now(), $this->bintaro->id);

    expect((int) $report['revenue'])->toBe(33000);
});

it('breaks the chain down per branch', function () {
    sale(['outlet_id' => $this->bintaro->id, 'outlet_name' => 'Bintaro']);
    sale(['outlet_id' => $this->kemang->id, 'outlet_name' => 'Kemang', 'total' => 50000]);

    $byOutlet = collect($this->reporter->report(now(), now())['by_outlet'])->keyBy('key');

    expect($byOutlet)->toHaveCount(2)
        ->and($byOutlet['Kemang']['value'])->toBe(50000)
        ->and($byOutlet['Bintaro']['value'])->toBe(33000);
});

// ------------------------------------------------------------- breakdowns

it('splits by payment method', function () {
    sale(['payment_method' => 'cash']);
    sale(['payment_method' => 'qris', 'total' => 20000]);

    $byPayment = collect($this->reporter->report(now(), now())['by_payment'])->keyBy('key');

    expect($byPayment['cash']['value'])->toBe(33000)
        ->and($byPayment['qris']['value'])->toBe(20000);
});

it('groups cashiers by id and labels them by name', function () {
    sale(['cashier_id' => '11111111-1111-4111-8111-111111111111', 'cashier_name' => 'Siti']);
    sale(['cashier_id' => '11111111-1111-4111-8111-111111111111', 'cashier_name' => 'Siti Rahayu']);

    // A renamed cashier stays one row rather than splitting their day in two.
    $byCashier = $this->reporter->report(now(), now())['by_cashier'];

    expect($byCashier)->toHaveCount(1)
        ->and($byCashier[0]['value'])->toBe(66000);
});

it('reports cost coverage so a half-costed catalogue is visible', function () {
    sale(lines: [
        ['unit_price' => 10000, 'quantity' => 1, 'unit_cost' => 5000],
        ['unit_price' => 10000, 'quantity' => 1, 'unit_cost' => null],
    ]);

    // Without this, a margin computed over half the items looks excellent and
    // means nothing.
    expect($this->reporter->report(now(), now())['cost_coverage'])->toBe(0.5);
});

it('computes gross profit from the costs it has', function () {
    sale(['total' => 30000], [['unit_price' => 15000, 'quantity' => 2, 'unit_cost' => 7000]]);

    $report = $this->reporter->report(now(), now());

    expect($report['cost_of_goods'])->toBe(14000)
        ->and($report['gross_profit'])->toBe(16000);
});

it('averages the order value without dividing by zero', function () {
    expect($this->reporter->report(now(), now())['average_order'])->toBe(0);
});

// -------------------------------------------------------------- isolation

it('never reports another merchant sales', function () {
    sale();

    $other = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);

    $seen = $this->context->runAs(
        $other,
        fn () => $this->reporter->report(now(), now())['revenue'],
    );

    expect((int) $seen)->toBe(0);
});
