<?php

declare(strict_types=1);

use App\Domain\Auth\Role;
use App\Models\Employee;
use App\Models\Tenant;
use App\Support\TenantContext;
use Filament\Auth\Pages\Login;
use Filament\Facades\Filament;
use Livewire\Livewire;

beforeEach(function () {
    $this->tenant = Tenant::factory()->create();
    $this->context = app(TenantContext::class);
    Filament::setCurrentPanel(Filament::getPanel('backoffice'));
});

it('signs in through the form and restores the session before resolving a tenant', function (Role $role) {
    $employee = Employee::factory()->create([
        'tenant_id' => $this->tenant->id,
        'role' => $role,
        'password' => 'password',
    ]);

    Livewire::test(Login::class)
        ->fillForm(['email' => $employee->email, 'password' => 'password'])
        ->call('authenticate')
        ->assertHasNoFormErrors()
        ->assertRedirect();

    $this->assertAuthenticatedAs($employee, 'backoffice');
    expect($this->context->hasTenant())->toBeFalse()
        ->and(Employee::count())->toBe(0);

    // Discard the guard's cached user: the next request must load it by ID
    // from the session while TenantScope still has no current merchant.
    auth()->forgetGuards();
    $this->get('/backoffice')->assertOk()->assertSee($this->tenant->name);
    $this->assertAuthenticatedAs($employee, 'backoffice');
    expect($this->context->hasTenant())->toBeFalse()
        ->and(Employee::count())->toBe(0);
})->with([Role::Owner, Role::Manager]);

it('rejects invalid or ineligible accounts through the login form', function (string $reason) {
    $employee = Employee::factory()->owner()->create([
        'tenant_id' => $this->tenant->id,
        'password' => 'password',
        'active' => $reason !== 'inactive',
        'role' => $reason === 'cashier' ? Role::Cashier : Role::Owner,
    ]);
    if ($reason === 'deleted') {
        $employee->delete();
    }

    Livewire::test(Login::class)
        ->fillForm([
            'email' => $reason === 'unknown' ? 'missing@example.test' : $employee->email,
            'password' => $reason === 'wrong password' ? 'incorrect' : 'password',
        ])
        ->call('authenticate')
        ->assertHasFormErrors(['email']);

    $this->assertGuest('backoffice');
    expect($this->context->hasTenant())->toBeFalse()
        ->and($this->context->isUnscoped())->toBeFalse();
})->with(['wrong password', 'unknown', 'inactive', 'cashier', 'deleted']);

it('restores remember tokens without weakening ordinary employee queries', function () {
    $employee = Employee::factory()->owner()->create([
        'tenant_id' => $this->tenant->id,
        'remember_token' => 'known-remember-token',
    ]);
    $otherTenant = Tenant::factory()->create();
    $this->context->set($otherTenant);
    $provider = auth('backoffice')->getProvider();

    expect($provider->retrieveByToken($employee->id, 'known-remember-token')?->id)->toBe($employee->id)
        ->and($provider->retrieveByToken($employee->id, 'wrong-token'))->toBeNull()
        ->and($provider->retrieveById($employee->id)?->id)->toBe($employee->id)
        ->and($this->context->id())->toBe($otherTenant->id)
        ->and($this->context->isUnscoped())->toBeFalse()
        ->and(Employee::find($employee->id))->toBeNull();

    $this->context->clear();
    $employee->delete();
    expect($provider->retrieveById($employee->id))->toBeNull()
        ->and($provider->retrieveByToken($employee->id, 'known-remember-token'))->toBeNull();
});
