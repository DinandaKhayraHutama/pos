<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources\EmployeeResource\Pages;

use App\Domain\Staff\StaffManager;
use App\Filament\Backoffice\Resources\EmployeeResource;
use Filament\Actions\CreateAction;
use Filament\Resources\Pages\ManageRecords;

class ManageEmployees extends ManageRecords
{
    protected static string $resource = EmployeeResource::class;

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make()->using(
                fn (array $data) => app(StaffManager::class)->save(auth('backoffice')->user(), $data)
            ),
        ];
    }
}
