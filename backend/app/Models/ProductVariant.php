<?php

declare(strict_types=1);

namespace App\Models;

use App\Models\Concerns\BelongsToTenant;
use App\Models\Concerns\Syncable;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * A single-select option baked onto one product (Regular / Large).
 *
 * Not a modifier: a variant belongs to exactly one product and its delta is
 * folded into the line price, while a modifier group is defined once and
 * attached to many products. Modifiers sync in a later slice.
 *
 * @property int $price_delta signed — a smaller size is negative
 */
class ProductVariant extends Model
{
    use BelongsToTenant, HasUuids, Syncable;

    protected $fillable = ['product_id', 'name', 'price_delta', 'sort_order'];

    protected function casts(): array
    {
        return ['price_delta' => 'integer', 'deleted_at' => 'datetime'];
    }

    public function product(): BelongsTo
    {
        return $this->belongsTo(Product::class);
    }
}
