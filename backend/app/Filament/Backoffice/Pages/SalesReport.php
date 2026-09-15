<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Pages;

use App\Domain\Auth\Permission;
use App\Domain\Reporting\SalesReporter;
use App\Models\Outlet;
use Carbon\Carbon;
use Filament\Forms\Components\DatePicker;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Filament\Schemas\Schema;
use Livewire\Attributes\Url;

/**
 * The money view: takings over a window, across one branch or the whole chain.
 *
 * Gated on `viewFinancialReports` — the OWNER's permission. A manager sees
 * today's dashboard and the cash drawers; the ranged report with profit and
 * margin is the owner's, exactly as on the device.
 *
 * The figures come from {@see SalesReporter}, which is also what the API and
 * any future export would call. Putting the SQL in the page would make this
 * screen the only place the numbers are defined, and the first export would
 * quietly disagree with it.
 */
class SalesReport extends Page
{
    protected static ?string $navigationLabel = 'Sales report';

    protected static ?int $navigationSort = 90;

    protected string $view = 'filament.backoffice.pages.sales-report';

    /** In the URL so a report can be sent to someone and open the same way. */
    #[Url]
    public ?string $outletId = null;

    #[Url]
    public ?string $from = null;

    #[Url]
    public ?string $to = null;

    public static function canAccess(): bool
    {
        $employee = auth('backoffice')->user();

        return $employee !== null
            && $employee->hasPermission(Permission::ViewFinancialReports);
    }

    public function mount(): void
    {
        // Seven days including today, which is the window someone opening a
        // sales report almost always wants first.
        $this->from ??= now()->subDays(6)->toDateString();
        $this->to ??= now()->toDateString();
    }

    public function form(Schema $schema): Schema
    {
        return $schema->components([
            Select::make('outletId')
                ->label('Outlet')
                // Empty means the whole chain, deliberately — that is how an
                // owner compares branches.
                ->placeholder('All outlets')
                ->options(fn (): array => Outlet::query()->pluck('name', 'id')->all())
                ->live(),

            DatePicker::make('from')->label('From')->live(),
            DatePicker::make('to')->label('To')->live(),
        ]);
    }

    /** @return array<string, mixed> */
    public function getReport(): array
    {
        return app(SalesReporter::class)->report(
            Carbon::parse($this->from ?? now()->subDays(6)->toDateString()),
            Carbon::parse($this->to ?? now()->toDateString()),
            $this->outletId ?: null,
        );
    }

    /** Whole rupiah, grouped — a currency with no circulating subunit. */
    public function rupiah(int|float|null $amount): string
    {
        return 'Rp '.number_format((float) ($amount ?? 0), 0, ',', '.');
    }
}
