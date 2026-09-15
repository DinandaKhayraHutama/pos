<?php

use App\Domain\Sync\SessionIngest;
use App\Models\Device;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\DB;

require __DIR__.'/../../vendor/autoload.php';
$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

// A separate PROCESS, so it holds its own PostgreSQL connection and genuinely
// contends for the same locks. A second connection inside the test process
// would sit inside the test's own transaction and see rows nobody has committed.
if (! $app->environment('testing') || config('database.connections.pgsql.database') !== 'justclick_pos_test') {
    exit(2);
}

$input = json_decode(stream_get_contents(STDIN), true, flags: JSON_THROW_ON_ERROR);
DB::select("SELECT set_config('application_name', ?, false)", [$input['worker_name']]);

$tenant = Tenant::query()->findOrFail($input['tenant_id']);
app(TenantContext::class)->set($tenant);

$device = app(TenantContext::class)->runUnscoped(
    fn () => Device::query()->findOrFail($input['device_id'])
);

$result = app(SessionIngest::class)->ingest($device, [$input['row']]);

echo $result['accepted'] === [] ? 'rejected' : 'accepted';
