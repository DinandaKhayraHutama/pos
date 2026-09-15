<?php

declare(strict_types=1);

namespace App\Models;

use App\Domain\Orders\OrderStatus;
use App\Models\Concerns\BelongsToTenant;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;

/**
 * A sale, as the till rang it up.
 *
 * Not [\App\Models\Concerns\Syncable]: these are pushed up and never pulled
 * back, so there is no cursor. The id always arrives from the device — it is
 * the idempotency key, and generating one here would turn a retry into a second
 * sale.
 *
 * @property string $id
 * @property OrderStatus $status
 * @property int $total
 */
class Order extends Model
{
    use BelongsToTenant, HasUuids;

    protected $guarded = [];

    protected function casts(): array
    {
        return [
            'status' => OrderStatus::class,
            'placed_at' => 'datetime',
            'subtotal' => 'integer',
            'discount' => 'integer',
            'tax' => 'integer',
            'service_charge_amount' => 'integer',
            'total' => 'integer',
            'amount_paid' => 'integer',
            'refunded_amount' => 'integer',
            'pb1_rate' => 'float',
            'service_charge_rate' => 'float',
        ];
    }

    public function items(): HasMany
    {
        return $this->hasMany(OrderItem::class);
    }

    public function outlet(): BelongsTo
    {
        return $this->belongsTo(Outlet::class);
    }

    public function register(): BelongsTo
    {
        return $this->belongsTo(PosRegister::class, 'pos_register_id');
    }

    /**
     * Only the sales that count as takings.
     *
     * Every aggregate goes through this rather than spelling out the statuses,
     * for the same reason the device keeps one SQL fragment: six queries
     * excluding refunds and a seventh that does not is a set of numbers that
     * quietly fails to add up.
     */
    public function scopeRevenue(Builder $query): Builder
    {
        return $query->whereIn('status', OrderStatus::revenueValues());
    }

    public function isSettled(): bool
    {
        return $this->status->isSettled();
    }
}
