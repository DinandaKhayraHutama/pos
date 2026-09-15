<?php

declare(strict_types=1);

use App\Domain\Auth\Role;
use App\Models\Category;
use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Product;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Str;
use Livewire\Mechanisms\HandleRequests\HandleRequests;

// Livewire::test() skips the real persistent middleware pipeline. Use the
// signed snapshot from a GET, then POST the update exactly as the client does.
function backofficeSnapshot(string $html, string $component): string
{
    preg_match_all('/wire:snapshot="([^"]+)"/', $html, $matches);
    foreach ($matches[1] as $encoded) {
        $snapshot = html_entity_decode($encoded, ENT_QUOTES | ENT_HTML5, 'UTF-8');
        if (Str::kebab(class_basename(json_decode($snapshot, true)['memo']['name'])) === $component) {
            return $snapshot;
        }
    }
    throw new RuntimeException("Missing component: {$component}");
}

beforeEach(function () {
    $this->context = app(TenantContext::class);
    $this->tenant = Tenant::factory()->create(['name' => 'Livewire Merchant A']);
    $this->other = Tenant::factory()->create(['name' => 'Secret Merchant B']);
    $this->owner = Employee::factory()->owner()->create(['tenant_id' => $this->tenant->id]);
    Employee::factory()->owner()->create(['tenant_id' => $this->other->id]);
    $this->actingAs($this->owner, 'backoffice');
    $this->updateComponent = function (string $snapshot, string $method, array $params = [], array $updates = []) {
        return $this->postJson(app(HandleRequests::class)->getUpdateUri(), [
            'components' => [[
                'snapshot' => $snapshot,
                'updates' => $updates,
                'calls' => [['path' => '', 'method' => $method, 'params' => $params]],
            ]],
        ], ['X-Livewire' => 'true']);
    };
});

it('keeps the business and staff count when the dashboard polls repeatedly', function () {
    $page = $this->get('/backoffice')->assertOk();
    $snapshot = backofficeSnapshot($page->getContent(), 'business-overview');
    for ($poll = 0; $poll < 3; $poll++) {
        $response = ($this->updateComponent)($snapshot, '$refresh')->assertOk();
        $html = $response->json('components.0.effects.html');
        // The merchant name and a tenant-scoped COUNT: together they prove the
        // context survived the poll. The count moved into the outlets stat's
        // description when the dashboard gained today's takings — what it
        // guards is unchanged.
        expect($html)->toContain('Livewire Merchant A')->not->toContain('No merchant resolved', 'Secret Merchant B')
            ->and(strip_tags($html))->toMatch('/1 active staff/s');
        $snapshot = $response->json('components.0.snapshot');
        expect($this->context->current())->toBeNull();
    }
});

it('creates records through the real Livewire HTTP action pipeline', function (string $resource, string $component, string $model) {
    $data = ['name' => 'Created over HTTP', 'active' => true, 'sort_order' => 0];
    if ($resource === 'pos-registers') {
        $outlet = $this->context->runAs($this->tenant, fn () => Outlet::create(['name' => 'Parent Outlet']));
        $data += ['outlet_id' => $outlet->id, 'table_service' => false];
    }
    if ($resource === 'products') {
        $category = $this->context->runAs($this->tenant, fn () => Category::create(['name' => 'Parent Category']));
        $data += ['category_id' => $category->id, 'price' => 5000, 'available' => true];
    }
    $page = $this->get('/backoffice/'.$resource)->assertOk();
    $snapshot = backofficeSnapshot($page->getContent(), $component);
    $mounted = ($this->updateComponent)($snapshot, 'mountAction', ['create'])->assertOk();
    $updates = [];
    foreach ($data as $key => $value) {
        $updates['mountedActions.0.data.'.$key] = $value;
    }
    ($this->updateComponent)($mounted->json('components.0.snapshot'), 'callMountedAction', [], $updates)->assertOk();
    $record = $this->context->runAs($this->tenant, fn () => $model::where('name', 'Created over HTTP')->first());
    expect($record)->not->toBeNull()
        ->and($record->tenant_id)->toBe($this->tenant->id)
        ->and($this->context->current())->toBeNull();
})->with([
    ['categories', 'manage-categories', Category::class],
    ['outlets', 'manage-outlets', Outlet::class],
    ['pos-registers', 'manage-pos-registers', PosRegister::class],
    ['products', 'manage-products', Product::class],
]);

it('renders staff with the required number formatting extension', function () {
    expect(extension_loaded('intl'))->toBeTrue();
    $this->get('/backoffice/employees')->assertOk()->assertSee($this->owner->name);
});

it('rechecks permissions for an owner snapshot after the account becomes a manager', function () {
    $page = $this->get('/backoffice/categories')->assertOk();
    $snapshot = backofficeSnapshot($page->getContent(), 'manage-categories');
    $this->owner->role = Role::Manager;
    $this->owner->save();
    ($this->updateComponent)($snapshot, 'mountAction', ['create'])->assertForbidden();
    expect($this->context->current())->toBeNull();
});

it('clears context when an update fails snapshot verification', function () {
    $page = $this->get('/backoffice')->assertOk();
    $snapshot = json_decode(backofficeSnapshot($page->getContent(), 'business-overview'), true);
    $snapshot['memo']['path'] = 'backoffice/employees';
    ($this->updateComponent)(json_encode($snapshot), '$refresh')->assertStatus(500);
    expect($this->context->current())->toBeNull();
});
