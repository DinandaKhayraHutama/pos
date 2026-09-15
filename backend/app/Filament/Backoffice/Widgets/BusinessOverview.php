<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Widgets;

use App\Domain\Reporting\SalesReporter;
use App\Models\Employee;
use App\Models\Outlet;
use App\Support\TenantContext;
use Filament\Widgets\StatsOverviewWidget;
use Filament\Widgets\StatsOverviewWidget\Stat;

/**
 * What the Backoffice shows before any outlet or product exists.
 *
 * Deliberately not an empty page: the first thing an Owner must be able to
 * confirm on their very first sign-in is that they are looking at THEIR
 * business and not somebody else's — which is also the acceptance criterion
 * for the tenant isolation this whole panel sits on.
 *
 * Every figure here comes from tenant-scoped queries. None of them filter by
 * tenant explicitly, and that is the point: the global scope does it, so a
 * widget author cannot forget.
 */
class BusinessOverview extends StatsOverviewWidget
{
    /**
     * Rendered with the page, not deferred to a follow-up Livewire request.
     *
     * Lazy loading buys nothing for two COUNT queries, and it costs the one
     * thing this widget exists for: an Owner opening the panel must see WHICH
     * business they are in immediately, not after a second round trip.
     */
    protected static bool $isLazy = false;

    protected function getStats(): array
    {
        $tenant = app(TenantContext::class)->current();
        $today = app(SalesReporter::class)->summaryForDay(now());
        $outlets = Outlet::query()->where('active', true)->count();

        return [
            Stat::make('Business', $tenant?->name ?? '—')
                ->description($tenant?->slug ?? 'No merchant resolved')
                ->color($tenant === null ? 'danger' : 'primary'),

            // Across every branch. An owner with two shops wants the business's
            // number first and the split second — the split is a click away on
            // the Sales report.
            Stat::make('Takings today', $this->rupiah((int) $today['revenue']))
                ->description($today['order_count'].' sales · '.$today['items_sold'].' items')
                ->color((int) $today['revenue'] > 0 ? 'success' : 'gray'),

            Stat::make('Outlets', (string) $outlets)
                ->description(Employee::query()->active()->count().' active staff'),
        ];
    }

    /**
     * Whole rupiah, grouped.
     *
     * Not `Number::currency`: that renders "Rp 33.000,00", and a currency with
     * no subunit in circulation showing two decimal places reads as a bug to
     * every Indonesian looking at it.
     */
    private function rupiah(int $amount): string
    {
        return 'Rp '.number_format($amount, 0, ',', '.');
    }
}
