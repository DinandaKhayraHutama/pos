<?php

declare(strict_types=1);

namespace App\Models;

use App\Models\Concerns\BelongsToTenant;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/**
 * One line on a receipt.
 *
 * `product_name`, `unit_price`, `unit_cost` and the category columns are all
 * snapshots taken at the moment of sale. There is no foreign key to `products`
 * on purpose: the product may have been deleted since, and a receipt must still
 * read correctly.
 *
 * @property int $unit_price
 * @property int $quantity
 */
class OrderItem extends Model
{
    use BelongsToTenant, HasUuids;

    protected $guarded = [];

    protected function casts(): array
    {
        return [
            'unit_price' => 'integer',
            'unit_cost' => 'integer',
            'quantity' => 'integer',
        ];
    }

    public function order(): BelongsTo
    {
        return $this->belongsTo(Order::class);
    }

    public function modifiers(): HasMany
    {
        return $this->hasMany(OrderItemModifier::class);
    }

    /** What this line contributed before any order-level discount. */
    public function lineTotal(): int
    {
        return $this->unit_price * $this->quantity;
    }
}
