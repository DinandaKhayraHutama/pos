<?php

declare(strict_types=1);

namespace App\Domain\Tenancy;

use App\Domain\Auth\Role;
use App\Models\Employee;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use InvalidArgumentException;

/**
 * Creates a merchant and its first Owner.
 *
 * A domain service rather than logic inside the console command, because this
 * is called from two surfaces already (the `tenant:create` command today, a
 * platform-admin screen later) and both must produce an identical result. The
 * command is a thin shell around this.
 *
 * The two writes happen in ONE transaction on purpose: a tenant with no owner
 * is a business nobody can sign into, and it would look successfully created.
 */
class TenantProvisioner
{
    public function __construct(private readonly TenantContext $context) {}

    /**
     * @return array{tenant: Tenant, owner: Employee}
     */
    public function provision(
        string $businessName,
        string $ownerName,
        string $ownerEmail,
        string $ownerPassword,
        ?string $slug = null,
    ): array {
        $email = Str::lower(trim($ownerEmail));

        // Checked before the transaction so the failure is a clean message
        // rather than a database constraint violation surfacing as a 500.
        // Unscoped: email is globally unique, so the conflict we care about is
        // with ANY tenant's staff, not just the one being created.
        $emailTaken = $this->context->runUnscoped(
            fn (): bool => Employee::query()->where('email', $email)->exists()
        );

        if ($emailTaken) {
            throw new InvalidArgumentException("The email {$email} is already in use.");
        }

        return DB::transaction(function () use ($businessName, $ownerName, $email, $ownerPassword, $slug): array {
            $tenant = Tenant::create([
                'name' => $businessName,
                'slug' => $slug ?? $this->uniqueSlug($businessName),
                'status' => Tenant::STATUS_ACTIVE,
            ]);

            // Written with an explicit tenant_id rather than by resolving the
            // context: this runs from the console, where no tenant is current,
            // and BelongsToTenant deliberately refuses to guess one.
            $owner = Employee::create([
                'tenant_id' => $tenant->id,
                'name' => $ownerName,
                'email' => $email,
                'password' => $ownerPassword,
                'role' => Role::Owner,
                'active' => true,
            ]);

            return ['tenant' => $tenant, 'owner' => $owner];
        });
    }

    private function uniqueSlug(string $businessName): string
    {
        $base = Str::slug($businessName) ?: 'merchant';

        // Unscoped for the same reason as the email check: slugs are unique
        // across the platform, not within one merchant.
        return $this->context->runUnscoped(function () use ($base): string {
            $slug = $base;
            $suffix = 2;

            while (Tenant::query()->where('slug', $slug)->exists()) {
                $slug = "{$base}-{$suffix}";
                $suffix++;
            }

            return $slug;
        });
    }
}
