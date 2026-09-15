<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources;

use App\Domain\Catalogue\CatalogueManager;
use App\Models\Product;
use Filament\Actions\DeleteAction;
use Filament\Actions\EditAction;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\Textarea;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;

/**
 * The menu. This is the screen the whole catalogue-sync slice exists to serve:
 * an Owner edits a price here and a till that has been offline since yesterday
 * picks it up on its next pull.
 */
class ProductResource extends Resource
{
    protected static ?string $model = Product::class;

    public static function form(Schema $schema): Schema
    {
        return $schema->components([
            TextInput::make('name')->required()->maxLength(255),

            // Options come from a tenant-scoped query, so another merchant's
            // categories are not merely hidden — they are never fetched.
            Select::make('category_id')->relationship('category', 'name')
                ->required()->searchable()->preload()->label('Category'),

            TextInput::make('price')->required()->numeric()->minValue(0)
                ->prefix('Rp')->helperText('Whole rupiah. No decimals.'),
            TextInput::make('cost')->numeric()->minValue(0)->prefix('Rp')
                ->helperText('Cost of goods, for the profit report.'),
            TextInput::make('sku')->maxLength(64),

            TextInput::make('tax_rate')->numeric()->minValue(0)->maxValue(100)->suffix('%')
                ->helperText('Leave empty to use the store PB1 rate. 0 means genuinely zero-rated — the two are not the same.'),

            Textarea::make('description')->maxLength(2000),
            TextInput::make('image_url')->url()->maxLength(2000),
            TextInput::make('icon_key')->maxLength(64)->default('restaurant')
                ->helperText('Shown when there is no photo.'),

            Toggle::make('available')->default(true),
            Toggle::make('is_popular')->default(false),
            TextInput::make('sort_order')->numeric()->default(0)->minValue(0),
        ]);
    }

    public static function table(Table $table): Table
    {
        return $table->columns([
            TextColumn::make('name')->searchable()->sortable(),
            TextColumn::make('category.name')->label('Category')->sortable(),
            TextColumn::make('price')->money('IDR', 1)->sortable(),
            IconColumn::make('available')->boolean(),
            TextColumn::make('sync_seq')->label('Rev')->sortable()
                ->tooltip('Sync revision. A till pulls everything above its own.'),
        ])->defaultSort('sort_order')->recordActions([
            EditAction::make()->using(
                fn (Product $record, array $data) => app(CatalogueManager::class)
                    ->saveProduct(auth('backoffice')->user(), $data, $record->id)
            ),
            DeleteAction::make()->using(
                fn (Product $record) => app(CatalogueManager::class)
                    ->deleteProduct(auth('backoffice')->user(), $record->id)
            ),
        ]);
    }

    public static function getPages(): array
    {
        return ['index' => ProductResource\Pages\ManageProducts::route('/')];
    }
}
