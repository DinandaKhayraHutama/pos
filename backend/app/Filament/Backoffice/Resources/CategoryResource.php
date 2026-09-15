<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources;

use App\Domain\Catalogue\CatalogueManager;
use App\Models\Category;
use Filament\Actions\DeleteAction;
use Filament\Actions\EditAction;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;

/**
 * Menu groups. Every write goes through {@see CatalogueManager} so it lands
 * with a `sync_seq` inside the same transaction that commits it — a row saved
 * straight through Eloquent here would be one no till ever hears about.
 */
class CategoryResource extends Resource
{
    protected static ?string $model = Category::class;

    protected static ?string $navigationLabel = 'Categories';

    public static function form(Schema $schema): Schema
    {
        return $schema->components([
            TextInput::make('name')->required()->maxLength(255),
            TextInput::make('icon_key')->maxLength(64)
                ->helperText('Material icon key used on the till, e.g. restaurant.'),
            TextInput::make('sort_order')->numeric()->default(0)->minValue(0),
            Toggle::make('is_popular')->default(false),
        ]);
    }

    public static function table(Table $table): Table
    {
        return $table->columns([
            TextColumn::make('name')->searchable()->sortable(),
            TextColumn::make('products_count')->counts('products')->label('Products'),
            IconColumn::make('is_popular')->boolean(),
            TextColumn::make('sync_seq')->label('Rev')->sortable()
                ->tooltip('Sync revision. A till pulls everything above its own.'),
        ])->defaultSort('sort_order')->recordActions([
            EditAction::make()->using(
                fn (Category $record, array $data) => app(CatalogueManager::class)
                    ->saveCategory(auth('backoffice')->user(), $data, $record->id)
            ),
            // Tombstones rather than removes — see CatalogueManager. Deleting a
            // category takes its products with it, exactly as the till's own
            // schema cascades.
            DeleteAction::make()->using(
                fn (Category $record) => app(CatalogueManager::class)
                    ->deleteCategory(auth('backoffice')->user(), $record->id)
            ),
        ]);
    }

    public static function getPages(): array
    {
        return ['index' => CategoryResource\Pages\ManageCategories::route('/')];
    }
}
