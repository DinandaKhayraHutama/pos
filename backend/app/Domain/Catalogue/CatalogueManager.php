<?php

declare(strict_types=1);

namespace App\Domain\Catalogue;

use App\Domain\Auth\Permission;
use App\Domain\Sync\SyncCursor;
use App\Models\Category;
use App\Models\Employee;
use App\Models\Product;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Validation\ValidationException;

/**
 * Every catalogue write goes through here.
 *
 * Not a convenience wrapper: a write has to allocate a `sync_seq` inside the
 * same transaction that commits the row, or a device can skip past it (see
 * {@see SyncCursor}). Funnelling writes through one place is
 * what makes that guarantee hold for the Filament panel and any future API
 * alike, instead of depending on each call site remembering.
 *
 * Catalogue is `manageCatalogue` — the OWNER's permission, not a manager's.
 * That mirrors the device exactly: a manager runs the floor and the money, and
 * prices are the owner's.
 */
class CatalogueManager
{
    public function saveCategory(Employee $actor, array $data, ?string $id = null): Category
    {
        return DB::transaction(function () use ($actor, $data, $id): Category {
            $this->authorize($actor);

            $values = Validator::make($data, [
                'name' => ['required', 'string', 'max:255'],
                'icon_key' => ['nullable', 'string', 'max:64'],
                'sort_order' => ['nullable', 'integer', 'min:0'],
                'is_popular' => ['nullable', 'boolean'],
            ])->validate();

            $this->assertNameFree(Category::class, $values['name'], $id, 'category');

            $category = $id ? Category::query()->findOrFail($id) : new Category;
            $category->fill($values)->save();

            return $category;
        }, 3);
    }

    public function saveProduct(Employee $actor, array $data, ?string $id = null): Product
    {
        return DB::transaction(function () use ($actor, $data, $id): Product {
            $this->authorize($actor);

            $values = Validator::make($data, [
                'name' => ['required', 'string', 'max:255'],
                'category_id' => ['required', 'uuid'],
                'price' => ['required', 'integer', 'min:0'],
                'cost' => ['nullable', 'integer', 'min:0'],
                'sku' => ['nullable', 'string', 'max:64'],
                // Nullable is meaningful: null defers to the store's PB1 rate,
                // 0 means genuinely zero-rated. `present` so a form that omits
                // the field cannot silently mean one when it meant the other.
                'tax_rate' => ['nullable', 'numeric', 'min:0', 'max:100'],
                'description' => ['nullable', 'string', 'max:2000'],
                'image_url' => ['nullable', 'url', 'max:2000'],
                'icon_key' => ['nullable', 'string', 'max:64'],
                'available' => ['nullable', 'boolean'],
                'is_popular' => ['nullable', 'boolean'],
                'sort_order' => ['nullable', 'integer', 'min:0'],
            ])->validate();

            // Scoped lookup: the global scope makes another merchant's category
            // invisible, so this rejects a foreign id without ever having to
            // compare tenant ids by hand.
            if (! Category::query()->whereKey($values['category_id'])->exists()) {
                throw ValidationException::withMessages([
                    'category_id' => 'Choose a category in this business.',
                ]);
            }

            $this->assertNameFree(Product::class, $values['name'], $id, 'product');

            $product = $id ? Product::query()->findOrFail($id) : new Product;
            $product->fill($values)->save();

            return $product;
        }, 3);
    }

    /**
     * Tombstone a row so every till learns it is gone.
     *
     * Deleting a category takes its products with it — the device's schema has
     * `ON DELETE CASCADE` there, so leaving them behind would produce products
     * pointing at a category that no longer exists on either side.
     */
    public function deleteCategory(Employee $actor, string $id): void
    {
        DB::transaction(function () use ($actor, $id): void {
            $this->authorize($actor);
            $category = Category::query()->findOrFail($id);

            foreach ($category->products()->get() as $product) {
                $product->delete();
            }

            $category->delete();
        }, 3);
    }

    public function deleteProduct(Employee $actor, string $id): void
    {
        DB::transaction(function () use ($actor, $id): void {
            $this->authorize($actor);
            Product::query()->findOrFail($id)->delete();
        }, 3);
    }

    /**
     * Names are unique per merchant.
     *
     * Matches the device, where the product form already refuses a duplicate —
     * two "Nasi Goreng" rows on a till is a cashier picking the wrong one.
     * Tombstoned rows are excluded by the global scope, so a name frees up once
     * the row is deleted.
     *
     * @param  class-string<Model>  $model
     */
    private function assertNameFree(string $model, string $name, ?string $exceptId, string $label): void
    {
        $taken = $model::query()
            ->whereRaw('LOWER(name) = ?', [mb_strtolower($name)])
            ->when($exceptId !== null, fn ($q) => $q->whereKeyNot($exceptId))
            ->exists();

        if ($taken) {
            throw ValidationException::withMessages([
                'name' => "This {$label} name is already used.",
            ]);
        }
    }

    /**
     * Locks the merchant for the write, then checks the actor may make it.
     *
     * The lock is the same one {@see SyncCursor} relies on:
     * catalogue writes for one merchant serialise, so the sequence they publish
     * can never be observed out of order.
     */
    private function authorize(Employee $actor): void
    {
        $context = app(TenantContext::class);
        $tenant = Tenant::query()->whereKey($context->requireId())->lockForUpdate()->firstOrFail();
        $context->set($tenant);

        $current = Employee::query()->find($actor->id);

        abort_unless(
            $current?->canAccessBackoffice()
                && $current->hasPermission(Permission::ManageCatalogue)
                && $tenant->isActive(),
            403
        );
    }
}
