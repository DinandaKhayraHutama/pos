<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * One monotonic counter per merchant. The spine of every sync cursor.
 *
 * A device asks "what changed after 412?" and gets rows in `sync_seq` order.
 * That number is deliberately NOT a timestamp: two tablets and a server never
 * agree on the clock to the millisecond, and the Flutter schema has no
 * `updated_at` anywhere to fall back on. A counter the server alone advances
 * has neither problem.
 *
 * Per tenant rather than global so one busy merchant's edits do not inflate
 * every other merchant's cursor, and so a merchant's stream stays readable when
 * debugging.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('tenant_sync_counters', function (Blueprint $table) {
            $table->foreignUuid('tenant_id')->primary()->constrained()->cascadeOnDelete();
            $table->unsignedBigInteger('last_seq')->default(0);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('tenant_sync_counters');
    }
};
