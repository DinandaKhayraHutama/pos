<?php

declare(strict_types=1);

namespace App\Models;

use App\Models\Concerns\BelongsToTenant;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

/**
 * A cash drawer session as the till reported it.
 *
 * Deliberately NOT [\App\Models\Concerns\Syncable]: these rows are pushed up,
 * never pulled back down, so there is no cursor for a device to page through.
 *
 * `HasUuids` is present for the key type, but the id always arrives from the
 * device — it is the idempotency key, so generating one here would turn a retry
 * into a second drawer.
 *
 * @property string $id
 * @property int $opening_cash
 * @property int|null $counted_cash
 * @property int|null $expected_cash
 */
class PosSession extends Model
{
    use BelongsToTenant, HasUuids;

    protected $fillable = [
        'id',
        'tenant_id',
        'outlet_id',
        'pos_register_id',
        'device_id',
        'employee_id',
        'employee_name',
        'pos_name',
        'outlet_name',
        'opened_at',
        'opening_cash',
        'closed_at',
        'counted_cash',
        'expected_cash',
        'closed_by_id',
        'closed_by_name',
        'note',
    ];

    protected function casts(): array
    {
        return [
            'opened_at' => 'datetime',
            'closed_at' => 'datetime',
            'opening_cash' => 'integer',
            'counted_cash' => 'integer',
            'expected_cash' => 'integer',
        ];
    }

    public function outlet(): BelongsTo
    {
        return $this->belongsTo(Outlet::class);
    }

    public function register(): BelongsTo
    {
        return $this->belongsTo(PosRegister::class, 'pos_register_id');
    }

    public function device(): BelongsTo
    {
        return $this->belongsTo(Device::class);
    }

    public function scopeOpen(Builder $query): Builder
    {
        return $query->whereNull('closed_at');
    }

    public function isOpen(): bool
    {
        return $this->closed_at === null;
    }

    /**
     * What the drawer was over or under by.
     *
     * Null while open, and null for a session closed before expected_cash was
     * recorded — an absent variance is not a variance of zero.
     */
    public function variance(): ?int
    {
        if ($this->counted_cash === null || $this->expected_cash === null) {
            return null;
        }

        return $this->counted_cash - $this->expected_cash;
    }
}
