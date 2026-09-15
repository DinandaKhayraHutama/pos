<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * A till. Selling means being signed on to one.
 *
 * A register belongs to exactly one outlet, and its name is unique **per
 * outlet** — every branch is allowed its own "Kasir 1", and forcing
 * "Bintaro Kasir 1" onto the button a cashier taps forty times a shift is the
 * tail wagging the dog.
 *
 * `table_service` is per-register, not per-store: one counter can run the floor
 * plan while the takeaway till beside it does not.
 *
 * The unique index is on (outlet_id, name) rather than (tenant_id, name) so the
 * constraint matches the product rule exactly. `tenant_id` is still carried on
 * the row — every tenant-owned table has it, so the global scope is uniform and
 * a query never has to join through `outlets` just to be safely filtered.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('pos_registers', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('outlet_id')->constrained()->cascadeOnDelete();
            $table->string('name');
            $table->boolean('table_service')->default(true);
            $table->boolean('active')->default(true);
            $table->unsignedInteger('sort_order')->default(0);
            $table->timestamps();

            $table->unique(['outlet_id', 'name']);
            $table->index(['tenant_id', 'active']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('pos_registers');
    }
};
