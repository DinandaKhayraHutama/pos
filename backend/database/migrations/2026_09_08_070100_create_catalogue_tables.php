<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * The menu. The first data that actually travels to a till.
 *
 * Shared across the chain, not per outlet — the Flutter app already draws that
 * line (`mobile/CLAUDE.md`, "Multi-outlet"): menu, prices and variants are the
 * business's, while stock and sales belong to a branch. Nothing here carries an
 * `outlet_id` for that reason.
 *
 * Column names and types mirror the device's SQLite schema deliberately, so a
 * pulled row can be written straight through the repository that already
 * exists rather than through a translation layer nobody would keep in step.
 * Money stays **integer rupiah**, never float.
 *
 * Every table gets the same three sync columns:
 * - `tenant_id` — the isolation boundary, on every row without exception.
 * - `sync_seq`  — the cursor devices page through.
 * - `deleted_at` — a tombstone, because "this product is gone" is a change a
 *   till has to receive, not an absence it could ever infer.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('categories', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->string('name');
            $table->string('icon_key')->nullable();
            $table->unsignedInteger('sort_order')->default(0);
            $table->boolean('is_popular')->default(false);
            $this->syncColumns($table);
        });

        Schema::create('products', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('category_id')->constrained()->cascadeOnDelete();
            $table->string('name');
            $table->bigInteger('price');
            $table->bigInteger('cost')->nullable();
            $table->string('sku')->nullable();

            // Nullable on purpose, and NOT the same as zero: null means "use the
            // store's PB1 rate", 0.0 means "genuinely zero-rated". Collapsing
            // the two would silently start taxing exempt items.
            $table->double('tax_rate')->nullable();

            $table->text('description')->nullable();
            $table->string('image_url')->nullable();
            $table->string('icon_key')->default('restaurant');
            $table->boolean('available')->default(true);
            $table->boolean('is_popular')->default(false);
            $table->unsignedInteger('sort_order')->default(0);
            $this->syncColumns($table);
        });

        Schema::create('product_variants', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('product_id')->constrained()->cascadeOnDelete();
            $table->string('name');
            // Signed: a smaller size is a negative delta.
            $table->bigInteger('price_delta')->default(0);
            $table->unsignedInteger('sort_order')->default(0);
            $this->syncColumns($table);
        });

        // A device pulling is always the same shape of query — "this tenant,
        // after this seq, in seq order" — so that is the index every one of
        // these tables gets.
        foreach (['categories', 'products', 'product_variants'] as $name) {
            Schema::table($name, fn (Blueprint $t) => $t->index(['tenant_id', 'sync_seq']));
        }

        // Composite keys so a product can never point at another merchant's
        // category, the same structural guarantee devices/registers already got.
        Schema::table('categories', fn (Blueprint $t) => $t->unique(['tenant_id', 'id']));
        Schema::table('products', function (Blueprint $t) {
            $t->unique(['tenant_id', 'id']);
            $t->foreign(['tenant_id', 'category_id'])->references(['tenant_id', 'id'])->on('categories');
        });
        Schema::table('product_variants', function (Blueprint $t) {
            $t->foreign(['tenant_id', 'product_id'])->references(['tenant_id', 'id'])->on('products');
        });
    }

    private function syncColumns(Blueprint $table): void
    {
        $table->unsignedBigInteger('sync_seq')->default(0);
        $table->timestamp('deleted_at')->nullable();
        $table->timestamps();
    }

    public function down(): void
    {
        Schema::dropIfExists('product_variants');
        Schema::dropIfExists('products');
        Schema::dropIfExists('categories');
    }
};
