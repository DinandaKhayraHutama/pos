<?php

declare(strict_types=1);

use App\Domain\Devices\DeviceActivation;
use App\Domain\Orders\OrderStatus;
use App\Domain\Sync\OrderIngest;
use App\Models\Device;
use App\Models\Employee;
use App\Models\Order;
use App\Models\OrderItem;
use App\Models\OrderItemModifier;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Sales arriving from a till.
 *
 * These rows are money customers have already handed over, so each case here
 * guards a different way it goes missing: recorded twice, recorded partly, or
 * quietly un-voided by a packet that arrived late.
 */
beforeEach(function () {
    $this->context = app(TenantContext::class);
    $this->ingest = app(OrderIngest::class);

    $this->tenant = Tenant::create(['name' => 'Warung A', 'slug' => 'warung-a']);
    $this->owner = Employee::factory()->owner()->create([
        'tenant_id' => $this->tenant->id, 'email' => 'a@example.test',
    ]);
    $this->context->set($this->tenant);

    $this->outlet = Outlet::create(['name' => 'Pusat']);
    $this->register = PosRegister::create([
        'name' => 'Kasir 1', 'outlet_id' => $this->outlet->id,
    ]);

    $issued = app(DeviceActivation::class)->issue($this->owner, $this->register->id);
    $this->activation = app(DeviceActivation::class)->activate([
        'code' => $issued['code'], 'device_uuid' => (string) Str::uuid(),
    ]);
    $this->device = Device::query()->findOrFail($this->activation['device']['id']);
});

afterEach(fn () => $this->context->clear());

function orderRow(array $overrides = [], array $itemOverrides = []): array
{
    return array_merge([
        'id' => (string) Str::uuid(),
        'number' => 'K1-0001',
        'placed_at' => now()->getTimestampMs(),
        'type' => 'dineIn',
        'status' => 'paid',
        'pos_session_id' => (string) Str::uuid(),
        'subtotal' => 30000,
        'discount' => 0,
        'tax' => 3000,
        'service_charge_amount' => 1500,
        'total' => 34500,
        'amount_paid' => 35000,
        'pb1_rate' => 10.0,
        'service_charge_rate' => 5.0,
        'payment_method' => 'cash',
        'cashier_id' => (string) Str::uuid(),
        'cashier_name' => 'Siti Rahayu',
        'outlet_name' => 'Pusat',
        'pos_name' => 'Kasir 1',
        'items' => [
            array_merge([
                'id' => (string) Str::uuid(),
                'product_id' => (string) Str::uuid(),
                'product_name' => 'Nasi Goreng',
                'unit_price' => 15000,
                'unit_cost' => 7000,
                'quantity' => 2,
                'category_id' => (string) Str::uuid(),
                'category_name' => 'Makanan',
                'modifiers' => [
                    [
                        'id' => (string) Str::uuid(),
                        'group_name' => 'Level Pedas',
                        'option_name' => 'Pedas',
                        'price_delta' => 0,
                    ],
                ],
            ], $itemOverrides),
        ],
    ], $overrides);
}

// -------------------------------------------------------------- never twice

it('records a sale with its lines and modifiers', function () {
    $row = orderRow();

    $result = $this->ingest->ingest($this->device, [$row]);

    expect($result['accepted'])->toBe([$row['id']])
        ->and(Order::query()->count())->toBe(1)
        ->and(OrderItem::query()->count())->toBe(1)
        ->and(OrderItemModifier::query()->count())->toBe(1);
});

it('is idempotent — the same sale three times is recorded once', function () {
    $row = orderRow();

    foreach (range(1, 3) as $ignored) {
        $this->ingest->ingest($this->device, [$row]);
    }

    // A push that timed out after the server committed gets retried. Without
    // this, a flaky connection inflates a merchant's takings.
    expect(Order::query()->count())->toBe(1)
        ->and(OrderItem::query()->count())->toBe(1)
        ->and(OrderItemModifier::query()->count())->toBe(1)
        ->and((int) Order::query()->sum('total'))->toBe(34500);
});

it('never restates what a customer paid', function () {
    $row = orderRow();
    $this->ingest->ingest($this->device, [$row]);

    // A later push claiming a different total must not rewrite the sale. The
    // money is settled the moment it changes hands.
    $this->ingest->ingest($this->device, [
        array_merge($row, ['total' => 999000, 'subtotal' => 900000]),
    ]);

    expect(Order::query()->findOrFail($row['id'])->total)->toBe(34500);
});

// -------------------------------------------------------------- never partly

it('writes the whole sale or none of it', function () {
    // A line with no name fails validation midway through the nested payload.
    $row = orderRow(itemOverrides: ['product_name' => null]);

    $result = $this->ingest->ingest($this->device, [$row]);

    expect($result['rejected'])->toHaveCount(1)
        ->and(Order::query()->count())->toBe(0)
        ->and(OrderItem::query()->count())->toBe(0);
});

it('refuses a sale with no lines at all', function () {
    // A header without lines is a total nobody can explain, and it would pass
    // every check that only looks at `orders`.
    $result = $this->ingest->ingest($this->device, [orderRow(['items' => []])]);

    expect($result['accepted'])->toBeEmpty()
        ->and(Order::query()->count())->toBe(0);
});

it('keeps a bad sale from failing the batch', function () {
    $good = orderRow();
    $bad = orderRow(['total' => 'not-a-number']);

    $result = $this->ingest->ingest($this->device, [$bad, $good]);

    expect($result['accepted'])->toBe([$good['id']])
        ->and($result['rejected'])->toHaveCount(1)
        ->and(Order::query()->count())->toBe(1);
});

// ---------------------------------------------------------- never rolled back

it('accepts a void that arrives after the sale', function () {
    $row = orderRow();
    $this->ingest->ingest($this->device, [$row]);

    $this->ingest->ingest($this->device, [array_merge($row, [
        'status' => 'cancelled',
        'authorized_by' => 'Siwi Wiyono',
        'void_reason' => 'Wrong table',
    ])]);

    $order = Order::query()->findOrFail($row['id']);
    expect($order->status)->toBe(OrderStatus::Cancelled)
        ->and($order->authorized_by)->toBe('Siwi Wiyono')
        ->and($order->void_reason)->toBe('Wrong table');
});

it('does not un-void a sale when a stale packet arrives', function () {
    $row = orderRow();
    $this->ingest->ingest($this->device, [$row]);
    $this->ingest->ingest($this->device, [array_merge($row, [
        'status' => 'cancelled',
        'authorized_by' => 'Siwi Wiyono',
        'void_reason' => 'Wrong table',
    ])]);

    // The device retries an older queued state. Applying it would restore a
    // sale a manager already signed off as cancelled.
    $this->ingest->ingest($this->device, [$row]);

    $order = Order::query()->findOrFail($row['id']);
    expect($order->status)->toBe(OrderStatus::Cancelled)
        ->and($order->authorized_by)->toBe('Siwi Wiyono');
});

it('settles only once when a void arrives twice', function () {
    $row = orderRow();
    $this->ingest->ingest($this->device, [$row]);

    $void = array_merge($row, [
        'status' => 'refunded',
        'authorized_by' => 'Siwi',
        'refunded_amount' => 34500,
    ]);
    $this->ingest->ingest($this->device, [$void]);
    $this->ingest->ingest($this->device, [
        array_merge($void, ['refunded_amount' => 99999]),
    ]);

    // Mirrors the device's `_settle` no-op guard: a double-tap on Void must not
    // credit anything twice.
    expect(Order::query()->findOrFail($row['id'])->refunded_amount)->toBe(34500);
});

it('excludes settled sales from revenue', function () {
    $kept = orderRow();
    $voided = orderRow(['status' => 'cancelled']);
    $refunded = orderRow(['status' => 'refunded']);

    $this->ingest->ingest($this->device, [$kept, $voided, $refunded]);

    // Six aggregates excluding refunds and a seventh that does not is the bug
    // the shared scope exists to prevent.
    expect(Order::query()->revenue()->count())->toBe(1)
        ->and((int) Order::query()->revenue()->sum('total'))->toBe(34500);
});

// --------------------------------------------------------------- the payload

it('takes identity from the token, never the payload', function () {
    $other = Outlet::create(['name' => 'Cabang Lain']);

    $result = $this->ingest->ingest($this->device, [orderRow([
        'outlet_id' => $other->id,
    ])]);

    expect($result['accepted'])->toBeEmpty();
});

it('keeps every snapshot the receipt was printed from', function () {
    $row = orderRow();
    $this->ingest->ingest($this->device, [$row]);

    $order = Order::query()->with('items.modifiers')->findOrFail($row['id']);
    $item = $order->items->first();

    // A receipt reprinted next year must read as it did on the day, so none of
    // this is re-derived by joining.
    expect($order->cashier_name)->toBe('Siti Rahayu')
        ->and($order->pos_name)->toBe('Kasir 1')
        ->and($order->pb1_rate)->toBe(10.0)
        ->and($order->service_charge_rate)->toBe(5.0)
        ->and($item->product_name)->toBe('Nasi Goreng')
        ->and($item->category_name)->toBe('Makanan')
        ->and($item->unit_cost)->toBe(7000)
        ->and($item->modifiers->first()->option_name)->toBe('Pedas');
});

it('accepts a sale naming a product the server has never seen', function () {
    // Sold offline from a catalogue since edited. Refusing it would be refusing
    // to record something that demonstrably happened.
    $result = $this->ingest->ingest($this->device, [orderRow(
        itemOverrides: ['product_id' => (string) Str::uuid()],
    )]);

    expect($result['accepted'])->toHaveCount(1);
});

it('stores money as integer rupiah', function () {
    $row = orderRow();
    $this->ingest->ingest($this->device, [$row]);

    expect(DB::table('orders')->where('id', $row['id'])->value('total'))->toBe(34500);
});

// ---------------------------------------------------------------- over HTTP

it('serves the order push only to an activated device', function () {
    $this->postJson('/api/v1/sync/push', [
        'entity' => 'orders',
        'rows' => [orderRow()],
    ])->assertUnauthorized();
});

it('accepts a sale over HTTP and names what it took', function () {
    $row = orderRow();

    $this->withHeader('Authorization', 'Bearer '.$this->activation['token'])
        ->postJson('/api/v1/sync/push', [
            'entity' => 'orders',
            'rows' => [$row],
        ])
        ->assertOk()
        ->assertJsonPath('entity', 'orders')
        ->assertJsonPath('accepted.0', $row['id']);
});

// --------------------------------------------------------------- isolation

it('never lets one merchant sale land under another', function () {
    $this->ingest->ingest($this->device, [orderRow()]);

    $other = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);

    expect($this->context->runAs($other, fn () => Order::query()->count()))->toBe(0)
        ->and($this->context->runAs($other, fn () => OrderItem::query()->count()))->toBe(0);
});
