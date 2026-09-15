<?php

declare(strict_types=1);

namespace App\Policies;

use App\Domain\Auth\Permission;
use App\Models\Employee;
use App\Support\TenantContext;
use Illuminate\Database\Eloquent\Model;

/**
 * Who may see and edit the menu.
 *
 * `manageCatalogue` is the OWNER's permission — a manager runs the floor and
 * the money, and prices are not theirs. That is the device's rule, mirrored
 * here so the two surfaces cannot disagree about who may reprice a dish.
 *
 * Separate from {@see InfrastructurePolicy} precisely because that one gates on
 * `manageOutlets`, which a manager DOES hold. Reusing it would quietly hand the
 * catalogue to managers.
 */
class CataloguePolicy
{
    public function viewAny(Employee $employee): bool
    {
        $context = app(TenantContext::class);

        return $employee->canAccessBackoffice()
            && $employee->hasPermission(Permission::ManageCatalogue)
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

    /**
     * Allowed — but it tombstones rather than removes, so a till learns the row
     * is gone instead of keeping it forever.
     */
    public function delete(Employee $employee, Model $record): bool
    {
        return $this->view($employee, $record);
    }
}
