<?php

declare(strict_types=1);

namespace Database\Seeders;

use App\Domain\Auth\Role;
use App\Domain\Tenancy\TenantProvisioner;
use App\Models\Employee;
use App\Models\SuperAdmin;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\Hash;
use RuntimeException;

/**
 * Local development data.
 *
 * Mirrors the Flutter app's demo staff — same names, same roles, same PINs —
 * so the two sides can be compared directly while the sync layer is being
 * built. Divergent demo data would make every "is this a sync bug?" question
 * start with "or is the seed just different?".
 *
 * Idempotent: re-running must not fail on a unique email, because it will be
 * re-run constantly during development.
 */
class DatabaseSeeder extends Seeder
{
    public function run(): void
    {
        // Refuses to run outside local/testing. Every account below is created
        // with the literal password "password", including a PLATFORM ADMIN who
        // can reach every merchant on the installation — running this against a
        // production database would hand the whole platform to anyone who reads
        // this file on GitHub. `--force` gets you past `migrate`'s prompt, so
        // the guard cannot live there.
        if (! app()->environment(['local', 'testing'])) {
            throw new RuntimeException(
                'DatabaseSeeder creates well-known demo credentials and must never '
                .'run outside local/testing. Current environment: '.app()->environment()
            );
        }

        $this->seedSuperAdmin();
        $this->seedDemoMerchant();
    }

    private function seedSuperAdmin(): void
    {
        SuperAdmin::query()->firstOrCreate(
            ['email' => 'admin@justclick.test'],
            ['name' => 'Platform Admin', 'password' => 'password'],
        );
    }

    private function seedDemoMerchant(): void
    {
        if (Tenant::query()->where('slug', 'restoran-nti')->exists()) {
            return;
        }

        ['tenant' => $tenant, 'owner' => $owner] = app(TenantProvisioner::class)->provision(
            businessName: 'Restoran NTI',
            ownerName: 'Farhan Sabili',
            ownerEmail: 'farhan@nti.test',
            ownerPassword: 'password',
            slug: 'restoran-nti',
        );

        // Everything below writes tenant-owned rows, so it runs INSIDE the
        // tenant's context. Without this the global scope resolves no tenant,
        // fails closed, and the writes below quietly touch nothing — which is
        // the scope behaving correctly and the seeder being wrong.
        app(TenantContext::class)->runAs($tenant, function () use ($owner): void {
            // PIN 9999 on the owner too: the Flutter app signs in with PINs, and
            // the owner holds one there even though the till is closed to them.
            $owner->setPin('9999');
            $owner->save();

            $staff = [
                ['Siwi Wiyono Raharjo', 'siwi@nti.test', Role::Manager, '1234'],
                ['Siti Rahayu', null, Role::Cashier, '2345'],
                ['Dani Rycki Dinata', null, Role::Cashier, '3456'],
            ];

            foreach ($staff as $index => [$name, $email, $role, $pin]) {
                Employee::create([
                    'name' => $name,
                    'email' => $email,
                    // Only staff who actually open a browser get a password.
                    'password' => $role->usesBackoffice() ? 'password' : null,
                    'pin_hash' => Hash::make($pin),
                    'role' => $role,
                    'active' => true,
                    'sort_order' => $index + 1,
                ]);
            }
        });
    }
}
