<?php

declare(strict_types=1);

namespace App\Models;

use App\Models\Concerns\BelongsToTenant;
use App\Models\Concerns\Syncable;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/**
 * A sellable item.
 *
 * `price` and `cost` are integer rupiah, matching the device. `tax_rate` is
 * nullable and null is NOT zero — see the migration.
 *
 * @property string $id
 * @property int $price
 */
class Product extends Model
{
    use BelongsToTenant, HasUuids, Syncable;

    protected $fillable = [
        'category_id', 'name', 'price', 'cost', 'sku', 'tax_rate',
        'description', 'image_url', 'icon_key', 'available', 'is_popular', 'sort_order',
    ];

    protected function casts(): array
    {
        return [
            'price' => 'integer',
            'cost' => 'integer',
            'tax_rate' => 'float',
            'available' => 'boolean',
            'is_popular' => 'boolean',
            'deleted_at' => 'datetime',
        ];
    }

    public function category(): BelongsTo
    {
        return $this->belongsTo(Category::class);
    }

    public function variants(): HasMany
    {
        return $this->hasMany(ProductVariant::class);
    }
}
