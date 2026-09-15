<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources;

use App\Domain\Devices\DeviceActivation;
use App\Domain\Devices\InfrastructureManager;
use App\Models\Outlet;
use App\Models\PosRegister;
use Filament\Actions\Action;
use Filament\Actions\EditAction;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Notifications\Notification;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;
use Livewire\Component;

class PosRegisterResource extends Resource
{
    protected static ?string $model = PosRegister::class;

    public static function form(Schema $schema): Schema
    {
        return $schema->components([
            Select::make('outlet_id')->label('Outlet')->options(fn () => Outlet::query()->orderBy('name')->pluck('name', 'id'))
                ->required()->disabled(fn (?PosRegister $record) => $record !== null)->dehydrated(),
            TextInput::make('name')->required()->maxLength(255),
            Toggle::make('table_service')->default(true)->required(),
            Toggle::make('active')->default(true)->required(),
        ]);
    }

    public static function table(Table $table): Table
    {
        return $table->columns([
            TextColumn::make('name')->searchable(),
            TextColumn::make('outlet.name')->label('Outlet'),
            IconColumn::make('table_service')->boolean(),
            IconColumn::make('active')->boolean(),
        ])->recordActions([
            EditAction::make()->using(fn (PosRegister $record, array $data) => app(InfrastructureManager::class)->saveRegister(auth('backoffice')->user(), $data, $record->id)),
            Action::make('issueCode')->label('Activation code')->requiresConfirmation()
                ->modalDescription('Create a code valid for 10 minutes. Any previous unused code for this register will be cancelled.')
                ->visible(fn (PosRegister $record) => static::canEdit($record) && $record->active && $record->outlet?->active)
                ->action(function (PosRegister $record, Component $livewire): void {
                    $issued = app(DeviceActivation::class)->issue(auth('backoffice')->user(), $record->id);
                    // send() queues plaintext in the session (database-backed
                    // here). Dispatch directly to the current browser instead.
                    $notification = Notification::make()->title('Activation code: '.$issued['code'])
                        ->body('Shown once. Expires at '.$issued['expires_at'])->persistent();
                    $livewire->dispatch('notificationSent', notification: $notification->toArray());
                }),
        ]);
    }

    public static function getPages(): array
    {
        return ['index' => PosRegisterResource\Pages\ManagePosRegisters::route('/')];
    }
}
