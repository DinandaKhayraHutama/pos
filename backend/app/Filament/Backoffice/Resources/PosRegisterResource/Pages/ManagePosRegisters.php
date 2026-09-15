<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources\PosRegisterResource\Pages;

use App\Domain\Devices\InfrastructureManager;
use App\Filament\Backoffice\Resources\PosRegisterResource;
use Filament\Actions\CreateAction;
use Filament\Resources\Pages\ManageRecords;

class ManagePosRegisters extends ManageRecords
{
    protected static string $resource = PosRegisterResource::class;

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make()->using(fn (array $data) => app(InfrastructureManager::class)->saveRegister(auth('backoffice')->user(), $data)),
        ];
    }
}
