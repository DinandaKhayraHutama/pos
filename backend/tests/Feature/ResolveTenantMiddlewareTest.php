<?php

declare(strict_types=1);

use App\Models\Employee;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\Route;

/**
 * Tenant isolation as it actually behaves over HTTP.
 *
 * The unit-level scope tests prove the filter works when a tenant is set; these
 * prove the right tenant gets set in the first place, which is the half a
 * controller can get wrong.
 */
beforeEach(function () {
    $this->tenantA = Tenant::create(['name' => 'Warung A', 'slug' => 'warung-a']);
    $this->tenantB = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);

    $this->ownerA = Employee::factory()->owner()->create([
        'tenant_id' => $this->tenantA->id, 'name' => 'Owner A', 'email' => 'a@example.test',
    ]);
    Employee::factory()->owner()->create([
        'tenant_id' => $this->tenantB->id, 'name' => 'Owner B', 'email' => 'b@example.test',
    ]);

    Route::middleware(['web', 'auth:backoffice', 'tenant'])
        ->get('/_test/staff', fn () => response()->json([
            'tenant' => app(TenantContext::class)->current()?->name,
            'staff' => Employee::query()->pluck('name'),
        ]));
});

it('resolves the tenant from the signed-in employee', function () {
    $this->actingAs($this->ownerA, 'backoffice')
        ->getJson('/_test/staff')
        ->assertOk()
        ->assertJsonPath('tenant', 'Warung A')
        ->assertJsonPath('staff', ['Owner A']);
});

it('never returns another merchant staff over HTTP', function () {
    $response = $this->actingAs($this->ownerA, 'backoffice')->getJson('/_test/staff');

    expect($response->json('staff'))->not->toContain('Owner B');
});

it('clears the tenant after the request', function () {
    $this->actingAs($this->ownerA, 'backoffice')->getJson('/_test/staff')->assertOk();

    // The context is a singleton; a leaked tenant would silently scope the next
    // request — or a queued job — to the wrong merchant.
    expect(app(TenantContext::class)->current())->toBeNull();
});

it('clears the tenant even when the request throws', function () {
    Route::middleware(['web', 'auth:backoffice', 'tenant'])
        ->get('/_test/boom', fn () => throw new RuntimeException('boom'));

    $this->withoutExceptionHandling()
        ->actingAs($this->ownerA, 'backoffice')
        ->getJson('/_test/boom');
})->throws(RuntimeException::class)
    ->after(fn () => expect(app(TenantContext::class)->current())->toBeNull());

it('leaves the tenant unresolved for a guest', function () {
    Route::middleware(['web', 'tenant'])
        ->get('/_test/guest', fn () => response()->json([
            'tenant' => app(TenantContext::class)->current()?->name,
            'staff' => Employee::query()->pluck('name'),
        ]));

    // Fails closed: no tenant, therefore no rows — not every merchant's rows.
    $this->getJson('/_test/guest')
        ->assertOk()
        ->assertJsonPath('tenant', null)
        ->assertJsonPath('staff', []);
});

it('serves the health endpoint without auth or a tenant', function () {
    $this->getJson('/api/v1/health')
        ->assertOk()
        ->assertJsonPath('status', 'ok');
});
