<?php

declare(strict_types=1);

use App\Domain\Sync\SyncCursor;
use App\Models\Category;
use App\Models\Employee;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\DB;

/**
 * The transaction guarantee behind every sync cursor.
 *
 * These live in the Concurrency suite for one reason: it uses
 * `DatabaseMigrations`, so a test is NOT wrapped in an ambient transaction.
 * Under the Feature suite's `RefreshDatabase`, `transactionLevel()` is never
 * zero, the guard below can never fire, and the bare-save path that production
 * actually takes would go untested while appearing covered.
 */
beforeEach(function () {
    $this->tenant = Tenant::factory()->create();
    $this->context = app(TenantContext::class);
    $this->context->set($this->tenant);
    Employee::factory()->owner()->create(['tenant_id' => $this->tenant->id]);
});

afterEach(fn () => $this->context->clear());

it('refuses to allocate a sequence with no transaction open', function () {
    expect(DB::transactionLevel())->toBe(0);

    // Allocating here would release the counter's row lock immediately, letting
    // a later writer publish a higher sequence before this one commits — and a
    // device that moved its cursor past the gap never asks for the row again.
    SyncCursor::next($this->tenant->id);
})->throws(RuntimeException::class);

it('opens its own transaction for a bare save', function () {
    expect(DB::transactionLevel())->toBe(0);

    // No surrounding DB::transaction(): Syncable::save() has to supply one, or
    // every write outside a domain service would hit the guard above.
    $category = new Category(['name' => 'Makanan']);
    $category->save();

    expect($category->sync_seq)->toBeGreaterThan(0)
        ->and(DB::transactionLevel())->toBe(0);
});

it('keeps the sequence monotonic across separate bare saves', function () {
    $first = new Category(['name' => 'Makanan']);
    $first->save();

    $second = new Category(['name' => 'Minuman']);
    $second->save();

    expect($second->sync_seq)->toBeGreaterThan($first->sync_seq);
});

it('does not advance the counter when the write rolls back', function () {
    $before = SyncCursor::current($this->tenant->id);

    try {
        DB::transaction(function (): void {
            (new Category(['name' => 'Makanan']))->save();
            throw new RuntimeException('rolled back');
        });
    } catch (RuntimeException) {
        // expected
    }

    // The counter is part of the same transaction, so a failed write leaves no
    // consumed number behind — and, more importantly, no row a device is told
    // about that does not exist.
    expect(SyncCursor::current($this->tenant->id))->toBe($before)
        ->and(Category::query()->count())->toBe(0);
});
