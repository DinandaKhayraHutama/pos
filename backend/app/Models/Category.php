<?php

declare(strict_types=1);

namespace App\Models;

use App\Models\Concerns\BelongsToTenant;
use App\Models\Concerns\Syncable;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\HasMany;

/**
 * A menu group. Shared across every outlet the merchant runs.
 *
 * @property string $id
 * @property string $name
 */
class Category extends Model
{
    use BelongsToTenant, HasUuids, Syncable;

    protected $fillable = ['name', 'icon_key', 'sort_order', 'is_popular'];

    protected function casts(): array
    {
        return ['is_popular' => 'boolean', 'deleted_at' => 'datetime'];
    }

    public function products(): HasMany
    {
        return $this->hasMany(Product::class);
    }
}
