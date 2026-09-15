<?php

declare(strict_types=1);

namespace App\Domain\Devices;

use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Validation\ValidationException;

class InfrastructureManager
{
    public function saveOutlet(Employee $actor, array $data, ?string $id = null): Outlet
    {
        return DB::transaction(function () use ($actor, $data, $id) {
            $this->authorize($actor);
            $outlet = $id ? Outlet::query()->findOrFail($id) : new Outlet;
            $values = Validator::make($data, [
                'name' => ['required', 'string', 'max:255'],
                'address' => ['nullable', 'string', 'max:255'],
                'phone' => ['nullable', 'string', 'max:255'],
                'active' => ['required', 'boolean'],
            ])->validate();
            if (Outlet::query()->where('name', $values['name'])->when($id, fn ($q) => $q->whereKeyNot($id))->exists()) {
                throw ValidationException::withMessages(['name' => 'This outlet name is already used.']);
            }
            $outlet->fill($values)->save();

            return $outlet;
        }, 3);
    }

    public function saveRegister(Employee $actor, array $data, ?string $id = null): PosRegister
    {
        return DB::transaction(function () use ($actor, $data, $id) {
            $this->authorize($actor);
            $register = $id ? PosRegister::query()->findOrFail($id) : new PosRegister;
            $values = Validator::make($data, [
                'name' => ['required', 'string', 'max:255'],
                'outlet_id' => ['required', 'uuid'],
                'table_service' => ['required', 'boolean'],
                'active' => ['required', 'boolean'],
            ])->validate();
            if (! Outlet::query()->whereKey($values['outlet_id'])->exists()
                || ($id && $register->outlet_id !== $values['outlet_id'])) {
                throw ValidationException::withMessages(['outlet_id' => 'Choose an outlet in this business. Existing registers cannot move outlets.']);
            }
            if (PosRegister::query()->where('outlet_id', $values['outlet_id'])->where('name', $values['name'])
                ->when($id, fn ($q) => $q->whereKeyNot($id))->exists()) {
                throw ValidationException::withMessages(['name' => 'This register name is already used at this outlet.']);
            }
            $register->fill($values)->save();

            return $register;
        }, 3);
    }

    private function authorize(Employee $actor): void
    {
        $context = app(TenantContext::class);
        $tenant = Tenant::query()->whereKey($context->requireId())->lockForUpdate()->firstOrFail();
        $context->set($tenant);
        app(DeviceActivation::class)->authorize($actor);
    }
}
