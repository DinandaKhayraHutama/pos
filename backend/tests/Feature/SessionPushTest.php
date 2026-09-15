<?php

declare(strict_types=1);

use App\Domain\Devices\DeviceActivation;
use App\Domain\Sync\SessionIngest;
use App\Models\Device;
use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\PosSession;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Str;

/**
 * Cash sessions arriving from a till.
 *
 * The first push direction, so these cases establish what "safe to retry" has
 * to mean for every later one: a drawer must never be duplicated by a retry,
 * never reopened by a late packet, and never opened twice on one register.
 */
beforeEach(function () {
    $this->context = app(TenantContext::class);
    $this->ingest = app(SessionIngest::class);

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

function openSessionRow(array $overrides = []): array
{
    return array_merge([
        'id' => (string) Str::uuid(),
        'employee_id' => (string) Str::uuid(),
        'employee_name' => 'Siti Rahayu',
        'pos_name' => 'Kasir 1',
        'outlet_name' => 'Pusat',
        'opened_at' => now()->getTimestampMs(),
        'opening_cash' => 200000,
        'closed_at' => null,
        'counted_cash' => null,
        'expected_cash' => null,
        'closed_by_id' => null,
        'closed_by_name' => null,
        'note' => null,
    ], $overrides);
}

// ------------------------------------------------------------- idempotency

it('accepts a session the till opened', function () {
    $row = openSessionRow();

    $result = $this->ingest->ingest($this->device, [$row]);

    expect($result['accepted'])->toBe([$row['id']])
        ->and($result['rejected'])->toBeEmpty()
        ->and(PosSession::query()->count())->toBe(1);
});

it('is idempotent — the same push three times leaves one drawer', function () {
    $row = openSessionRow();

    foreach (range(1, 3) as $ignored) {
        $this->ingest->ingest($this->device, [$row]);
    }

    // A push that timed out after the server committed gets retried by the
    // device. Retrying must not open a second drawer for the same shift.
    expect(PosSession::query()->count())->toBe(1);
});

it('carries the close over the earlier open row', function () {
    $row = openSessionRow();
    $this->ingest->ingest($this->device, [$row]);

    $this->ingest->ingest($this->device, [openSessionRow([
        'id' => $row['id'],
        'closed_at' => now()->getTimestampMs(),
        'counted_cash' => 450000,
        'expected_cash' => 445000,
        'closed_by_name' => 'Siwi',
    ])]);

    $session = PosSession::query()->findOrFail($row['id']);
    expect(PosSession::query()->count())->toBe(1)
        ->and($session->isOpen())->toBeFalse()
        ->and($session->counted_cash)->toBe(450000)
        ->and($session->variance())->toBe(5000);
});

it('refuses to reopen a drawer that has already been counted', function () {
    $row = openSessionRow();
    $this->ingest->ingest($this->device, [$row]);
    $this->ingest->ingest($this->device, [openSessionRow([
        'id' => $row['id'],
        'closed_at' => now()->getTimestampMs(),
        'counted_cash' => 450000,
        'expected_cash' => 445000,
    ])]);

    // A stale packet describing the open state arrives late. Applying it would
    // erase a variance somebody has already signed off on.
    $result = $this->ingest->ingest($this->device, [$row]);

    expect($result['accepted'])->toBeEmpty()
        ->and($result['rejected'])->toHaveCount(1)
        ->and(PosSession::query()->findOrFail($row['id'])->isOpen())->toBeFalse();
});

// -------------------------------------------------- one open drawer per till

it('refuses a second open session on the same register', function () {
    $this->ingest->ingest($this->device, [openSessionRow()]);

    $result = $this->ingest->ingest($this->device, [openSessionRow([
        'employee_name' => 'Dani',
    ])]);

    expect($result['accepted'])->toBeEmpty()
        ->and($result['rejected'][0]['reason'])->toContain('Siti Rahayu')
        ->and(PosSession::query()->open()->count())->toBe(1);
});

it('frees the register once the drawer is closed', function () {
    $first = openSessionRow();
    $this->ingest->ingest($this->device, [$first]);
    $this->ingest->ingest($this->device, [openSessionRow([
        'id' => $first['id'],
        'closed_at' => now()->getTimestampMs(),
        'counted_cash' => 200000,
        'expected_cash' => 200000,
    ])]);

    $result = $this->ingest->ingest($this->device, [openSessionRow()]);

    expect($result['accepted'])->toHaveCount(1)
        ->and(PosSession::query()->count())->toBe(2);
});

// -------------------------------------------------------------- the payload

it('takes the outlet and register from the token, never the payload', function () {
    $other = Outlet::create(['name' => 'Cabang Lain']);
    $otherRegister = PosRegister::create([
        'name' => 'Kasir 9', 'outlet_id' => $other->id,
    ]);

    // A till naming someone else's register would be a till able to write into
    // another branch's books.
    $result = $this->ingest->ingest($this->device, [openSessionRow([
        'outlet_id' => $other->id,
        'pos_register_id' => $otherRegister->id,
    ])]);

    expect($result['accepted'])->toBeEmpty()
        ->and($result['rejected'])->toHaveCount(1);
});

it('stamps the device that sent it', function () {
    $row = openSessionRow();
    $this->ingest->ingest($this->device, [$row]);

    // Which tablet sent it is a different question from which register it
    // belongs to — a register outlives the tablet standing at it.
    expect(PosSession::query()->findOrFail($row['id'])->device_id)
        ->toBe($this->device->id);
});

it('keeps a bad row from failing the whole batch', function () {
    $good = openSessionRow();
    $bad = openSessionRow(['employee_name' => null]);

    $result = $this->ingest->ingest($this->device, [$bad, $good]);

    // The good row is money already taken; holding it hostage to a neighbour's
    // problem is the wrong risk.
    expect($result['accepted'])->toBe([$good['id']])
        ->and($result['rejected'])->toHaveCount(1)
        ->and(PosSession::query()->count())->toBe(1);
});

// --------------------------------------------------------------- over HTTP

it('serves the push endpoint only to an activated device', function () {
    $this->postJson('/api/v1/sync/push', [
        'entity' => 'pos_sessions',
        'rows' => [openSessionRow()],
    ])->assertUnauthorized();
});

it('accepts a push over HTTP and names what it took', function () {
    $row = openSessionRow();

    $this->withHeader('Authorization', 'Bearer '.$this->activation['token'])
        ->postJson('/api/v1/sync/push', [
            'entity' => 'pos_sessions',
            'rows' => [$row],
        ])
        ->assertOk()
        ->assertJsonPath('entity', 'pos_sessions')
        ->assertJsonPath('accepted.0', $row['id']);
});

it('rejects an entity that is not pushable', function () {
    $this->withHeader('Authorization', 'Bearer '.$this->activation['token'])
        ->postJson('/api/v1/sync/push', [
            'entity' => 'employees',
            'rows' => [['id' => (string) Str::uuid()]],
        ])
        ->assertStatus(422);
});

// -------------------------------------------------------------- isolation

it('never lets one merchant session land under another', function () {
    $row = openSessionRow();
    $this->ingest->ingest($this->device, [$row]);

    $other = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);

    $seen = $this->context->runAs($other, fn () => PosSession::query()->count());

    expect($seen)->toBe(0);
});
