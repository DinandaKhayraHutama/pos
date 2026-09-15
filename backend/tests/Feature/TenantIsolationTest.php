<?php

declare(strict_types=1);

use App\Domain\Auth\Role;
use App\Domain\Devices\DeviceActivation;
use App\Models\ActivationCode;
use App\Models\Device;
use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Str;

/**
 * The most important test class in this system.
 *
 * Every tenant-owned model must be unreachable from another tenant's context,
 * and the failure mode being guarded against is silent: a leak returns data
 * successfully, with no error anywhere. Each new tenant-owned entity gets a
 * case here before it is considered done.
 */
beforeEach(function () {
    $this->context = app(TenantContext::class);

    $this->tenantA = Tenant::create(['name' => 'Warung A', 'slug' => 'warung-a']);
    $this->tenantB = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);

    $this->staffA = Employee::factory()->create([
        'tenant_id' => $this->tenantA->id,
        'name' => 'Owner A',
        'email' => 'a@example.test',
    ]);

    $this->staffB = Employee::factory()->create([
        'tenant_id' => $this->tenantB->id,
        'name' => 'Owner B',
        'email' => 'b@example.test',
    ]);
});

afterEach(function () {
    $this->context->clear();
});

it('returns only the current tenant employees', function () {
    $this->context->set($this->tenantA);

    $names = Employee::query()->pluck('name');

    expect($names)->toContain('Owner A')
        ->and($names)->not->toContain('Owner B')
        ->and(Employee::query()->count())->toBe(1);
});

it('cannot find another tenant employee by primary key', function () {
    $this->context->set($this->tenantA);

    expect(Employee::query()->find($this->staffB->id))->toBeNull();
});

it('cannot update another tenant employee', function () {
    $this->context->set($this->tenantA);

    $affected = Employee::query()->whereKey($this->staffB->id)->update(['name' => 'Hijacked']);

    expect($affected)->toBe(0)
        ->and($this->staffB->fresh()->name)->toBe('Owner B');
});

it('cannot delete another tenant employee', function () {
    $this->context->set($this->tenantA);

    $deleted = Employee::query()->whereKey($this->staffB->id)->delete();

    expect($deleted)->toBe(0)
        ->and(Employee::withoutGlobalScopes()->whereKey($this->staffB->id)->exists())->toBeTrue();
});

it('does not leak every tenant when no tenant is resolved', function () {
    // The dangerous default this guards: an unresolved tenant must fail closed
    // (empty), never fall through to returning everybody's rows.
    $this->context->clear();

    expect(Employee::query()->count())->toBe(0);
});

it('stamps the current tenant onto new rows automatically', function () {
    $this->context->set($this->tenantB);

    $created = Employee::create([
        'name' => 'Hired Later',
        'email' => 'later@example.test',
        'password' => 'password123',
        'role' => Role::Manager,
    ]);

    expect($created->tenant_id)->toBe($this->tenantB->id);
});

it('refuses to create a tenant-owned row with no tenant resolved', function () {
    $this->context->clear();

    Employee::create([
        'name' => 'Orphan',
        'email' => 'orphan@example.test',
        'password' => 'password123',
        'role' => Role::Manager,
    ]);
})->throws(RuntimeException::class);

it('sees across tenants only inside runUnscoped', function () {
    $this->context->set($this->tenantA);

    $all = $this->context->runUnscoped(fn () => Employee::query()->pluck('name'));

    expect($all)->toContain('Owner A')->toContain('Owner B');

    // …and the previous tenant is restored afterwards.
    expect(Employee::query()->count())->toBe(1);
});

it('refuses an unscoped write that does not name its tenant', function () {
    $this->context->runUnscoped(function () {
        Employee::create([
            'name' => 'Ambiguous',
            'email' => 'ambiguous@example.test',
            'password' => 'password123',
            'role' => Role::Manager,
        ]);
    });
})->throws(RuntimeException::class);

it('restores the previous tenant after runAs', function () {
    $this->context->set($this->tenantA);

    $seen = $this->context->runAs($this->tenantB, fn () => Employee::query()->pluck('name'));

    expect($seen)->toContain('Owner B')->not->toContain('Owner A')
        ->and($this->context->id())->toBe($this->tenantA->id);
});

it('isolates every Phase 2 entity and fails closed before authentication', function (string $class) {
    $rows = [];
    foreach ([$this->tenantA, $this->tenantB] as $tenant) {
        $rows[] = $this->context->runAs($tenant, function () use ($class) {
            $outlet = Outlet::create(['name' => 'Pusat']);
            $register = PosRegister::create(['name' => 'Kasir', 'outlet_id' => $outlet->id]);
            $owner = Employee::query()->firstOrFail();
            $issued = app(DeviceActivation::class)->issue($owner, $register->id);
            app(DeviceActivation::class)->activate([
                'code' => $issued['code'], 'device_uuid' => (string) Str::uuid(),
            ]);

            return $class::query()->firstOrFail();
        });
    }
    $this->context->set($this->tenantA);
    expect($class::query()->count())->toBe(1)
        ->and($class::query()->find($rows[1]->id))->toBeNull()
        ->and($class::query()->whereKey($rows[1]->id)->delete())->toBe(0);
    $this->context->clear();
    expect($class::query()->count())->toBe(0);
})->with([Outlet::class, PosRegister::class, Device::class, ActivationCode::class]);

it('rejects explicit foreign tenant writes and tenant reassignment', function () {
    $this->context->set($this->tenantA);
    expect(fn () => $this->staffB->update(['name' => 'Hijacked']))->toThrow(RuntimeException::class);
    expect(fn () => $this->staffA->update(['tenant_id' => $this->tenantB->id]))->toThrow(RuntimeException::class);
});
