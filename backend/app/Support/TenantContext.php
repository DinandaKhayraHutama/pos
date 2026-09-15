<?php

declare(strict_types=1);

namespace App\Support;

use App\Models\Tenant;
use RuntimeException;

/**
 * Which merchant the current request belongs to.
 *
 * Resolved ONCE per request (from the authenticated Backoffice employee, or
 * later from a device's API token) and read from here by the global scope that
 * filters every tenant-owned query. Deliberately not passed as an argument
 * through the call stack: an argument can be forgotten at one call site, and
 * one forgotten filter is a cross-tenant data leak.
 *
 * Registered as a singleton, so "the current tenant" cannot differ between two
 * objects handling the same request.
 */
class TenantContext
{
    private ?Tenant $tenant = null;

    /**
     * True while no tenant is resolved.
     *
     * This is a legitimate state, not an error: platform staff acting on
     * `tenants` themselves, console commands, and migrations all run outside
     * any tenant.
     */
    private bool $unscoped = false;

    public function set(Tenant $tenant): void
    {
        $this->tenant = $tenant;
        $this->unscoped = false;
    }

    public function clear(): void
    {
        $this->tenant = null;
        $this->unscoped = false;
    }

    public function current(): ?Tenant
    {
        return $this->tenant;
    }

    public function id(): ?string
    {
        return $this->tenant?->id;
    }

    public function hasTenant(): bool
    {
        return $this->tenant !== null;
    }

    /**
     * The tenant id, or a hard failure.
     *
     * Used where a missing tenant can only be a bug — writing a tenant-owned
     * row, for instance. Failing loudly here is the point: the alternative is a
     * row written with a null tenant_id, which no scope will ever return again
     * and which nobody notices until a report comes up short.
     */
    public function requireId(): string
    {
        $id = $this->id();

        if ($id === null) {
            throw new RuntimeException(
                'No tenant is resolved for this operation. Either authenticate as '
                .'an employee, or wrap the call in TenantContext::runUnscoped() if '
                .'it genuinely spans tenants.'
            );
        }

        return $id;
    }

    public function isUnscoped(): bool
    {
        return $this->unscoped;
    }

    /**
     * Run a callback with tenant filtering switched off.
     *
     * The escape hatch for the handful of operations that genuinely span
     * merchants: platform staff listing every business, a scheduled job
     * sweeping all tenants. Explicit and greppable on purpose — an audit of
     * "what can read across tenants" is a search for this one method.
     */
    public function runUnscoped(callable $callback): mixed
    {
        $previousTenant = $this->tenant;
        $previousUnscoped = $this->unscoped;

        $this->tenant = null;
        $this->unscoped = true;

        try {
            return $callback();
        } finally {
            $this->tenant = $previousTenant;
            $this->unscoped = $previousUnscoped;
        }
    }

    /**
     * Run a callback as a specific tenant, restoring the previous one after.
     *
     * Used by console commands and jobs that act for one merchant at a time.
     */
    public function runAs(Tenant $tenant, callable $callback): mixed
    {
        $previousTenant = $this->tenant;
        $previousUnscoped = $this->unscoped;

        $this->set($tenant);

        try {
            return $callback();
        } finally {
            $this->tenant = $previousTenant;
            $this->unscoped = $previousUnscoped;
        }
    }
}
