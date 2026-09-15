<?php

declare(strict_types=1);

use App\Domain\Devices\DeviceActivation;
use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Symfony\Component\Process\Process;

it('lets only one of two concurrent PostgreSQL connections consume a code', function () {
    expect(config('database.connections.pgsql.database'))->toBe('justclick_pos_test');
    $tenant = Tenant::factory()->create();
    $actor = Employee::factory()->owner()->create(['tenant_id' => $tenant->id]);
    $context = app(TenantContext::class);
    $context->set($tenant);
    $outlet = Outlet::create(['name' => 'Race']);
    $register = PosRegister::create(['name' => 'Race', 'outlet_id' => $outlet->id]);
    $code = app(DeviceActivation::class)->issue($actor, $register->id)['code'];
    $config = config('database.connections.pgsql');
    $workerName = 'activation-race-'.Str::uuid();
    $workers = [];
    DB::beginTransaction();
    Tenant::whereKey($tenant->id)->lockForUpdate()->firstOrFail();
    try {
        for ($i = 0; $i < 2; $i++) {
            $process = new Process([PHP_BINARY, base_path('tests/Support/activate_worker.php')], base_path(), [
                'APP_ENV' => 'testing', 'DB_CONNECTION' => 'pgsql', 'DB_URL' => '',
                'DB_HOST' => $config['host'], 'DB_PORT' => (string) $config['port'],
                'DB_DATABASE' => $config['database'], 'DB_USERNAME' => $config['username'],
                'DB_PASSWORD' => $config['password'], 'CACHE_STORE' => 'array',
            ]);
            $process->setInput(json_encode([
                'worker_name' => $workerName,
                'payload' => ['code' => $code, 'device_uuid' => (string) Str::uuid()],
            ], JSON_THROW_ON_ERROR));
            $process->setTimeout(20);
            $process->start();
            $workers[] = $process;
        }
        $deadline = microtime(true) + 10;
        do {
            DB::select('SELECT pg_stat_clear_snapshot()');
            $waiting = DB::selectOne("SELECT count(*) AS total FROM pg_stat_activity WHERE application_name = ? AND wait_event_type = 'Lock'", [$workerName])->total;
            if ((int) $waiting === 2) {
                break;
            }
            usleep(20000);
        } while (microtime(true) < $deadline);
        // Both workers really overlap and are waiting for this same tenant.
        expect((int) $waiting)->toBe(2);
        DB::commit();
        $statuses = [];
        foreach ($workers as $worker) {
            $worker->wait();
            expect($worker->isSuccessful())->toBeTrue($worker->getErrorOutput());
            $statuses[] = $worker->getOutput();
        }
        sort($statuses);
        expect($statuses)->toBe(['201', '422'])
            ->and(DB::table('devices')->count())->toBe(1)
            ->and(DB::table('personal_access_tokens')->count())->toBe(1)
            ->and(DB::table('activation_codes')->whereNotNull('used_at')->count())->toBe(1);
    } finally {
        if (DB::transactionLevel() > 0) {
            DB::rollBack();
        }
        foreach ($workers as $worker) {
            if ($worker->isRunning()) {
                $worker->stop();
            }
        }
        $context->clear();
    }
});
