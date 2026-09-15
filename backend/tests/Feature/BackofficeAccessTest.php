<?php

declare(strict_types=1);

use App\Domain\Auth\Role;
use App\Models\Employee;
use App\Models\Tenant;

/**
 * Who may open the Backoffice, and what they see once inside.
 *
 * The acceptance criteria for the tenant-bootstrap phase live here: an Owner
 * signs in and is shown their OWN business, and nobody else can get in.
 */
beforeEach(function () {
    $this->tenantA = Tenant::create(['name' => 'Warung A', 'slug' => 'warung-a']);
    $this->tenantB = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);

    $this->ownerA = Employee::factory()->owner()->create([
        'tenant_id' => $this->tenantA->id, 'name' => 'Owner A', 'email' => 'a@example.test',
    ]);
    $this->ownerB = Employee::factory()->owner()->create([
        'tenant_id' => $this->tenantB->id, 'name' => 'Owner B', 'email' => 'b@example.test',
    ]);
});

it('redirects a guest to the login page', function () {
    $this->get('/backoffice')->assertRedirect('/backoffice/login');
});

it('serves the login page', function () {
    $this->get('/backoffice/login')->assertOk();
});

it('lets an owner reach the dashboard', function () {
    $this->actingAs($this->ownerA, 'backoffice')
        ->get('/backoffice')
        ->assertOk();
});

it('shows the owner their own business name', function () {
    $this->actingAs($this->ownerA, 'backoffice')
        ->get('/backoffice')
        ->assertOk()
        ->assertSee('Warung A')
        ->assertDontSee('Warung B');
});

it('lets a manager in', function () {
    $manager = Employee::factory()->manager()->create([
        'tenant_id' => $this->tenantA->id, 'email' => 'm@example.test',
    ]);

    expect($manager->canAccessBackoffice())->toBeTrue();

    $this->actingAs($manager, 'backoffice')->get('/backoffice')->assertOk();
});

it('keeps a cashier out even when they somehow hold a password', function () {
    $cashier = Employee::factory()->create([
        'tenant_id' => $this->tenantA->id,
        'role' => Role::Cashier,
        'email' => 'c@example.test',
        'password' => 'password123',
    ]);

    $this->actingAs($cashier, 'backoffice')
        ->get('/backoffice')
        ->assertForbidden();
});

it('keeps a deactivated owner out', function () {
    $suspended = Employee::factory()->owner()->inactive()->create([
        'tenant_id' => $this->tenantA->id, 'email' => 'x@example.test',
    ]);

    // A deactivated account still has a valid password; the door check is what
    // separates "these credentials are real" from "this person still works here".
    $this->actingAs($suspended, 'backoffice')
        ->get('/backoffice')
        ->assertForbidden();
});

it('never shows one merchant the other staff list', function () {
    $this->actingAs($this->ownerB, 'backoffice')
        ->get('/backoffice')
        ->assertOk()
        ->assertSee('Warung B')
        ->assertDontSee('Warung A');
});
