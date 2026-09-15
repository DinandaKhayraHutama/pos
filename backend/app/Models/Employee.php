<?php

declare(strict_types=1);

namespace App\Models;

use App\Domain\Auth\Permission;
use App\Domain\Auth\Role;
use App\Models\Concerns\BelongsToTenant;
use App\Models\Concerns\Syncable;
use Database\Factories\EmployeeFactory;
use Filament\Models\Contracts\FilamentUser;
use Filament\Models\Contracts\HasName;
use Filament\Panel;
use Illuminate\Contracts\Auth\Authenticatable as AuthenticatableContract;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Support\Facades\Hash;

/**
 * A merchant's staff member, and the account behind the Backoffice panel.
 *
 * One row per person: the same human is the Owner who signs into the browser
 * and the name that lands on a receipt. Which credential they hold is what
 * differs, not which table they live in — see the migration for why both are
 * nullable.
 *
 * @property string $id
 * @property string $tenant_id
 * @property string $name
 * @property string|null $email
 * @property string|null $pin_hash
 * @property Role $role
 * @property bool $active
 */
class Employee extends Authenticatable implements AuthenticatableContract, FilamentUser, HasName
{
    /** @use HasFactory<EmployeeFactory> */
    use BelongsToTenant;

    use HasFactory;
    use HasUuids;

    // Staff sync down to tills so a cashier can be signed in offline. Only the
    // PIN hash travels — never `password`, which is a browser credential a till
    // has no use for. See SyncRegistry's column list.
    use Syncable;

    protected $fillable = [
        'tenant_id',
        'name',
        'email',
        'password',
        'pin_hash',
        'role',
        'active',
        'sort_order',
    ];

    protected $hidden = ['password', 'pin_hash', 'remember_token'];

    protected function casts(): array
    {
        return [
            'role' => Role::class,
            'active' => 'boolean',
            'password' => 'hashed',
            'deleted_at' => 'datetime',
        ];
    }

    // ---------------------------------------------------------------- scopes

    public function scopeActive(Builder $query): Builder
    {
        return $query->where('active', true);
    }

    // ----------------------------------------------------------- permissions

    /**
     * True when this employee's role grants [$permission].
     *
     * Screens and endpoints ask this, never `role === Role::Manager`. A role
     * comparison is a bug waiting for the fourth role, and it is also how a
     * surface quietly keeps working for someone who should have lost it.
     */
    public function hasPermission(Permission $permission): bool
    {
        if (! $this->active) {
            return false;
        }

        return $this->role->grants($permission);
    }

    /** @return list<string> */
    public function permissionValues(): array
    {
        return $this->active ? $this->role->permissionValues() : [];
    }

    public function canAuthorizeOverrides(): bool
    {
        return $this->active && $this->role->canAuthorizeOverrides();
    }

    // ------------------------------------------------------------------ PINs

    /**
     * Verify a till PIN against this ONE employee.
     *
     * Scoped to a single row on purpose. The device's sign-in picks the account
     * first and then checks the PIN against that choice — verifying globally
     * would let someone tap one name, type another person's PIN, and be signed
     * in as them, which makes the choice theatre.
     */
    public function verifyPin(string $pin): bool
    {
        if (! $this->active || $this->pin_hash === null) {
            return false;
        }

        return Hash::check($pin, $this->pin_hash);
    }

    public function setPin(?string $pin): void
    {
        $this->pin_hash = $pin === null ? null : Hash::make($pin);
    }

    /**
     * True when another active employee of the same tenant already uses [$pin].
     *
     * Iterating and hash-comparing rather than a `WHERE pin_hash = ?`, because
     * bcrypt is salted: the same PIN produces a different hash every time, so
     * uniqueness genuinely cannot be expressed as a unique index or a lookup.
     * The set being scanned is one merchant's staff, so this stays small.
     *
     * Uniqueness matters for the manager-override prompt specifically, which
     * resolves an approver from a PIN alone with no account chosen.
     */
    public static function pinTakenWithinTenant(string $pin, ?string $exceptId = null): bool
    {
        return static::query()
            ->active()
            ->whereNotNull('pin_hash')
            ->when($exceptId !== null, fn (Builder $q) => $q->whereKeyNot($exceptId))
            ->get(['id', 'pin_hash'])
            ->contains(fn (self $employee): bool => Hash::check($pin, (string) $employee->pin_hash));
    }

    // -------------------------------------------------------------- gateways

    /**
     * Whether this account may open the web Backoffice.
     *
     * Three independent conditions, all required: the account is live, the role
     * is one the Backoffice is for, and a browser password was actually set.
     */
    public function canAccessBackoffice(): bool
    {
        return $this->active
            && $this->role->usesBackoffice()
            && $this->password !== null;
    }

    /**
     * Filament's door check, delegating to the one above.
     *
     * Filament calls this AFTER a password has already been accepted, so it is
     * the difference between "these credentials are real" and "this person
     * belongs in this panel" — a deactivated Owner still has a valid password.
     */
    public function canAccessPanel(Panel $panel): bool
    {
        return match ($panel->getId()) {
            'backoffice' => $this->canAccessBackoffice(),
            default => false,
        };
    }

    public function getFilamentName(): string
    {
        return $this->name;
    }
}
