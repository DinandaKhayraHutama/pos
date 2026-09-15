<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources;

use App\Domain\Orders\OrderStatus;
use App\Models\Order;
use Filament\Resources\Resource;
use Filament\Tables\Columns\TextColumn;
use Filament\Tables\Filters\Filter;
use Filament\Tables\Filters\SelectFilter;
use Filament\Tables\Table;
use Illuminate\Database\Eloquent\Builder;

/**
 * Sales, as the tills rang them up.
 *
 * Read-only. These rows are money that has already changed hands; editing one
 * from a browser would let somebody restate a customer's receipt after the
 * fact, which is precisely the thing an audit trail exists to prevent. A sale
 * is undone at the till, by someone with the permission and a reason, and that
 * decision arrives here as a push.
 *
 * Rows appear only once a device has synced, so a quiet screen at a busy branch
 * means a till has not reached the server — worth noticing, which is why the
 * Devices screen carries "last seen".
 */
class OrderResource extends Resource
{
    protected static ?string $model = Order::class;

    protected static ?string $navigationLabel = 'Sales';

    public static function canCreate(): bool
    {
        return false;
    }

    public static function table(Table $table): Table
    {
        return $table
            ->columns([
                TextColumn::make('number')->label('Receipt')->searchable()
                    ->description(fn (Order $r): string => $r->pos_name ?? '—'),

                TextColumn::make('placed_at')->dateTime('d M Y, H:i')->sortable()
                    ->label('Rung up')
                    // The till's clock, not ours. A sale taken offline yesterday
                    // and synced this morning belongs to yesterday.
                    ->description(fn (Order $r): string => $r->outlet_name ?? '—'),

                TextColumn::make('cashier_name')->label('Cashier')->searchable(),

                TextColumn::make('total')->money('IDR', 1)->sortable(),

                TextColumn::make('payment_method')->label('Paid by')->badge(),

                TextColumn::make('status')->badge()
                    ->color(fn (Order $r): string => $r->isSettled() ? 'danger' : 'success'),

                // Who approved undoing a sale, and why. The whole reason a void
                // carries a name on the device.
                TextColumn::make('authorized_by')->label('Voided by')
                    ->placeholder('—')
                    ->description(fn (Order $r): ?string => $r->void_reason)
                    ->toggleable(),
            ])
            ->defaultSort('placed_at', 'desc')
            ->filters([
                SelectFilter::make('outlet_id')
                    ->relationship('outlet', 'name')
                    ->label('Outlet'),

                SelectFilter::make('status')
                    ->options(collect(OrderStatus::cases())
                        ->mapWithKeys(fn (OrderStatus $s) => [$s->value => ucfirst($s->value)])
                        ->all()),

                Filter::make('settled')
                    ->label('Voided or refunded')
                    ->query(fn (Builder $q): Builder => $q->whereIn(
                        'status',
                        [OrderStatus::Cancelled->value, OrderStatus::Refunded->value],
                    )),
            ]);
    }

    public static function getPages(): array
    {
        return ['index' => OrderResource\Pages\ManageOrders::route('/')];
    }
}
