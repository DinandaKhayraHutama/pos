<?php

declare(strict_types=1);

use App\Domain\Tenancy\TenantProvisioner;
use App\Models\Category;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Product;
use App\Support\TenantContext;
use GuzzleHttp\Cookie\CookieJar;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Str;

require __DIR__.'/../vendor/autoload.php';
$app = require __DIR__.'/../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

if (! app()->environment(['local', 'testing'])) {
    throw new RuntimeException('This verification is only for local/testing.');
}

$baseUrl = rtrim($argv[1] ?? 'http://127.0.0.1:8000', '/');
if (! in_array(parse_url($baseUrl, PHP_URL_HOST), ['127.0.0.1', 'localhost', '::1'], true)) {
    throw new RuntimeException('Use a loopback server connected to this local database.');
}
$cookies = new CookieJar;
$client = fn () => Http::withOptions(['cookies' => $cookies])->timeout(20);
$context = app(TenantContext::class);
$tenant = null;
$csrf = null;
$updateUrl = null;
$failure = null;

function checkBackoffice(bool $condition, string $message): void
{
    if (! $condition) {
        throw new RuntimeException($message);
    }
}

function extractBackofficeSnapshot(string $html, string $class): string
{
    preg_match_all('/wire:snapshot="([^"]+)"/', $html, $matches);
    foreach ($matches[1] as $encoded) {
        $snapshot = html_entity_decode($encoded, ENT_QUOTES | ENT_HTML5, 'UTF-8');
        if (class_basename(json_decode($snapshot, true)['memo']['name']) === $class) {
            return $snapshot;
        }
    }
    throw new RuntimeException('Missing component: '.$class);
}

$get = function (string $path) use ($client, $baseUrl, &$csrf): string {
    $response = $client()->get($baseUrl.$path);
    checkBackoffice($response->status() === 200, 'GET '.$path.' returned '.$response->status());
    // Login rotates the session's CSRF token. Read the current page's token
    // just as the browser does before its next component request.
    if (preg_match('/data-csrf="([^"]+)"/', $response->body(), $match)) {
        $csrf = html_entity_decode($match[1], ENT_QUOTES);
    }

    return $response->body();
};
$update = function (string $snapshot, string $method, array $params = [], array $updates = []) use ($client, &$csrf, &$updateUrl): array {
    $response = $client()->withHeaders(['X-Livewire' => 'true'])->post($updateUrl, [
        '_token' => $csrf,
        'components' => [[
            'snapshot' => $snapshot,
            'updates' => (object) $updates,
            'calls' => [['path' => '', 'method' => $method, 'params' => $params]],
        ]],
    ]);
    checkBackoffice($response->status() === 200, $method.' returned '.$response->status());

    return $response->json('components.0');
};

try {
    $suffix = (string) Str::uuid();
    $password = Str::random(32);
    ['tenant' => $tenant, 'owner' => $owner] = app(TenantProvisioner::class)->provision(
        businessName: 'HTTP Verification '.$suffix,
        ownerName: 'Verification Owner',
        ownerEmail: $suffix.'@verification.test',
        ownerPassword: $password,
    );

    $html = $get('/backoffice/login');
    preg_match('/data-csrf="([^"]+)"/', $html, $match);
    $csrf = html_entity_decode($match[1], ENT_QUOTES);
    preg_match('/data-update-uri="([^"]+)"/', $html, $match);
    $updateUrl = html_entity_decode($match[1], ENT_QUOTES);
    if (str_starts_with($updateUrl, '/')) {
        $updateUrl = $baseUrl.$updateUrl;
    }
    $login = $update(extractBackofficeSnapshot($html, 'Login'), 'authenticate', [], [
        'data.email' => $owner->email, 'data.password' => $password,
    ]);
    checkBackoffice(isset($login['effects']['redirect']), 'Login failed');
    echo "PASS login over HTTP\n";

    $html = $get('/backoffice');
    checkBackoffice(str_contains($html, $tenant->name), 'Dashboard did not resolve the merchant');
    $snapshot = extractBackofficeSnapshot($html, 'BusinessOverview');
    for ($i = 0; $i < 3; $i++) {
        $result = $update($snapshot, '$refresh');
        $rendered = $result['effects']['html'];
        checkBackoffice(str_contains($rendered, $tenant->name) && ! str_contains($rendered, 'No merchant resolved'), 'Polling lost tenant');
        checkBackoffice((bool) preg_match('/Active staff\s+1/s', strip_tags($rendered)), 'Polling changed staff count');
        $snapshot = $result['snapshot'];
    }
    echo "PASS dashboard across three polling requests\n";

    $create = function (string $path, string $component, string $model, array $data) use ($get, $update, $context, $tenant) {
        $mounted = $update(extractBackofficeSnapshot($get('/backoffice/'.$path), $component), 'mountAction', ['create']);
        $updates = [];
        foreach ($data as $key => $value) {
            $updates['mountedActions.0.data.'.$key] = $value;
        }
        $update($mounted['snapshot'], 'callMountedAction', [], $updates);
        $record = $context->runAs($tenant, fn () => $model::where('name', $data['name'])->first());
        checkBackoffice($record !== null, 'Create failed: '.$path);
        echo 'PASS create '.$path." over HTTP\n";

        return $record;
    };
    $outlet = $create('outlets', 'ManageOutlets', Outlet::class, ['name' => 'Verification outlet', 'active' => true]);
    $create('pos-registers', 'ManagePosRegisters', PosRegister::class, [
        'name' => 'Verification register', 'outlet_id' => $outlet->id, 'active' => true, 'table_service' => false,
    ]);
    $category = $create('categories', 'ManageCategories', Category::class, ['name' => 'Verification category', 'sort_order' => 0]);
    $create('products', 'ManageProducts', Product::class, [
        'name' => 'Verification product', 'category_id' => $category->id,
        'price' => 5000, 'available' => true, 'sort_order' => 0,
    ]);
    checkBackoffice(str_contains($get('/backoffice/employees'), $owner->name), 'Staff list failed');
    echo "PASS Staff page and number formatting\n";
} catch (Throwable $exception) {
    $failure = $exception;
    fwrite(STDERR, 'FAIL '.$exception->getMessage().PHP_EOL);
} finally {
    if ($tenant !== null) {
        $tenant->delete();
        echo "Removed disposable verification merchant\n";
    }
    $context->clear();
}

exit($failure === null ? 0 : 1);
