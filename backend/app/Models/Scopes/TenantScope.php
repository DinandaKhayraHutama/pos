<?php

declare(strict_types=1);

namespace App\Models\Scopes;

use App\Models\Concerns\BelongsToTenant;
use App\Support\TenantContext;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Scope;

/**
 * Adds `WHERE tenant_id = ?` to every query on a tenant-owned model.
 *
 * Automatic rather than hand-written per query, because the failure mode of
 * the hand-written version is silent: one query missing its filter returns
 * another merchant's rows and nothing anywhere goes red.
 *
 * When no tenant is resolved the scope does NOT quietly fall through to
 * returning everything. That is the single most dangerous default this class
 * could have — a forgotten `TenantContext::set()` would turn every listing in
 * the app into a cross-tenant one. Instead:
 *
 * - inside `TenantContext::runUnscoped()`, filtering is skipped deliberately;
 * - otherwise the query is constrained to match nothing, so a missing tenant
 *   produces an empty result rather than everybody's data.
 *
 * "Empty" is chosen over "throw" because reads happen in places that must not
 * blow up (a health check, a queued job with no tenant). Writes are where the
 * loud failure lives — see {@see BelongsToTenant}.
 */
class TenantScope implements Scope
{
    public function apply(Builder $builder, Model $model): void
    {
        $context = app(TenantContext::class);

        if ($context->isUnscoped()) {
            return;
        }

        $tenantId = $context->id();

        if ($tenantId === null) {
            // Match nothing. Deliberately not `return`, which would leak.
            $builder->whereRaw('1 = 0');

            return;
        }

        $builder->where($model->qualifyColumn('tenant_id'), $tenantId);
    }
}
