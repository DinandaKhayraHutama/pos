<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources;

use App\Models\PosSession;
use Filament\Resources\Resource;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\Filter;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;

/**
 * Cash drawers, as the tills reported them.
 *
 * Read-only, and that is the point: these rows are the till's account of what
 * happened at a physical cash box. Letting the Backoffice edit a counted
 * drawer would let someone erase a variance from a chair, which is exactly the
 * control this screen exists to provide.
 *
 * Rows only appear once a device has pushed them, so an empty screen at a busy
 * branch means a till has not synced — worth surfacing rather than hiding, and
 * why "Last sync" lives on the Devices screen next door.
 */
class PosSessionResource extends Resource
{
    protected static ?string $model = PosSession::class;

    protected static ?string $navigationLabel = 'Cash sessions';

    public static function canCreate(): bool
    {
        return false;
    }

    public static function table(Table $table): Table
    {
        return $table
            ->columns([
                TextColumn::make('opened_at')->dateTime('d M Y, H:i')->sortable()
                    ->description(fn (PosSession $r): string => $r->outlet_name ?? '—'),
                TextColumn::make('pos_name')->label('Register')->searchable(),
                TextColumn::make('employee_name')->label('Opened by')->searchable(),
                TextColumn::make('opening_cash')->money('IDR', 1)->label('Float'),

                TextColumn::make('closed_at')->dateTime('d M Y, H:i')
                    // A drawer with no close is not missing data — it is a
                    // shift still running, and the difference matters to
                    // whoever is deciding whether to go home.
                    ->placeholder('Still open')
                    ->description(fn (PosSession $r): ?string => $r->closed_by_name),

                TextColumn::make('counted_cash')->money('IDR', 1)->label('Counted')
                    ->placeholder('—'),

                // The number the whole screen exists for.
                TextColumn::make('variance')
                    ->label('Over / short')
                    ->state(fn (PosSession $r): ?int => $r->variance())
                    ->money('IDR', 1)
                    ->placeholder('—')
                    ->color(fn (PosSession $r): string => match (true) {
                        $r->variance() === null => 'gray',
                        $r->variance() === 0 => 'success',
                        default => 'danger',
                    }),
            ])
            ->defaultSort('opened_at', 'desc')
            ->filters([
                SelectFilter::make('outlet_id')
                    ->relationship('outlet', 'name')
                    ->label('Outlet'),

                Filter::make('open')
                    ->label('Still open')
                    ->query(fn (Builder $q): Builder => $q->whereNull('closed_at')),

                Filter::make('short')
                    ->label('Drawer did not balance')
                    ->query(fn (Builder $q): Builder => $q
                        ->whereNotNull('counted_cash')
                        ->whereNotNull('expected_cash')
                        ->whereColumn('counted_cash', '!=', 'expected_cash')),
            ]);
    }

    public static function getPages(): array
    {
        return ['index' => PosSessionResource\Pages\ManagePosSessions::route('/')];
    }
}
