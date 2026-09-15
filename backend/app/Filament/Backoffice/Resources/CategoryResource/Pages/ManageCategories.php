<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources\CategoryResource\Pages;

use App\Domain\Catalogue\CatalogueManager;
use App\Filament\Backoffice\Resources\CategoryResource;
use Filament\Actions\CreateAction;
use Filament\Resources\Pages\ManageRecords;

class ManageCategories extends ManageRecords
{
    protected static string $resource = CategoryResource::class;

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make()->using(
                fn (array $data) => app(CatalogueManager::class)
                    ->saveCategory(auth('backoffice')->user(), $data)
            ),
        ];
    }
}
