<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources;

use App\Domain\Auth\Role;
use App\Domain\Staff\StaffManager;
use App\Models\Employee;
use Filament\Actions\Action;
use Filament\Actions\EditAction;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Resources\Resource;
use Filament\Schemas\Schema;
use Filament\Tables\Columns\IconColumn;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Table;

/**
 * Staff accounts. The screen that makes offline sign-in possible: a PIN set
 * here is hashed, synced down, and verified on the tablet with no network.
 */
class EmployeeResource extends Resource
{
    protected static ?string $model = Employee::class;

    protected static ?string $navigationLabel = 'Staff';

    public static function form(Schema $schema): Schema
    {
        return $schema->components([
            TextInput::make('name')->required()->maxLength(255),

            Select::make('role')->required()
                ->options(collect(Role::cases())->mapWithKeys(
                    fn (Role $r) => [$r->value => ucfirst($r->value)]
                )->all())
                ->helperText('Cashiers ring up sales. Managers and owners use this Backoffice.'),

            TextInput::make('pin')->password()->revealable()
                ->minLength(4)->maxLength(6)
                ->helperText('4–6 digits, for signing in at the till. Leave blank to keep the current PIN.'),

            TextInput::make('email')->email()->maxLength(255)
                ->helperText('Only for staff who sign into this Backoffice.'),

            TextInput::make('password')->password()->revealable()->minLength(8)
                ->helperText('Leave blank to keep the current password.'),

            Toggle::make('active')->default(true),
            TextInput::make('sort_order')->numeric()->default(0)->minValue(0),
        ]);
    }

    public static function table(Table $table): Table
    {
        return $table->columns([
            TextColumn::make('name')->searchable()->sortable(),
            TextColumn::make('role')->badge()->sortable(),
            // Whether a credential exists, never the credential.
            IconColumn::make('pin_hash')->label('Till PIN')->boolean()
                ->getStateUsing(fn (Employee $r): bool => $r->pin_hash !== null),
            IconColumn::make('password')->label('Backoffice')->boolean()
                ->getStateUsing(fn (Employee $r): bool => $r->password !== null),
            IconColumn::make('active')->boolean(),
            TextColumn::make('sync_seq')->label('Rev')->sortable()
                ->tooltip('Sync revision. A till pulls everything above its own.'),
        ])->defaultSort('sort_order')->recordActions([
            EditAction::make()->using(
                fn (Employee $record, array $data) => app(StaffManager::class)
                    ->save(auth('backoffice')->user(), $data, $record->id)
            ),
            Action::make('deactivate')
                ->requiresConfirmation()
                ->visible(fn (Employee $record): bool => $record->active)
                ->action(fn (Employee $record) => app(StaffManager::class)
                    ->deactivate(auth('backoffice')->user(), $record->id)),
        ]);
    }

    public static function getPages(): array
    {
        return ['index' => EmployeeResource\Pages\ManageEmployees::route('/')];
    }
}
