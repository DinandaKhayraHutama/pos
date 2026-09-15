<?php

declare(strict_types=1);

namespace App\Domain\Sync;

use Illuminate\Support\Facades\DB;
use RuntimeException;

/**
 * Allocates the next `sync_seq` for a merchant.
 *
 * ## Why this must run inside the writer's transaction
 *
 * The obvious implementation — hand out a number, then write the row — has a
 * silent data-loss bug under concurrency:
 *
 * 1. Writer A takes seq 10, and is slow to commit.
 * 2. Writer B takes seq 11, and commits immediately.
 * 3. A device pulls, sees only row B, and moves its cursor to 11.
 * 4. Writer A finally commits. Row 10 is now visible — but the device is
 *    already past it and will never ask for it again.
 *
 * The product disappears from one till and nobody finds out until someone tries
 * to sell it.
 *
 * `INSERT … ON CONFLICT DO UPDATE … RETURNING` fixes this precisely because
 * PostgreSQL holds the counter row's exclusive lock until the surrounding
 * transaction ENDS. Writer B therefore cannot take 11 until writer A has
 * committed 10, so a device can never observe a gap that later fills in.
 *
 * That guarantee only exists if allocation and the row write share one
 * transaction — hence {@see Syncable::save()} opens one when the caller has
 * not, and this method refuses to run without it rather than quietly returning
 * a number whose ordering means nothing.
 */
class SyncCursor
{
    public static function next(string $tenantId): int
    {
        if (DB::transactionLevel() === 0) {
            throw new RuntimeException(
                'SyncCursor::next() must run inside a transaction, or the counter '
                .'lock is released before the row it numbers is committed — which '
                .'lets a device skip past a row it never received.'
            );
        }

        $row = DB::selectOne(
            'INSERT INTO tenant_sync_counters (tenant_id, last_seq)
             VALUES (?, 1)
             ON CONFLICT (tenant_id)
             DO UPDATE SET last_seq = tenant_sync_counters.last_seq + 1
             RETURNING last_seq',
            [$tenantId]
        );

        return (int) $row->last_seq;
    }

    /**
     * The merchant's current high-water mark, without advancing it.
     *
     * Only for reporting — never as a cursor a device is handed, because a
     * value read outside a write transaction can be stale the moment it
     * returns.
     */
    public static function current(string $tenantId): int
    {
        return (int) (DB::table('tenant_sync_counters')
            ->where('tenant_id', $tenantId)
            ->value('last_seq') ?? 0);
    }
}
