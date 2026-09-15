<?php

declare(strict_types=1);

namespace App\Models\Concerns;

use App\Models\Scopes\TenantScope;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use RuntimeException;

/**
 * Marks a model as owned by exactly one merchant.
 *
 * Applying this trait is the ONLY thing a tenant-owned model has to do: reads
 * are filtered by {@see TenantScope}, and writes get their `tenant_id` filled
 * in automatically. No controller, service or Filament resource should ever
 * type `where('tenant_id', ...)` by hand — a filter that has to be remembered
 * is a filter that will eventually be forgotten.
 *
 * @property string $tenant_id
 */
trait BelongsToTenant
{
    public static function bootBelongsToTenant(): void
    {
        static::addGlobalScope(new TenantScope);

        static::saving(function (Model $model): void {
            $context = app(TenantContext::class);
            if ($model->exists && $model->isDirty('tenant_id')) {
                throw new RuntimeException('Tenant ownership is immutable.');
            }
            if ($context->hasTenant() && $model->getAttribute('tenant_id') !== null
                && $model->getAttribute('tenant_id') !== $context->id()) {
                throw new RuntimeException('Cannot write a row belonging to another tenant.');
            }
        });

        static::creating(function (Model $model): void {
            if ($model->getAttribute('tenant_id') !== null) {
                return;
            }

            $context = app(TenantContext::class);

            if ($context->isUnscoped()) {
                // An unscoped write must name its tenant explicitly. Guessing
                // one here is how a row lands under the wrong merchant.
                throw new RuntimeException(sprintf(
                    'Cannot create %s while unscoped without an explicit tenant_id.',
                    $model::class
                ));
            }

            // Throws when no tenant is resolved. Loud on purpose: a row written
            // with a null tenant_id is a row no scope will ever return again.
            $model->setAttribute('tenant_id', $context->requireId());
        });
    }

    public function tenant(): BelongsTo
    {
        return $this->belongsTo(Tenant::class);
    }
}
