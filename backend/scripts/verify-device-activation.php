<?php

declare(strict_types=1);

use App\Domain\Devices\DeviceActivation;
use App\Domain\Devices\InfrastructureManager;
use App\Domain\Tenancy\TenantProvisioner;
use App\Models\ActivationCode;
use App\Models\Device;
use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Support\TenantContext;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;

require __DIR__.'/../vendor/autoload.php';
$app = require __DIR__.'/../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$base = $argv[1] ?? 'http://127.0.0.1:8000';
if (! $app->environment('local') || ! in_array(parse_url($base, PHP_URL_HOST), ['localhost', '127.0.0.1', '::1'], true)) {
    fwrite(STDERR, "This smoke test requires a local environment and loopback server.\n");
    exit(2);
}
$http = Http::baseUrl(rtrim($base, '/').'/api/v1')->acceptJson()->timeout(15)->withoutRedirecting();
$assertStatus = function ($response, int $status, string $label): void {
    if ($response->status() !== $status) {
        throw new RuntimeException("$label: expected $status, got ".$response->status());
    }
    echo "$label: $status\n";
};
$fixture = app(TenantProvisioner::class)->provision(
    'Device activation smoke', 'Smoke Owner', 'smoke-'.Str::uuid().'@example.test', Str::random(40),
);
$context = app(TenantContext::class);
$tenant = $fixture['tenant'];
$actor = $fixture['owner'];
$context->set($tenant);
try {
    $manager = app(InfrastructureManager::class);
    $outlet = $manager->saveOutlet($actor, ['name' => 'Smoke outlet', 'active' => true]);
    $register = $manager->saveRegister($actor, [
        'name' => 'Smoke register', 'outlet_id' => $outlet->id, 'active' => true, 'table_service' => true,
    ]);
    $service = app(DeviceActivation::class);
    $issued = $service->issue($actor, $register->id);
    $payload = ['code' => $issued['code'], 'device_uuid' => (string) Str::uuid(), 'platform' => 'web'];

    $assertStatus($http->get('/health'), 200, 'Health');
    $assertStatus($http->get('/devices/me'), 401, 'Unauthenticated');
    $response = $http->post('/devices/activate', $payload);
    $assertStatus($response, 201, 'Activation');
    $body = $response->json();
    if ($body['outlet']['id'] !== $outlet->id || $body['pos_register']['id'] !== $register->id) {
        throw new RuntimeException('Binding mismatch');
    }
    $assertStatus($http->withToken($body['token'])->get('/devices/me'), 200, 'UUID bearer authentication');
    $assertStatus($http->post('/devices/activate', $payload), 422, 'Replay rejected');

    $expired = $service->issue($actor, $register->id);
    ActivationCode::query()->where('code_hash', DeviceActivation::fingerprint($expired['code']))
        ->update(['expires_at' => now()->subMinute()]);
    $assertStatus($http->post('/devices/activate', [...$payload, 'code' => $expired['code']]), 422, 'Expired code rejected');
    $service->revoke($actor, $body['device']['id']);
    $assertStatus($http->withToken($body['token'])->get('/devices/me'), 401, 'Revoked token rejected');

    // The first three POSTs above count toward the five-per-minute IP budget.
    for ($i = 0; $i < 2; $i++) {
        $assertStatus($http->post('/devices/activate', ['code' => 'bad']), 422, 'Malformed attempt');
    }
    $limited = $http->post('/devices/activate', ['code' => 'bad']);
    $assertStatus($limited, 429, 'Rate limit');
    if (! $limited->header('Retry-After')) {
        throw new RuntimeException('Missing Retry-After header');
    }
    echo "All real HTTP checks passed. No credentials printed.\n";
} finally {
    // Only the disposable fixture created by this invocation is removed.
    $context->runAs($tenant, function () use ($tenant): void {
        ActivationCode::query()->delete();
        Device::query()->each(fn (Device $device) => $device->tokens()->delete());
        Device::query()->delete();
        PosRegister::query()->delete();
        Outlet::query()->delete();
        Employee::query()->delete();
        $tenant->delete();
    });
    $context->clear();
}
