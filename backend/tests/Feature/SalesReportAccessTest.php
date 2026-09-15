<?php

declare(strict_types=1);

use App\Models\Employee;
use App\Models\Tenant;
use App\Support\TenantContext;

/**
 * Who may open the money view.
 *
 * `viewFinancialReports` is the OWNER's permission on the device — a manager
 * gets today's dashboard and the cash drawers, but the ranged report with
 * profit and margin is not theirs. Mirrored here so the two surfaces cannot
 * come to different answers about who may read the takings.
 */
beforeEach(function () {
    $this->context = app(TenantContext::class);
    $this->tenant = Tenant::create(['name' => 'Warung A', 'slug' => 'warung-a']);
    $this->context->set($this->tenant);
});

afterEach(fn () => $this->context->clear());

it('lets an owner open the sales report', function () {
    $owner = Employee::factory()->owner()->create([
        'tenant_id' => $this->tenant->id, 'email' => 'owner@example.test',
    ]);

    $this->actingAs($owner, 'backoffice')
        ->get('/backoffice/sales-report')
        ->assertOk();
});

it('keeps a manager out of the ranged financial report', function () {
    $manager = Employee::factory()->manager()->create([
        'tenant_id' => $this->tenant->id, 'email' => 'manager@example.test',
    ]);

    // A manager runs the floor and the money day to day; profit and margin over
    // a range are the owner's. Same split as the till.
    $this->actingAs($manager, 'backoffice')
        ->get('/backoffice/sales-report')
        ->assertForbidden();
});

it('sends a guest to the login page', function () {
    $this->get('/backoffice/sales-report')->assertRedirect('/backoffice/login');
});
