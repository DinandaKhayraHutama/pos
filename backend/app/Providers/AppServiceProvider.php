<?php

declare(strict_types=1);

namespace App\Providers;

use App\Auth\EmployeeUserProvider;
use App\Domain\Auth\Permission;
use App\Domain\Auth\Role;
use App\Models\Category;
use App\Models\Device;
use App\Models\DeviceAccessToken;
use App\Models\Employee;
use App\Models\Order;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\PosSession;
use App\Models\Product;
use App\Models\ProductVariant;
use App\Policies\CashSessionPolicy;
use App\Policies\CataloguePolicy;
use App\Policies\InfrastructurePolicy;
use App\Policies\OrderPolicy;
use App\Policies\StaffPolicy;
use App\Support\TenantContext;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;
use Laravel\Sanctum\Sanctum;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        // Singleton, so "the current tenant" cannot differ between two objects
        // handling the same request.
        $this->app->singleton(TenantContext::class);
    }

    public function boot(): void
    {
        Auth::provider('tenant-employee', fn ($app, array $config) => new EmployeeUserProvider(
            $app['hash'], $config['model']
        ));

        foreach ([Outlet::class, PosRegister::class, Device::class] as $model) {
            Gate::policy($model, InfrastructurePolicy::class);
        }

        // Deliberately a different policy: infrastructure is `manageOutlets`
        // (managers hold it), the catalogue is `manageCatalogue` (owners only).
        foreach ([Category::class, Product::class, ProductVariant::class] as $model) {
            Gate::policy($model, CataloguePolicy::class);
        }

        // A third policy, not a reuse: staff are `manageEmployees`, which a
        // manager does NOT hold — otherwise a manager could mint themselves a
        // till account and walk around the role split entirely.
        Gate::policy(Employee::class, StaffPolicy::class);

        // Cash sessions are the manager's oversight of a physical drawer, so
        // they ride on `viewCashDrawer` — which a manager holds and a cashier
        // does not. InfrastructurePolicy would have been close enough to reuse
        // and wrong: `manageOutlets` is about configuring branches, not about
        // who may see what the tills took.
        Gate::policy(PosSession::class, CashSessionPolicy::class);

        // Sales ride on `viewAllOrders` — the manager's, not the owner's alone.
        Gate::policy(Order::class, OrderPolicy::class);
        Sanctum::usePersonalAccessTokenModel(DeviceAccessToken::class);
        RateLimiter::for('device-activation', fn (Request $request) => [
            Limit::perMinute(5)->by('activation-ip:'.$request->ip()),
            Limit::perHour(30)->by('activation-hour:'.$request->ip()),
            Limit::perMinute(300)->by('activation-platform'),
        ]);
        RateLimiter::for('device-api', fn (Request $request) => Limit::perMinute(120)->by('device:'.$request->user()->id));
        $this->registerPermissionGates();
    }

    /**
     * Expose every permission as a Gate ability.
     *
     * Lets policies, controllers and Blade all ask `can('voidOrder')` while the
     * answer still comes from the one derived role map in
     * {@see Role} — the Gate is a lookup surface, never a
     * second copy of the rules.
     */
    private function registerPermissionGates(): void
    {
        foreach (Permission::cases() as $permission) {
            Gate::define(
                $permission->value,
                static fn (Employee $employee): bool => $employee->hasPermission($permission),
            );
        }
    }
}
