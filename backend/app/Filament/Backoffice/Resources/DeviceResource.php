<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources;

use App\Domain\Devices\DeviceActivation;
use App\Models\Device;
use Filament\Actions\Action;
use Filament\Resources\Resource;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;

class DeviceResource extends Resource
{
    protected static ?string $model = Device::class;

    public static function canCreate(): bool
    {
        return false;
    }

    public static function table(Table $table): Table
    {
        return $table->columns([
            TextColumn::make('label')->placeholder('Unnamed device'),
            TextColumn::make('device_uuid')->label('Installation'),
            TextColumn::make('outlet.name')->label('Outlet'),
            TextColumn::make('posRegister.name')->label('Register'),
            TextColumn::make('platform'),
            TextColumn::make('last_seen_at')->dateTime(),
            TextColumn::make('revoked_at')->dateTime()->placeholder('Active'),
        ])->recordActions([
            Action::make('revoke')->label('Revoke access')->color('danger')->requiresConfirmation()
                ->modalDescription('The device will be rejected on its next API request. Unused activation codes for this register will also be cancelled.')
                ->visible(fn (Device $record) => static::canView($record) && $record->revoked_at === null)
                ->action(fn (Device $record) => app(DeviceActivation::class)->revoke(auth('backoffice')->user(), $record->id)),
        ]);
    }

    public static function getPages(): array
    {
        return ['index' => DeviceResource\Pages\ManageDevices::route('/')];
    }
}
