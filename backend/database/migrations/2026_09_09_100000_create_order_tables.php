<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Sales, as the tills rang them up.
 *
 * The most consequential table in the system: these rows are money that
 * customers have already handed over. Three decisions here look odd next to the
 * catalogue tables and are all deliberate.
 *
 * **1. Almost nothing has a foreign key.** `product_id`, `employee_id`,
 * `table_id` are plain columns. A till sells offline for a day and pushes
 * afterwards; by then a product may have been deleted, a cashier may have left.
 * Rejecting the sale over that would be refusing to record something that
 * demonstrably happened. The device holds the same position for the same
 * reason — see `mobile/CLAUDE.md`, "a catalogue-consistency failure must never
 * abort a customer's sale".
 *
 * **2. Every snapshot column comes along.** `product_name`, `cashier_name`,
 * `outlet_name`, `pos_name`, `table_name`, and the tax and service-charge RATES
 * as well as their amounts. A receipt reprinted next year must read as it did
 * on the day, so nothing here is re-derived by joining — a rename would rewrite
 * history, and a changed PB1 rate would make an old receipt fail to add up.
 *
 * **3. Money is integer rupiah**, never float, matching the device exactly.
 *
 * No `sync_seq`: these travel up, never back down.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('orders', function (Blueprint $table) {
            // The till's UUID. Also the idempotency key — a retried push
            // updates this row rather than recording the sale twice.
            $table->uuid('id')->primary();

            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('outlet_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('pos_register_id')->nullable()
                ->constrained()->nullOnDelete();
            $table->foreignUuid('device_id')->nullable()
                ->constrained('devices')->nullOnDelete();

            // No FK: a session may be pushed after the orders that belong to
            // it, and an order must never be rejected for arriving first.
            $table->uuid('pos_session_id')->nullable();

            // The printed number. NOT unique: it is a label, counted per
            // register on a device that may be one of two on that register. The
            // id above is the key.
            $table->string('number');

            $table->timestamp('placed_at');
            $table->string('type');
            $table->string('status')->index();

            $table->uuid('table_id')->nullable();
            $table->string('table_name')->nullable();
            $table->string('customer_name')->nullable();
            $table->text('note')->nullable();

            $table->bigInteger('subtotal');
            $table->bigInteger('discount')->default(0);
            $table->bigInteger('tax')->default(0);            // PB1 amount
            $table->bigInteger('service_charge_amount')->default(0);
            $table->bigInteger('total');
            $table->bigInteger('amount_paid')->default(0);

            // The rates in force at the moment of sale, not today's. Null on a
            // row from a device that predates them — genuinely unrecoverable,
            // and honest as null rather than guessed.
            $table->double('pb1_rate')->nullable();
            $table->double('service_charge_rate')->nullable();

            $table->string('payment_method');
            $table->string('promo_name')->nullable();

            $table->uuid('cashier_id')->nullable();
            $table->string('cashier_name');
            $table->string('outlet_name')->nullable();
            $table->string('pos_name')->nullable();

            // Who approved a void or refund, and why. The audit trail the
            // Backoffice exists to surface.
            $table->string('authorized_by')->nullable();
            $table->text('void_reason')->nullable();
            $table->bigInteger('refunded_amount')->nullable();

            $table->timestamps();

            // Every report is "this merchant, this window", optionally narrowed
            // to one branch.
            $table->index(['tenant_id', 'placed_at']);
            $table->index(['tenant_id', 'outlet_id', 'placed_at']);
            $table->index(['tenant_id', 'pos_session_id']);
        });

        Schema::create('order_items', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('order_id')->constrained()->cascadeOnDelete();

            // Deliberately no FK — see the class note.
            $table->uuid('product_id')->nullable();
            $table->string('product_name');
            $table->string('variant_name')->nullable();

            $table->bigInteger('unit_price');
            $table->bigInteger('unit_cost')->nullable();
            $table->integer('quantity');
            $table->text('note')->nullable();

            // Snapshotted so the category breakdown keeps working after a
            // product is recategorised or deleted.
            $table->uuid('category_id')->nullable();
            $table->string('category_name')->nullable();

            $table->timestamps();

            $table->index(['tenant_id', 'product_id']);
            $table->index(['tenant_id', 'category_id']);
        });

        Schema::create('order_item_modifiers', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('order_item_id')->constrained()->cascadeOnDelete();

            // Names and prices only — this table has no ids into the catalogue
            // at all, on the device or here. What was chosen and what it cost
            // is the whole record.
            $table->string('group_name');
            $table->string('option_name');
            $table->bigInteger('price_delta')->default(0);
            $table->unsignedInteger('sort_order')->default(0);

            $table->timestamps();
        });

        // A line can never belong to another merchant's order.
        Schema::table('orders', fn (Blueprint $t) => $t->unique(['tenant_id', 'id']));
        Schema::table('order_items', function (Blueprint $t) {
            $t->unique(['tenant_id', 'id']);
            $t->foreign(['tenant_id', 'order_id'])->references(['tenant_id', 'id'])->on('orders');
        });
        Schema::table('order_item_modifiers', function (Blueprint $t) {
            $t->foreign(['tenant_id', 'order_item_id'])->references(['tenant_id', 'id'])->on('order_items');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('order_item_modifiers');
        Schema::dropIfExists('order_items');
        Schema::dropIfExists('orders');
    }
};
