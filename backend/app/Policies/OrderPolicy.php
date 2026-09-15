<?php

declare(strict_types=1);

namespace App\Policies;

use App\Domain\Auth\Permission;
use App\Models\Employee;
use App\Support\TenantContext;
use Illuminate\Database\Eloquent\Model;

/**
 * Who may look at the sales.
 *
 * `viewAllOrders` — the manager's permission on the device, where it separates
 * seeing every cashier's sales from seeing only your own. A cashier holds
 * `viewOwnOrders` and cannot reach the Backoffice at all, so the distinction
 * does not arise here; it is mirrored anyway so the two surfaces cannot come to
 * different answers about who may read the takings.
 *
 * Every write verb is false. A sale is undone at the till by someone with the
 * permission and a reason; letting a browser restate it would erase the audit
 * trail that makes the void meaningful.
 */
class OrderPolicy
{
    public function viewAny(Employee $employee): bool
    {
        $context = app(TenantContext::class);

        return $employee->canAccessBackoffice()
            && $employee->hasPermission(Permission::ViewAllOrders)
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
