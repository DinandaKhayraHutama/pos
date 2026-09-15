<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources\ProductResource\Pages;

use App\Domain\Catalogue\CatalogueManager;
use App\Filament\Backoffice\Resources\ProductResource;
use Filament\Actions\CreateAction;
use Filament\Resources\Pages\ManageRecords;

class ManageProducts extends ManageRecords
{
    protected static string $resource = ProductResource::class;

    protected function getHeaderActions(): array
    {
        return [
            CreateAction::make()->using(
                fn (array $data) => app(CatalogueManager::class)
                    ->saveProduct(auth('backoffice')->user(), $data)
            ),
        ];
    }
}
