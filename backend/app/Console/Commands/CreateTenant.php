<?php

declare(strict_types=1);

namespace App\Console\Commands;

use App\Domain\Tenancy\TenantProvisioner;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Validator;
use InvalidArgumentException;

/**
 * Onboard a merchant: `php artisan tenant:create`.
 *
 * The platform-staff action that starts everything else. Deliberately a console
 * command in the MVP rather than a self-service signup form — taking on a
 * merchant is a commercial act, not a form submission, and the platform-admin
 * screen that will eventually wrap this calls the same provisioner.
 */
class CreateTenant extends Command
{
    protected $signature = 'tenant:create
        {--business= : The merchant\'s business name}
        {--owner= : The owner\'s full name}
        {--email= : The owner\'s login email for the Backoffice}
        {--password= : The owner\'s initial password}
        {--slug= : Optional URL handle; derived from the business name when omitted}';

    protected $description = 'Create a merchant and its first Owner account';

    public function handle(TenantProvisioner $provisioner): int
    {
        $business = $this->option('business') ?: $this->ask('Business name');
        $ownerName = $this->option('owner') ?: $this->ask("Owner's full name");
        $email = $this->option('email') ?: $this->ask("Owner's email");
        $password = $this->option('password') ?: $this->secret("Owner's password");

        $validator = Validator::make([
            'business' => $business,
            'owner' => $ownerName,
            'email' => $email,
            'password' => $password,
        ], [
            'business' => ['required', 'string', 'max:255'],
            'owner' => ['required', 'string', 'max:255'],
            'email' => ['required', 'email', 'max:255'],
            'password' => ['required', 'string', 'min:8'],
        ]);

        if ($validator->fails()) {
            foreach ($validator->errors()->all() as $error) {
                $this->components->error($error);
            }

            return self::FAILURE;
        }

        try {
            ['tenant' => $tenant, 'owner' => $owner] = $provisioner->provision(
                businessName: $business,
                ownerName: $ownerName,
                ownerEmail: $email,
                ownerPassword: $password,
                slug: $this->option('slug'),
            );
        } catch (InvalidArgumentException $e) {
            $this->components->error($e->getMessage());

            return self::FAILURE;
        }

        $this->components->info("Merchant \"{$tenant->name}\" created.");
        $this->components->twoColumnDetail('Tenant ID', $tenant->id);
        $this->components->twoColumnDetail('Slug', $tenant->slug);
        $this->components->twoColumnDetail('Owner', "{$owner->name} <{$owner->email}>");
        $this->components->twoColumnDetail('Backoffice', url('/backoffice'));

        return self::SUCCESS;
    }
}
