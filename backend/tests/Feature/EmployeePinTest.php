<?php

declare(strict_types=1);

use App\Domain\Auth\Permission;
use App\Domain\Auth\Role;
use App\Models\Employee;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\Hash;

beforeEach(function () {
    $this->context = app(TenantContext::class);
    $this->tenant = Tenant::create(['name' => 'Warung A', 'slug' => 'warung-a']);
    $this->other = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);
    $this->context->set($this->tenant);
});

afterEach(fn () => $this->context->clear());

it('stores a PIN hashed, never in plain text', function () {
    $cashier = Employee::factory()->cashier('2345')->create(['tenant_id' => $this->tenant->id]);

    expect($cashier->pin_hash)->not->toBe('2345')
        ->and(Hash::check('2345', $cashier->pin_hash))->toBeTrue();
});

it('verifies a PIN against one employee only', function () {
    $siti = Employee::factory()->cashier('2345')->create([
        'tenant_id' => $this->tenant->id, 'name' => 'Siti',
    ]);
    $dani = Employee::factory()->cashier('3456')->create([
        'tenant_id' => $this->tenant->id, 'name' => 'Dani',
    ]);

    // The device picks the account first, then checks the PIN against THAT
    // choice. A colleague's own valid PIN must be rejected exactly like a wrong
    // one, or the account choice is theatre.
    expect($siti->verifyPin('2345'))->toBeTrue()
        ->and($siti->verifyPin('3456'))->toBeFalse()
        ->and($dani->verifyPin('3456'))->toBeTrue();
});

it('refuses a PIN on a deactivated account', function () {
    $cashier = Employee::factory()->cashier('2345')->inactive()->create([
        'tenant_id' => $this->tenant->id,
    ]);

    expect($cashier->verifyPin('2345'))->toBeFalse();
});

it('grants no permissions to a deactivated account', function () {
    $manager = Employee::factory()->manager()->inactive()->create([
        'tenant_id' => $this->tenant->id,
    ]);

    expect($manager->hasPermission(Permission::VoidOrder))->toBeFalse()
        ->and($manager->permissionValues())->toBe([])
        ->and($manager->canAuthorizeOverrides())->toBeFalse();
});

it('detects a duplicate PIN within the tenant', function () {
    Employee::factory()->cashier('2345')->create(['tenant_id' => $this->tenant->id]);

    expect(Employee::pinTakenWithinTenant('2345'))->toBeTrue()
        ->and(Employee::pinTakenWithinTenant('9999'))->toBeFalse();
});

it('ignores the employee being edited when checking PIN uniqueness', function () {
    $cashier = Employee::factory()->cashier('2345')->create(['tenant_id' => $this->tenant->id]);

    expect(Employee::pinTakenWithinTenant('2345', exceptId: $cashier->id))->toBeFalse();
});

it('lets two different merchants use the same PIN', function () {
    app(TenantContext::class)->runAs($this->other, fn () => Employee::factory()->cashier('2345')->create(['tenant_id' => $this->other->id]));

    // Still scoped to the current tenant, which holds nobody with that PIN.
    expect(Employee::pinTakenWithinTenant('2345'))->toBeFalse();
});

it('keeps a cashier out of the backoffice even with a password set', function () {
    $cashier = Employee::factory()->create([
        'tenant_id' => $this->tenant->id,
        'role' => Role::Cashier,
        'password' => 'password123',
    ]);

    expect($cashier->canAccessBackoffice())->toBeFalse();
});

it('keeps a passwordless owner out of the backoffice', function () {
    $owner = Employee::factory()->create([
        'tenant_id' => $this->tenant->id,
        'role' => Role::Owner,
        'password' => null,
    ]);

    expect($owner->canAccessBackoffice())->toBeFalse();
});

it('lets an active owner with a password into the backoffice', function () {
    $owner = Employee::factory()->owner()->create(['tenant_id' => $this->tenant->id]);

    expect($owner->canAccessBackoffice())->toBeTrue();
});

it('hides credentials when serialised', function () {
    $owner = Employee::factory()->owner()->create(['tenant_id' => $this->tenant->id]);

    expect(array_keys($owner->toArray()))
        ->not->toContain('password')
        ->not->toContain('pin_hash')
        ->not->toContain('remember_token');
});
