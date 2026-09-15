<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources\PosSessionResource\Pages;

use App\Filament\Backoffice\Resources\PosSessionResource;
use Filament\Resources\Pages\ManageRecords;

class ManagePosSessions extends ManageRecords
{
    protected static string $resource = PosSessionResource::class;

    /** No create action: a drawer is opened at a till, never from a browser. */
    protected function getHeaderActions(): array
    {
        return [];
    }
}
