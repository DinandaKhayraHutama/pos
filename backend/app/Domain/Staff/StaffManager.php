<?php

declare(strict_types=1);

namespace App\Domain\Staff;

use App\Domain\Auth\Permission;
use App\Domain\Auth\Role;
use App\Models\Employee;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;

/**
 * Staff accounts, and the credentials behind them.
 *
 * Two credentials, neither implying the other, both optional:
 *
 * - `password` — for staff who open the Backoffice in a browser. Never leaves
 *   the server.
 * - `pin_hash` — for staff who stand at a till. Syncs down to devices so a
 *   cashier can sign in with no network at all.
 *
 * A cashier gets a PIN and no password; an Owner usually has both. Requiring
 * one to set the other would either lock cashiers out of the till or hand every
 * one of them a Backoffice login.
 */
class StaffManager
{
    public function save(Employee $actor, array $data, ?string $id = null): Employee
    {
        return DB::transaction(function () use ($actor, $data, $id): Employee {
            $this->authorize($actor);

            $employee = $id ? Employee::query()->findOrFail($id) : new Employee;

            $values = Validator::make($data, [
                'name' => ['required', 'string', 'max:255'],
                'role' => ['required', Rule::enum(Role::class)],
                'active' => ['nullable', 'boolean'],
                'sort_order' => ['nullable', 'integer', 'min:0'],
                'email' => [
                    'nullable', 'email', 'max:255',
                    // Globally unique: Backoffice login resolves an account
                    // from the email alone, so the same address in two
                    // merchants would make "who is signing in" ambiguous.
                    Rule::unique('employees', 'email')->ignore($id),
                ],
                'password' => ['nullable', 'string', 'min:8'],
                'pin' => ['nullable', 'digits_between:4,6'],
            ])->validate();

            $pin = $values['pin'] ?? null;
            $password = $values['password'] ?? null;
            unset($values['pin'], $values['password']);

            $employee->fill($values);

            if ($password !== null) {
                $employee->password = $password;
            }

            if ($pin !== null) {
                $this->assertPinFree($pin, $id);
                $employee->setPin($pin);
            }

            $this->assertUsable($employee, changingPin: $pin !== null);

            $employee->save();

            return $employee;
        }, 3);
    }

    public function deactivate(Employee $actor, string $id): Employee
    {
        return DB::transaction(function () use ($actor, $id): Employee {
            $this->authorize($actor);

            $employee = Employee::query()->findOrFail($id);

            if ($employee->id === $actor->id) {
                // Not paranoia: an Owner who deactivates themselves locks the
                // only account that can reactivate anyone out of the Backoffice.
                throw ValidationException::withMessages([
                    'id' => 'You cannot deactivate your own account.',
                ]);
            }

            if ($employee->role === Role::Owner && $this->activeOwnerCount() <= 1) {
                throw ValidationException::withMessages([
                    'id' => 'This is the last active owner. Promote someone else first.',
                ]);
            }

            // Deactivated, not deleted — the same call the device already makes.
            // Their name is snapshotted onto past receipts and shifts, and those
            // must keep reading correctly.
            $employee->active = false;
            $employee->save();

            return $employee;
        }, 3);
    }

    /**
     * True when [$pin] is already in use by another active employee here.
     *
     * Iterating and hash-comparing rather than a `WHERE pin_hash = ?`, because
     * bcrypt is salted: the same PIN hashes differently every time, so
     * uniqueness genuinely cannot be an index. One merchant's staff is a small
     * set, so this stays cheap.
     *
     * It matters for the manager-override prompt specifically, which resolves
     * an approver from a PIN alone with no account chosen — a duplicate there
     * makes "who approved this" unanswerable.
     */
    private function assertPinFree(string $pin, ?string $exceptId): void
    {
        if (Employee::pinTakenWithinTenant($pin, $exceptId)) {
            throw ValidationException::withMessages([
                'pin' => 'Another active employee already uses this PIN.',
            ]);
        }
    }

    /**
     * Refuse an account nobody can actually sign into.
     *
     * A cashier with no PIN cannot reach the till; a manager or owner with
     * neither password nor PIN cannot reach anything. Saving one looks like it
     * worked and produces a person who cannot work.
     */
    private function assertUsable(Employee $employee, bool $changingPin): void
    {
        $hasPin = $changingPin || $employee->pin_hash !== null;
        $hasPassword = $employee->password !== null;

        if ($employee->role === Role::Cashier && ! $hasPin) {
            throw ValidationException::withMessages([
                'pin' => 'A cashier needs a PIN — it is the only way onto the till.',
            ]);
        }

        if (! $hasPin && ! $hasPassword) {
            throw ValidationException::withMessages([
                'password' => 'Set a PIN, a password, or both. This account could not sign in anywhere.',
            ]);
        }
    }

    private function activeOwnerCount(): int
    {
        return Employee::query()->active()->where('role', Role::Owner)->count();
    }

    private function authorize(Employee $actor): void
    {
        $context = app(TenantContext::class);
        $tenant = Tenant::query()->whereKey($context->requireId())->lockForUpdate()->firstOrFail();
        $context->set($tenant);

        $current = Employee::query()->find($actor->id);

        abort_unless(
            $current?->canAccessBackoffice()
                && $current->hasPermission(Permission::ManageEmployees)
                && $tenant->isActive(),
            403
        );
    }

    /** A PIN suggestion the form can offer — never stored or logged in plaintext. */
    public function suggestPin(): string
    {
        do {
            $pin = Str::padLeft((string) random_int(0, 9999), 4, '0');
        } while (Employee::pinTakenWithinTenant($pin));

        return $pin;
    }
}
