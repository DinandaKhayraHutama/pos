<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Staff accounts join the delta feed, so a till can be signed into offline with
 * credentials the Owner set in a browser.
 *
 * The backfill below is the whole reason this is not a two-line migration.
 * `sync_seq` defaults to 0, and a device pulls everything **greater than** its
 * cursor — which also starts at 0. Every employee that already exists would
 * therefore be permanently invisible to every device: no error, no empty
 * result to notice, just a till nobody can sign into. Existing rows have to be
 * given real numbers, and they have to come from the same per-tenant counter
 * every later write uses, or the sequence stops being monotonic.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::table('employees', function (Blueprint $table) {
            $table->unsignedBigInteger('sync_seq')->default(0);
            $table->timestamp('deleted_at')->nullable();
            $table->index(['tenant_id', 'sync_seq']);
        });

        $this->numberExistingEmployees();
    }

    /**
     * Give every existing row a place in its merchant's sequence.
     *
     * Ordered by `created_at` then `id` so the result is deterministic — a
     * re-run on a copy of the database produces the same numbering, which
     * matters when comparing two environments.
     */
    private function numberExistingEmployees(): void
    {
        $tenantIds = DB::table('employees')->distinct()->pluck('tenant_id');

        foreach ($tenantIds as $tenantId) {
            $ids = DB::table('employees')
                ->where('tenant_id', $tenantId)
                ->orderBy('created_at')
                ->orderBy('id')
                ->pluck('id');

            foreach ($ids as $id) {
                // One statement, so the counter and the row it numbers cannot
                // drift apart — the same allocation SyncCursor performs.
                $seq = DB::selectOne(
                    'INSERT INTO tenant_sync_counters (tenant_id, last_seq)
                     VALUES (?, 1)
                     ON CONFLICT (tenant_id)
                     DO UPDATE SET last_seq = tenant_sync_counters.last_seq + 1
                     RETURNING last_seq',
                    [$tenantId]
                )->last_seq;

                DB::table('employees')->where('id', $id)->update(['sync_seq' => $seq]);
            }
        }
    }

    public function down(): void
    {
        Schema::table('employees', function (Blueprint $table) {
            $table->dropIndex(['tenant_id', 'sync_seq']);
            $table->dropColumn(['sync_seq', 'deleted_at']);
        });
    }
};
