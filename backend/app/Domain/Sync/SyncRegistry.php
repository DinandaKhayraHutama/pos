<?php

declare(strict_types=1);

namespace App\Domain\Sync;

use App\Models\Category;
use App\Models\Employee;
use App\Models\Product;
use App\Models\ProductVariant;
use Illuminate\Database\Eloquent\Model;
use InvalidArgumentException;

/**
 * Which entities a device may pull, and in what order it must apply them.
 *
 * An allow-list, not a lookup by class name from the request: the entity name
 * arrives from a client, and turning client input into a model class is how an
 * endpoint ends up serving `employees` — password hashes and all — to anything
 * holding a device token.
 *
 * **Order is load-bearing.** The device writes pulled rows into SQLite where
 * `PRAGMA foreign_keys` is ON, so a product landing before its category fails
 * with SQLite error 787. The same dependency-before-dependent discipline the
 * app's own migrations already follow.
 */
class SyncRegistry
{
    /**
     * Pullable entities, in dependency order.
     *
     * @var array<string, class-string<Model>>
     */
    private const ENTITIES = [
        // Staff first: a till has to know who may sign in before anything else
        // matters, and nothing in the catalogue depends on it either way.
        'employees' => Employee::class,
        'categories' => Category::class,
        'products' => Product::class,
        'product_variants' => ProductVariant::class,
    ];

    /**
     * The columns a device receives.
     *
     * Explicit per entity rather than `SELECT *`, so a column added later for
     * server-side bookkeeping is not silently published to every till. `id` and
     * `sync_seq` are always included — the first is the primary key the device
     * writes under, the second is its cursor. `deleted_at` travels because a
     * tombstone is the only way a device learns a row is gone.
     *
     * @var array<string, list<string>>
     */
    private const COLUMNS = [
        // Note what is ABSENT: `password` and `email`. A browser password is a
        // credential a till has no use for, and shipping it to every tablet in
        // every branch would put it somewhere far easier to extract than the
        // server. `pin_hash` travels because offline sign-in genuinely needs
        // it — and it is a hash, verified on-device, never a plaintext PIN.
        'employees' => ['id', 'name', 'pin_hash', 'role', 'active', 'sort_order'],

        'categories' => ['id', 'name', 'icon_key', 'sort_order', 'is_popular'],
        'products' => [
            'id', 'category_id', 'name', 'price', 'cost', 'sku', 'tax_rate',
            'description', 'image_url', 'icon_key', 'available', 'is_popular', 'sort_order',
        ],
        'product_variants' => ['id', 'product_id', 'name', 'price_delta', 'sort_order'],
    ];

    /** @return list<string> dependency order — categories before products */
    public static function names(): array
    {
        return array_keys(self::ENTITIES);
    }

    public static function supports(string $entity): bool
    {
        return array_key_exists($entity, self::ENTITIES);
    }

    /** @return class-string<Model> */
    public static function modelFor(string $entity): string
    {
        if (! self::supports($entity)) {
            throw new InvalidArgumentException("Unknown sync entity [{$entity}].");
        }

        return self::ENTITIES[$entity];
    }

    /** @return list<string> */
    public static function columnsFor(string $entity): array
    {
        return [...self::COLUMNS[self::supports($entity) ? $entity : throw new InvalidArgumentException(
            "Unknown sync entity [{$entity}]."
        )], 'sync_seq', 'deleted_at'];
    }
}
