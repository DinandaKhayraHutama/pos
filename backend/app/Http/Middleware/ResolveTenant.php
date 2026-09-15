<?php

declare(strict_types=1);

namespace App\Http\Middleware;

use App\Models\Employee;
use App\Support\TenantContext;
use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Puts the signed-in employee's merchant into {@see TenantContext}.
 *
 * The single place a tenant is resolved for a web request. Everything
 * downstream — every Eloquent read, every write — is filtered from what this
 * sets, which is why it must run before any tenant-owned query and why no
 * controller resolves a tenant for itself.
 *
 * The tenant is taken from the authenticated account, never from the request
 * (no `?tenant=` parameter, no subdomain trusted on its own). A tenant id that
 * arrives in user-controlled input is an invitation to read someone else's
 * data by editing a URL.
 */
class ResolveTenant
{
    public function __construct(private readonly TenantContext $context) {}

    public function handle(Request $request, Closure $next): Response
    {
        $this->context->clear();
        try {
            $employee = $request->user('backoffice');

            if ($employee instanceof Employee) {
                // Relation load rather than a bare id: downstream surfaces show the
                // business name, and a suspended merchant has to be detectable.
                $tenant = $employee->tenant;

                if ($tenant !== null) {
                    $this->context->set($tenant);
                }
            }

            return $next($request);
        } finally {
            // Cleared even on an exception. The context is a singleton, and a
            // queue worker or test process reusing the container must not
            // inherit the previous request's merchant.
            $this->context->clear();
        }
    }
}
