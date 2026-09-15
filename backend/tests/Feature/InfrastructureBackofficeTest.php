<?php

declare(strict_types=1);

use App\Domain\Devices\DeviceActivation;
use App\Domain\Devices\InfrastructureManager;
use App\Filament\Backoffice\Resources\DeviceResource\Pages\ManageDevices;
use App\Filament\Backoffice\Resources\OutletResource;
use App\Filament\Backoffice\Resources\OutletResource\Pages\ManageOutlets;
use App\Filament\Backoffice\Resources\PosRegisterResource\Pages\ManagePosRegisters;
use App\Models\ActivationCode;
use App\Models\Device;
use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Tenant;
use App\Support\TenantContext;
use Filament\Actions\Exceptions\ActionNotResolvableException;
use Filament\Actions\Testing\TestAction;
use Filament\Facades\Filament;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;
use Livewire\Livewire;
use Symfony\Component\HttpKernel\Exception\HttpException;

beforeEach(function () {
    $this->tenant = Tenant::factory()->create();
    $this->owner = Employee::factory()->owner()->create(['tenant_id' => $this->tenant->id]);
    $this->context = app(TenantContext::class);
    $this->context->set($this->tenant);
    $this->outlet = Outlet::create(['name' => 'Pusat']);
    $this->register = PosRegister::create(['name' => 'Kasir', 'outlet_id' => $this->outlet->id]);
    $this->actingAs($this->owner, 'backoffice');
    Filament::setCurrentPanel(Filament::getPanel('backoffice'));
});

it('serves every new Backoffice resource', function (string $path) {
    $this->get('/backoffice/'.$path)->assertOk();
})->with(['outlets', 'pos-registers', 'devices']);

it('creates and edits outlets through Filament without permitting deletion', function () {
    Livewire::test(ManageOutlets::class)
        ->callAction('create', data: ['name' => 'Kemang', 'address' => 'Jl. Kemang', 'phone' => '', 'active' => true])
        ->assertHasNoActionErrors();
    $created = Outlet::where('name', 'Kemang')->firstOrFail();
    expect($created->tenant_id)->toBe($this->tenant->id);
    Livewire::test(ManageOutlets::class)
        ->callAction(TestAction::make('edit')->table($created), data: ['name' => 'Kemang Baru', 'active' => false])
        ->assertHasNoActionErrors();
    expect($created->fresh()->active)->toBeFalse();
    expect(OutletResource::canDelete($created))->toBeFalse();
});

it('creates a register and issues a once-displayed code through Filament', function () {
    Livewire::test(ManagePosRegisters::class)
        ->callAction('create', data: ['outlet_id' => $this->outlet->id, 'name' => 'Takeaway', 'active' => true, 'table_service' => false])
        ->assertHasNoActionErrors();
    $register = PosRegister::where('name', 'Takeaway')->firstOrFail();
    expect($register->table_service)->toBeFalse();
    Livewire::test(ManagePosRegisters::class)
        ->callAction(TestAction::make('issueCode')->table($register))->assertHasNoActionErrors()
        ->assertDispatched('notificationSent');
    expect(json_encode(session()->all()))->not->toContain('Activation code:');
    expect(ActivationCode::count())->toBe(1);
});

it('revokes through the actual Filament action', function () {
    $service = app(DeviceActivation::class);
    $code = $service->issue($this->owner, $this->register->id);
    $body = $service->activate(['code' => $code['code'], 'device_uuid' => (string) Str::uuid()]);
    $device = Device::findOrFail($body['device']['id']);
    Livewire::test(ManageDevices::class)->callAction(TestAction::make('revoke')->table($device))->assertHasNoActionErrors();
    expect($device->fresh()->revoked_at)->not->toBeNull()->and($device->tokens()->count())->toBe(0);
});

it('keeps foreign records out of listings and forged actions', function () {
    $other = Tenant::factory()->create();
    $foreign = $this->context->runAs($other, fn () => Outlet::create(['name' => 'Other secret outlet']));
    $page = Livewire::test(ManageOutlets::class)->assertCanSeeTableRecords([$this->outlet])->assertCanNotSeeTableRecords([$foreign]);
    expect(fn () => $page->callAction(TestAction::make('edit')->table($foreign), data: ['name' => 'Hijacked', 'active' => false]))
        ->toThrow(ActionNotResolvableException::class);
    expect($this->context->runAs($other, fn () => $foreign->fresh()->name))->toBe('Other secret outlet');
});

it('denies cashiers and inactive employees at the service boundary', function (string $kind) {
    $actor = match ($kind) {
        'cashier' => Employee::factory()->cashier()->create(['tenant_id' => $this->tenant->id]),
        default => Employee::factory()->owner()->inactive()->create(['tenant_id' => $this->tenant->id]),
    };
    app(DeviceActivation::class)->issue($actor, $this->register->id);
})->with(['cashier', 'inactive'])->throws(HttpException::class);

it('allows managers to configure tills using manageOutlets', function () {
    $manager = Employee::factory()->manager()->create(['tenant_id' => $this->tenant->id]);
    expect(app(DeviceActivation::class)->issue($manager, $this->register->id))->toHaveKeys(['code', 'expires_at']);
});

it('rejects foreign outlet IDs and immutable register reassignment', function () {
    $other = Outlet::create(['name' => 'Other']);
    app(InfrastructureManager::class)->saveRegister($this->owner, [
        'outlet_id' => $other->id, 'name' => 'Moved', 'active' => true, 'table_service' => true,
    ], $this->register->id);
})->throws(ValidationException::class);

it('enforces outlet and per-outlet register names', function () {
    app(InfrastructureManager::class)->saveOutlet($this->owner, ['name' => 'Pusat', 'active' => true]);
})->throws(ValidationException::class);
