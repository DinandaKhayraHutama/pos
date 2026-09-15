<?php

declare(strict_types=1);

namespace App\Models;

use App\Models\Concerns\BelongsToTenant;
use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class PosRegister extends Model
{
    use BelongsToTenant, HasUuids;

    protected $fillable = ['outlet_id', 'name', 'table_service', 'active', 'sort_order'];

    protected function casts(): array
    {
        return ['active' => 'boolean', 'table_service' => 'boolean'];
    }

    public function outlet(): BelongsTo
    {
        return $this->belongsTo(Outlet::class);
    }
}
