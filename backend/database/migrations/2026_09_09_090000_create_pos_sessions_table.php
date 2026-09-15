<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * A cash drawer session, pushed up by the till that opened it.
 *
 * The first table whose rows are AUTHORED ON A DEVICE. Everything before this
 * was written in the Backoffice and pulled down; these arrive already created,
 * with an id the tablet chose, possibly hours after the fact.
 *
 * Three consequences of that, all visible in the schema:
 *
 * - **No `sync_seq`.** That column exists so devices can page through server
 *   changes. Sessions travel the other way and are never pulled back, so a
 *   counter would be bookkeeping nobody reads.
 * - **Every snapshot column comes along** (`employee_name`, `pos_name`,
 *   `outlet_name`, `closed_by_name`). They are stored rather than re-derived by
 *   joining, so a closed drawer keeps naming whoever actually counted it even
 *   after that person is renamed or leaves — the same rule the device follows.
 * - **`opened_at` / `closed_at` are the DEVICE's clock**, kept as the till
 *   recorded them. `created_at` is the server's. Both matter: one is when the
 *   drawer was really opened, the other is when we first heard about it, and a
 *   reconciliation needs to tell those apart.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('pos_sessions', function (Blueprint $table) {
            // Chosen by the device, so a retry of the same push is recognisably
            // the same session rather than a second drawer.
            $table->uuid('id')->primary();

            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('outlet_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('pos_register_id')->constrained()->cascadeOnDelete();

            // Which tablet sent it. Not the same question as which register it
            // belongs to: a register outlives the tablet standing at it.
            $table->foreignUuid('device_id')->nullable()
                ->constrained('devices')->nullOnDelete();

            // No FK: a session names the cashier who opened it, and that person
            // may since have been deleted. The snapshot is what a report reads.
            $table->uuid('employee_id')->nullable();
            $table->string('employee_name');
            $table->string('pos_name')->nullable();
            $table->string('outlet_name')->nullable();

            $table->timestamp('opened_at');
            $table->bigInteger('opening_cash');

            $table->timestamp('closed_at')->nullable();
            $table->bigInteger('counted_cash')->nullable();
            $table->bigInteger('expected_cash')->nullable();
            $table->uuid('closed_by_id')->nullable();
            $table->string('closed_by_name')->nullable();
            $table->text('note')->nullable();

            $table->timestamps();

            $table->index(['tenant_id', 'opened_at']);
            $table->index(['tenant_id', 'outlet_id', 'opened_at']);
        });

        // The device enforces one open drawer per till with a partial unique
        // index; the server mirrors it so a second tablet cannot open a session
        // on a register that already has one. Partial, because a register
        // accumulates any number of CLOSED sessions.
        DB::statement(
            'CREATE UNIQUE INDEX pos_sessions_one_open_per_register
             ON pos_sessions (pos_register_id)
             WHERE closed_at IS NULL'
        );

        // A session pointing at another merchant's register must be impossible
        // in the database, not merely unlikely in the code — same composite-key
        // guarantee devices and registers already have.
        Schema::table('pos_sessions', function (Blueprint $table) {
            $table->foreign(['tenant_id', 'outlet_id', 'pos_register_id'], 'pos_sessions_register_context_fk')
                ->references(['tenant_id', 'outlet_id', 'id'])->on('pos_registers');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('pos_sessions');
    }
};
