<?php

declare(strict_types=1);

namespace App\Auth;

use App\Support\TenantContext;
use Illuminate\Auth\EloquentUserProvider;
use SensitiveParameter;

/**
 * Authentication resolves the employee BEFORE middleware knows their tenant.
 * Email is globally unique; session IDs and remember tokens identify one user.
 * Only these identity lookups cross tenants, never ordinary Employee queries.
 * Other scopes (including staff tombstones) and password checks remain intact.
 */
class EmployeeUserProvider extends EloquentUserProvider
{
    public function retrieveByCredentials(#[SensitiveParameter] array $credentials)
    {
        return app(TenantContext::class)->runUnscoped(
            fn () => parent::retrieveByCredentials($credentials)
        );
    }

    public function retrieveById($identifier)
    {
        return app(TenantContext::class)->runUnscoped(
            fn () => parent::retrieveById($identifier)
        );
    }

    public function retrieveByToken($identifier, #[SensitiveParameter] $token)
    {
        return app(TenantContext::class)->runUnscoped(
            fn () => parent::retrieveByToken($identifier, $token)
        );
    }
}
