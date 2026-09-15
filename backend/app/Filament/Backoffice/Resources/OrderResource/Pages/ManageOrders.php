<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources\OrderResource\Pages;

use App\Filament\Backoffice\Resources\OrderResource;
use Filament\Resources\Pages\ManageRecords;

class ManageOrders extends ManageRecords
{
    protected static string $resource = OrderResource::class;

    /** No create action: a sale happens at a till, never from a browser. */
    protected function getHeaderActions(): array
    {
        return [];
    }
}
