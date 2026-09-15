<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * A branch the merchant trades from.
 *
 * An outlet is NOT a register: two tills at one counter share the shelf, the
 * tables and the menu and only need telling apart for attribution, while two
 * outlets share almost nothing. What is per-outlet (stock, floor plan, sales)
 * versus shared across the chain (menu, prices, promos, staff) is a product
 * decision that every later query has to respect, and the Flutter app already
 * encodes it — see `mobile/CLAUDE.md`, "Multi-outlet".
 *
 * Deactivated, never deleted: `orders.outlet_name` will be a snapshot copied at
 * checkout, so removing a row would not corrupt a past receipt, but it would
 * leave nothing for an Owner to switch back on when a branch reopens.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('outlets', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->string('name');
            $table->string('address')->nullable();
            $table->string('phone')->nullable();
            $table->boolean('active')->default(true);
            $table->unsignedInteger('sort_order')->default(0);
            $table->timestamps();

            // Per tenant, not global: two unrelated merchants are both entitled
            // to a branch called "Pusat".
            $table->unique(['tenant_id', 'name']);
            $table->index(['tenant_id', 'active']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('outlets');
    }
};
