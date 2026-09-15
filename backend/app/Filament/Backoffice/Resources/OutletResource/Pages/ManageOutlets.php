<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources\OutletResource\Pages;

use App\Domain\Devices\InfrastructureManager;
use App\Filament\Backoffice\Resources\OutletResource;
use Filament\Actions\CreateAction;
use Filament\Resources\Pages\ManageRecords;

class ManageOutlets extends ManageRecords
{
    protected static string $resource = OutletResource::class;

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make()->using(fn (array $data) => app(InfrastructureManager::class)->saveOutlet(auth('backoffice')->user(), $data)),
        ];
    }
}
