<?php

declare(strict_types=1);

use App\Domain\Catalogue\CatalogueManager;
use App\Domain\Devices\DeviceActivation;
use App\Domain\Staff\StaffManager;
use App\Domain\Sync\CataloguePuller;
use App\Domain\Sync\SyncCursor;
use App\Models\Category;
use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Product;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;
use Symfony\Component\HttpKernel\Exception\HttpException;

/**
 * The catalogue delta feed.
 *
 * The failure modes here are all silent: a product that never reaches a till,
 * a deletion that never lands, or one merchant's menu appearing on another's
 * device. None of them raise an error anywhere, so each gets a case.
 */
beforeEach(function () {
    $this->context = app(TenantContext::class);
    $this->catalogue = app(CatalogueManager::class);
    $this->puller = app(CataloguePuller::class);

    $this->tenant = Tenant::create(['name' => 'Warung A', 'slug' => 'warung-a']);
    $this->owner = Employee::factory()->owner()->create([
        'tenant_id' => $this->tenant->id, 'email' => 'a@example.test',
    ]);
    $this->context->set($this->tenant);
});

afterEach(fn () => $this->context->clear());

function makeCategory(string $name = 'Makanan'): Category
{
    return test()->catalogue->saveCategory(test()->owner, ['name' => $name]);
}

function makeProduct(Category $category, string $name, int $price = 15000): Product
{
    return test()->catalogue->saveProduct(test()->owner, [
        'name' => $name, 'category_id' => $category->id, 'price' => $price,
    ]);
}

// ---------------------------------------------------------------- sequencing

it('gives every write a higher sequence than the last', function () {
    $a = makeCategory('Makanan');
    $b = makeCategory('Minuman');

    expect($b->sync_seq)->toBeGreaterThan($a->sync_seq);
});

it('advances the sequence on an update, not only on create', function () {
    $product = makeProduct(makeCategory(), 'Nasi Goreng');
    $created = $product->sync_seq;

    $this->catalogue->saveProduct($this->owner, [
        'name' => 'Nasi Goreng', 'category_id' => $product->category_id, 'price' => 18000,
    ], $product->id);

    // A price change that kept its old number is a change no device would ever
    // ask for again.
    expect($product->fresh()->sync_seq)->toBeGreaterThan($created);
});

it('counts per merchant, so one busy tenant does not inflate another', function () {
    makeCategory('Makanan');
    makeCategory('Minuman');

    $other = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);
    $otherOwner = $this->context->runAs($other, fn () => Employee::factory()->owner()->create([
        'tenant_id' => $other->id, 'email' => 'b@example.test',
    ]));

    $mine = $this->context->runAs($this->tenant, fn () => SyncCursor::current($this->tenant->id));
    $theirs = $this->context->runAs(
        $other,
        fn () => $this->catalogue->saveCategory($otherOwner, ['name' => 'Kopi'])
    );

    // Asserted as "far behind mine" rather than a literal 1: staff are syncable
    // too, so the exact starting number depends on how many rows a tenant was
    // created with. What must hold is that the counters are independent.
    expect($theirs->sync_seq)->toBeLessThan($mine);
});

// The "must run inside a transaction" guard cannot be proved here: RefreshDatabase
// wraps every Feature test in a transaction, so `transactionLevel()` is never 0
// and the guard can never fire. It — and the bare-save path that depends on it —
// live in tests/Concurrency/SyncCursorTransactionTest.php, which does not wrap.

// --------------------------------------------------------------------- pulls

it('returns everything on a first pull from zero', function () {
    $category = makeCategory();
    makeProduct($category, 'Nasi Goreng');
    makeProduct($category, 'Mie Goreng');

    $result = $this->puller->pull('products', 0, 200);

    expect($result['rows'])->toHaveCount(2)
        ->and($result['has_more'])->toBeFalse()
        ->and($result['next_seq'])->toBeGreaterThan(0);
});

it('returns only what changed after the cursor', function () {
    $category = makeCategory();
    $first = makeProduct($category, 'Nasi Goreng');
    makeProduct($category, 'Mie Goreng');

    $result = $this->puller->pull('products', $first->sync_seq, 200);

    expect($result['rows'])->toHaveCount(1)
        ->and($result['rows'][0]['name'])->toBe('Mie Goreng');
});

it('returns nothing when the device is already up to date', function () {
    $category = makeCategory();
    $product = makeProduct($category, 'Nasi Goreng');

    $result = $this->puller->pull('products', $product->sync_seq, 200);

    expect($result['rows'])->toBeEmpty()
        ->and($result['has_more'])->toBeFalse()
        // Never rewind an idle device's cursor.
        ->and($result['next_seq'])->toBe((int) $product->sync_seq);
});

it('pages without skipping or repeating a row', function () {
    $category = makeCategory();
    foreach (range(1, 5) as $i) {
        makeProduct($category, "Item {$i}");
    }

    $seen = [];
    $cursor = 0;
    do {
        $page = $this->puller->pull('products', $cursor, 2);
        foreach ($page['rows'] as $row) {
            $seen[] = $row['id'];
        }
        $cursor = $page['next_seq'];
    } while ($page['has_more']);

    expect($seen)->toHaveCount(5)
        ->and(array_unique($seen))->toHaveCount(5);
});

it('orders rows by sequence so dependencies stay applicable', function () {
    $category = makeCategory();
    foreach (range(1, 4) as $i) {
        makeProduct($category, "Item {$i}");
    }

    $seqs = array_column($this->puller->pull('products', 0, 200)['rows'], 'sync_seq');

    expect($seqs)->toBe(array_values(collect($seqs)->sort()->all()));
});

// ---------------------------------------------------------------- tombstones

it('delivers a deletion as a tombstone rather than an absence', function () {
    $category = makeCategory();
    $product = makeProduct($category, 'Nasi Goreng');
    $afterCreate = $product->sync_seq;

    $this->catalogue->deleteProduct($this->owner, $product->id);

    $result = $this->puller->pull('products', $afterCreate, 200);

    expect($result['rows'])->toHaveCount(1)
        ->and($result['rows'][0]['id'])->toBe($product->id)
        ->and($result['rows'][0]['deleted_at'])->not->toBeNull();
});

it('hides tombstones from ordinary reads', function () {
    $category = makeCategory();
    $product = makeProduct($category, 'Nasi Goreng');
    $this->catalogue->deleteProduct($this->owner, $product->id);

    expect(Product::query()->count())->toBe(0)
        ->and(Product::query()->withTombstones()->count())->toBe(1);
});

it('tombstones a category products too, so nothing is left orphaned', function () {
    $category = makeCategory();
    $product = makeProduct($category, 'Nasi Goreng');

    $this->catalogue->deleteCategory($this->owner, $category->id);

    // The device cascades category deletes to products; leaving them behind
    // would point them at a category that exists on neither side.
    expect(Product::query()->withTombstones()->find($product->id)->deleted_at)->not->toBeNull();
});

it('frees a name once the row is tombstoned', function () {
    $category = makeCategory();
    $product = makeProduct($category, 'Nasi Goreng');
    $this->catalogue->deleteProduct($this->owner, $product->id);

    expect(fn () => makeProduct($category, 'Nasi Goreng'))->not->toThrow(Exception::class);
});

// ------------------------------------------------------------------ isolation

it('never serves one merchant catalogue to another', function () {
    $category = makeCategory();
    makeProduct($category, 'Nasi Goreng');

    $other = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);

    $rows = $this->context->runAs($other, fn () => $this->puller->pull('products', 0, 200)['rows']);

    expect($rows)->toBeEmpty();
});

it('serves the pull endpoint only to an activated device', function () {
    $this->getJson('/api/v1/sync/pull?entity=products')->assertUnauthorized();
});

it('serves a device its own catalogue over HTTP', function () {
    $category = makeCategory();
    makeProduct($category, 'Nasi Goreng');

    $outlet = Outlet::create(['name' => 'Pusat']);
    $register = PosRegister::create(['name' => 'Kasir 1', 'outlet_id' => $outlet->id]);
    $issued = app(DeviceActivation::class)->issue($this->owner, $register->id);
    $activated = app(DeviceActivation::class)->activate([
        'code' => $issued['code'], 'device_uuid' => (string) Str::uuid(),
    ]);

    $this->withHeader('Authorization', 'Bearer '.$activated['token'])
        ->getJson('/api/v1/sync/pull?entity=products&after_seq=0')
        ->assertOk()
        ->assertJsonPath('entity', 'products')
        ->assertJsonPath('rows.0.name', 'Nasi Goreng')
        ->assertJsonPath('has_more', false);
});

it('rejects an entity that is not on the allow list', function () {
    $outlet = Outlet::create(['name' => 'Pusat']);
    $register = PosRegister::create(['name' => 'Kasir 1', 'outlet_id' => $outlet->id]);
    $issued = app(DeviceActivation::class)->issue($this->owner, $register->id);
    $activated = app(DeviceActivation::class)->activate([
        'code' => $issued['code'], 'device_uuid' => (string) Str::uuid(),
    ]);

    // `devices` holds every till's binding for this merchant. Turning a
    // client-supplied name into a model class is how it would get served.
    $this->withHeader('Authorization', 'Bearer '.$activated['token'])
        ->getJson('/api/v1/sync/pull?entity=devices')
        ->assertStatus(422);
});

it('never ships a browser password or email to a till', function () {
    // Staff DO sync — a cashier has to be able to sign in offline. What must
    // not travel is the Backoffice credential: shipping it to every tablet in
    // every branch puts it somewhere far easier to extract than the server.
    $this->catalogue; // keep the shared setup honest about what it built

    $rows = app(CataloguePuller::class)->pull('employees', 0, 200)['rows'];

    expect($rows)->not->toBeEmpty();

    foreach ($rows as $row) {
        expect($row)->not->toHaveKey('password')
            ->and($row)->not->toHaveKey('email')
            ->and($row)->not->toHaveKey('remember_token')
            ->and($row)->toHaveKey('pin_hash');
    }
});

it('sends a PIN only as a hash', function () {
    app(StaffManager::class)->save($this->owner, [
        'name' => 'Siti', 'role' => 'cashier', 'pin' => '2345',
    ]);

    $rows = app(CataloguePuller::class)->pull('employees', 0, 200)['rows'];
    $siti = collect($rows)->firstWhere('name', 'Siti');

    expect($siti['pin_hash'])->not->toBe('2345')
        ->and(Hash::check('2345', $siti['pin_hash']))->toBeTrue();
});

// ------------------------------------------------------------------ authoring

it('lets only the owner touch the catalogue', function () {
    $manager = Employee::factory()->manager()->create([
        'tenant_id' => $this->tenant->id, 'email' => 'm@example.test',
    ]);

    // Prices are the owner's, on the server exactly as on the till.
    expect(fn () => $this->catalogue->saveCategory($manager, ['name' => 'Makanan']))
        ->toThrow(HttpException::class);
});

it('refuses a product pointed at another merchant category', function () {
    $other = Tenant::create(['name' => 'Warung B', 'slug' => 'warung-b']);
    $otherOwner = $this->context->runAs($other, fn () => Employee::factory()->owner()->create([
        'tenant_id' => $other->id, 'email' => 'b@example.test',
    ]));
    $foreign = $this->context->runAs(
        $other,
        fn () => $this->catalogue->saveCategory($otherOwner, ['name' => 'Kopi'])
    );

    expect(fn () => $this->catalogue->saveProduct($this->owner, [
        'name' => 'Latte', 'category_id' => $foreign->id, 'price' => 20000,
    ]))->toThrow(ValidationException::class);
});

it('keeps a null tax rate distinct from a zero one', function () {
    $category = makeCategory();

    $inherits = $this->catalogue->saveProduct($this->owner, [
        'name' => 'Nasi Goreng', 'category_id' => $category->id, 'price' => 15000,
    ]);
    $exempt = $this->catalogue->saveProduct($this->owner, [
        'name' => 'Beras', 'category_id' => $category->id, 'price' => 60000, 'tax_rate' => 0,
    ]);

    // null means "use the store PB1 rate"; 0.0 means genuinely zero-rated.
    expect($inherits->tax_rate)->toBeNull()
        ->and($exempt->tax_rate)->toBe(0.0);
});

it('stores money as integer rupiah', function () {
    $product = makeProduct(makeCategory(), 'Nasi Goreng', 15500);

    expect(DB::table('products')->where('id', $product->id)->value('price'))->toBe(15500);
});
