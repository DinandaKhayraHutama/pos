<?php

declare(strict_types=1);

namespace App\Policies;

use App\Domain\Auth\Permission;
use App\Models\Employee;
use App\Support\TenantContext;
use Illuminate\Database\Eloquent\Model;

/**
 * Who may manage staff accounts and their PINs.
 *
 * `manageEmployees` — the owner's, not a manager's. Letting a manager mint till
 * accounts would let them mint one for themselves and walk around every
 * permission the role split exists to enforce.
 */
class StaffPolicy
{
    public function viewAny(Employee $employee): bool
    {
        $context = app(TenantContext::class);

        return $employee->canAccessBackoffice()
            && $employee->hasPermission(Permission::ManageEmployees)
            && $context->id() === $employee->tenant_id
            && (bool) $context->current()?->isActive();
    }

    public function create(Employee $employee): bool
    {
        return $this->viewAny($employee);
    }

    public function view(Employee $employee, Model $record): bool
    {
        return $this->viewAny($employee) && $record->tenant_id === $employee->tenant_id;
    }

    public function update(Employee $employee, Model $record): bool
    {
        return $this->view($employee, $record);
    }

    /** Staff are deactivated, never deleted — their names live on past receipts. */
    public function delete(Employee $employee, Model $record): bool
    {
        return false;
    }
}
