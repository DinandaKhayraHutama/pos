<?php

declare(strict_types=1);

namespace App\Providers\Filament;

use App\Http\Middleware\ResolveTenant;
use App\Models\Employee;
use Filament\Http\Middleware\Authenticate;
use Filament\Http\Middleware\AuthenticateSession;
use Filament\Http\Middleware\DisableBladeIconComponents;
use Filament\Http\Middleware\DispatchServingFilamentEvent;
use Filament\Pages\Dashboard;
use Filament\Panel;
use Filament\PanelProvider;
use Filament\Support\Colors\Color;
use Illuminate\Cookie\Middleware\AddQueuedCookiesToResponse;
use Illuminate\Cookie\Middleware\EncryptCookies;
use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken;
use Illuminate\Routing\Middleware\SubstituteBindings;
use Illuminate\Session\Middleware\StartSession;
use Illuminate\View\Middleware\ShareErrorsFromSession;

/**
 * The merchant-facing web Backoffice.
 *
 * Owners and Managers only — a cashier's world is the till app, and
 * {@see Employee::canAccessBackoffice()} is what enforces that at
 * the door rather than leaving them a panel with nothing in it.
 *
 * Authenticates on the `backoffice` guard, NOT the platform one: this panel
 * belongs to merchants. Platform staff who create merchants use a separate
 * guard and will get their own panel, so no permission check stands between a
 * merchant and the button that creates other merchants — there is no such
 * button on this panel at all.
 */
class BackofficePanelProvider extends PanelProvider
{
    public function panel(Panel $panel): Panel
    {
        return $panel
            ->default()
            ->id('backoffice')
            ->path('backoffice')
            ->authGuard('backoffice')
            ->login()
            ->colors([
                // NTI's deep blue, the same brand primary the Flutter app
                // defaults to (BrandPreset.presets.first).
                'primary' => Color::hex('#1E40AF'),
            ])
            ->brandName('JustClick POS')
            ->discoverResources(in: app_path('Filament/Backoffice/Resources'), for: 'App\Filament\Backoffice\Resources')
            ->discoverPages(in: app_path('Filament/Backoffice/Pages'), for: 'App\Filament\Backoffice\Pages')
            ->pages([Dashboard::class])
            ->discoverWidgets(in: app_path('Filament/Backoffice/Widgets'), for: 'App\Filament\Backoffice\Widgets')
            ->middleware([
                EncryptCookies::class,
                AddQueuedCookiesToResponse::class,
                StartSession::class,
                AuthenticateSession::class,
                ShareErrorsFromSession::class,
                VerifyCsrfToken::class,
                SubstituteBindings::class,
                DisableBladeIconComponents::class,
                DispatchServingFilamentEvent::class,
                // Filament defines its own session stack instead of using the
                // web group. Keep this wrapper non-persistent; Livewire POSTs
                // get the same wrapper from the web group in bootstrap/app.php.
                ResolveTenant::class,
            ])
            ->authMiddleware([
                Authenticate::class,
                // TenantContext is managed by the outer web middleware, not
                // this replayed authorization pipeline (which ends too soon).
            ], isPersistent: true);
    }
}
