<?php

declare(strict_types=1);

namespace App\Models;

use App\Models\Concerns\BelongsToTenant;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * A choice made on one line — "Level Pedas: Pedas, +2000".
 *
 * Carries names and a price only. It has no ids into the catalogue at all, on
 * the device or here: what was chosen and what it cost IS the record, so
 * deleting a modifier group later never rewrites a past receipt.
 *
 * @property int $price_delta
 */
class OrderItemModifier extends Model
{
    use BelongsToTenant, HasUuids;

    protected $guarded = [];

    protected function casts(): array
    {
        return ['price_delta' => 'integer'];
    }

    public function item(): BelongsTo
    {
        return $this->belongsTo(OrderItem::class, 'order_item_id');
    }
}
