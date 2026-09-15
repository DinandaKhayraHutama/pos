<?php

declare(strict_types=1);

namespace App\Models\Concerns;

use App\Domain\Sync\SyncCursor;
use App\Support\TenantContext;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;

/**
 * Marks a model as something devices pull down.
 *
 * Two things happen automatically, and neither is safe to do by hand at each
 * call site:
 *
 * - **Every write takes a new `sync_seq`.** Including updates — a price change
 *   has to travel, and a row that keeps its old number is a change no device
 *   will ever ask for again.
 * - **Deletes are tombstones, not removals.** `delete()` stamps `deleted_at`
 *   and takes a fresh `sync_seq`, so the deletion itself is a change a device
 *   can receive. A row that simply vanished from the server would linger on
 *   every till forever, because "gone" is not something a delta can express.
 *
 * Tombstones are excluded from normal reads by a global scope, so Backoffice
 * screens behave as if the row is gone. Only the sync endpoint asks for them.
 *
 * @property int $sync_seq
 * @property Carbon|null $deleted_at
 */
trait Syncable
{
    public static function bootSyncable(): void
    {
        static::addGlobalScope('notTombstoned', function (Builder $builder) {
            $builder->whereNull($builder->getModel()->qualifyColumn('deleted_at'));
        });

        static::saving(function (Model $model): void {
            // On a create, `tenant_id` is NOT set yet: Eloquent fires
            // `saving` before `creating`, and `creating` is where
            // {@see BelongsToTenant} stamps it. Reading the attribute alone
            // would hand a null to the counter on every insert, so the resolved
            // tenant is the fallback — the same one that is about to be stamped.
            $tenantId = $model->getAttribute('tenant_id')
                ?? app(TenantContext::class)->requireId();

            $model->setAttribute('sync_seq', SyncCursor::next($tenantId));
        });
    }

    /**
     * Always writes inside a transaction.
     *
     * Not a convenience: {@see SyncCursor::next()} depends on the counter's row
     * lock surviving until this row is committed, and a bare `save()` outside a
     * transaction releases it immediately.
     */
    public function save(array $options = []): bool
    {
        if (DB::transactionLevel() > 0) {
            return parent::save($options);
        }

        return DB::transaction(fn (): bool => parent::save($options));
    }

    /**
     * Tombstone rather than remove.
     *
     * Goes through `save()` so the deletion takes a `sync_seq` like any other
     * change — that number is the only reason a till ever learns the row is
     * gone.
     */
    public function delete(): bool
    {
        $this->setAttribute('deleted_at', now());

        return $this->save();
    }

    /** Include tombstones. Only the sync endpoint has a reason to. */
    public function scopeWithTombstones(Builder $query): Builder
    {
        return $query->withoutGlobalScope('notTombstoned');
    }

    public function isTombstoned(): bool
    {
        return $this->getAttribute('deleted_at') !== null;
    }
}
