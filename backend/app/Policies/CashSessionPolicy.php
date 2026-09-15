<?php

declare(strict_types=1);

namespace App\Policies;

use App\Domain\Auth\Permission;
use App\Models\Employee;
use App\Support\TenantContext;
use Illuminate\Database\Eloquent\Model;

/**
 * Who may look at what the tills took.
 *
 * `viewCashDrawer` — the manager's permission on the device too, where it gates
 * seeing the expected contents of every open drawer without ending the shift.
 * Mirroring it here keeps one answer to "who may check the money" across both
 * surfaces.
 *
 * Every write verb is false. These rows are a till's account of a physical cash
 * box; editing one from a browser would let somebody erase a variance from a
 * chair, which is the opposite of what the screen is for.
 */
class CashSessionPolicy
{
    public function viewAny(Employee $employee): bool
    {
        $context = app(TenantContext::class);

        return $employee->canAccessBackoffice()
            && $employee->hasPermission(Permission::ViewCashDrawer)
            && $context->id() === $employee->tenant_id
            && (bool) $context->current()?->isActive();
    }

    public function view(Employee $employee, Model $record): bool
    {
        return $this->viewAny($employee) && $record->tenant_id === $employee->tenant_id;
    }

    public function create(Employee $employee): bool
    {
        return false;
    }

    public function update(Employee $employee, Model $record): bool
    {
        return false;
    }

    public function delete(Employee $employee, Model $record): bool
    {
        return false;
    }
}
