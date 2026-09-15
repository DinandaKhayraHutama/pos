<?php

declare(strict_types=1);

namespace App\Policies;

use App\Domain\Auth\Permission;
use App\Models\Device;
use App\Models\Employee;
use App\Support\TenantContext;
use Illuminate\Database\Eloquent\Model;

class InfrastructurePolicy
{
    public function viewAny(Employee $employee): bool
    {
        return $employee->canAccessBackoffice()
            && $employee->hasPermission(Permission::ManageOutlets)
            && app(TenantContext::class)->id() === $employee->tenant_id
            && app(TenantContext::class)->current()->isActive();
    }

    public function create(Employee $employee): bool
    {
        return $this->viewAny($employee);
    }

    public function update(Employee $employee, Model $record): bool
    {
        return ! $record instanceof Device && $this->view($employee, $record);
    }

    public function view(Employee $employee, Model $record): bool
    {
        return $this->viewAny($employee) && $record->tenant_id === $employee->tenant_id;
    }

    public function delete(Employee $employee, Model $record): bool
    {
        return false;
    }
}
