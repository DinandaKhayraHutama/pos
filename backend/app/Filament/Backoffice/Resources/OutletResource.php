<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources;

use App\Domain\Devices\InfrastructureManager;
use App\Models\Outlet;
use Filament\Actions\EditAction;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;

class OutletResource extends Resource
{
    protected static ?string $model = Outlet::class;

    public static function form(Schema $schema): Schema
    {
        return $schema->components([
            TextInput::make('name')->required()->maxLength(255),
            TextInput::make('address')->maxLength(255),
            TextInput::make('phone')->maxLength(255),
            Toggle::make('active')->default(true)->required(),
        ]);
    }

    public static function table(Table $table): Table
    {
        return $table->columns([
            TextColumn::make('name')->searchable()->sortable(),
            TextColumn::make('address'),
            IconColumn::make('active')->boolean(),
        ])->recordActions([
            EditAction::make()->using(fn (Outlet $record, array $data) => app(InfrastructureManager::class)->saveOutlet(auth('backoffice')->user(), $data, $record->id)),
        ]);
    }

    public static function getPages(): array
    {
        return ['index' => OutletResource\Pages\ManageOutlets::route('/')];
    }
}
