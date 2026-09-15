<?php

declare(strict_types=1);

use App\Domain\Devices\DeviceActivation;
use App\Models\Device;
use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Symfony\Component\Process\Process;

/**
 * Two tablets opening a drawer on one register at the same instant.
 *
 * The single-connection tests prove the check works when the rows are already
 * committed. This proves the LOCK works: both writers pass the "is this
 * register free?" read before either commits, which is exactly the window a
 * non-locking implementation leaves open — and the outcome would be two
 * expected balances for one physical cash box, unreconcilable afterwards.
 */
it('lets only one of two concurrent connections open a drawer on a register', function () {
    expect(config('database.connections.pgsql.database'))->toBe('justclick_pos_test');

    $tenant = Tenant::factory()->create();
    $actor = Employee::factory()->owner()->create(['tenant_id' => $tenant->id]);
    $context = app(TenantContext::class);
    $context->set($tenant);

    $outlet = Outlet::create(['name' => 'Race']);
    $register = PosRegister::create(['name' => 'Race', 'outlet_id' => $outlet->id]);

    $issued = app(DeviceActivation::class)->issue($actor, $register->id);
    $activation = app(DeviceActivation::class)->activate([
        'code' => $issued['code'], 'device_uuid' => (string) Str::uuid(),
    ]);
    $device = Device::query()->findOrFail($activation['device']['id']);

    $config = config('database.connections.pgsql');
    $workerName = 'session-race-'.Str::uuid();
    $workers = [];

    // Hold the tenant lock so both workers are parked on it before either can
    // read the register — that is what makes the overlap real rather than
    // hoped-for.
    DB::beginTransaction();
    Tenant::whereKey($tenant->id)->lockForUpdate()->firstOrFail();

    try {
        for ($i = 0; $i < 2; $i++) {
            $process = new Process([PHP_BINARY, base_path('tests/Support/session_push_worker.php')], base_path(), [
                'APP_ENV' => 'testing', 'DB_CONNECTION' => 'pgsql', 'DB_URL' => '',
                'DB_HOST' => $config['host'], 'DB_PORT' => (string) $config['port'],
                'DB_DATABASE' => $config['database'], 'DB_USERNAME' => $config['username'],
                'DB_PASSWORD' => $config['password'], 'CACHE_STORE' => 'array',
            ]);
            $process->setInput(json_encode([
                'worker_name' => $workerName,
                'tenant_id' => $tenant->id,
                'device_id' => $device->id,
                'row' => [
                    'id' => (string) Str::uuid(),
                    'employee_name' => "Cashier {$i}",
                    'opened_at' => now()->getTimestampMs(),
                    'opening_cash' => 100000,
                ],
            ], JSON_THROW_ON_ERROR));
            $process->setTimeout(20);
            $process->start();
            $workers[] = $process;
        }

        $deadline = microtime(true) + 10;
        do {
            DB::select('SELECT pg_stat_clear_snapshot()');
            $waiting = DB::selectOne(
                "SELECT count(*) AS total FROM pg_stat_activity WHERE application_name = ? AND wait_event_type = 'Lock'",
                [$workerName]
            )->total;
            if ((int) $waiting === 2) {
                break;
            }
            usleep(20000);
        } while (microtime(true) < $deadline);

        expect((int) $waiting)->toBe(2);
        DB::commit();

        $statuses = [];
        foreach ($workers as $worker) {
            $worker->wait();
            expect($worker->isSuccessful())->toBeTrue($worker->getErrorOutput());
            $statuses[] = $worker->getOutput();
        }

        sort($statuses);
        expect($statuses)->toBe(['accepted', 'rejected'])
            ->and(DB::table('pos_sessions')->whereNull('closed_at')->count())->toBe(1);
    } finally {
        if (DB::transactionLevel() > 0) {
            DB::rollBack();
        }
        foreach ($workers as $worker) {
            if ($worker->isRunning()) {
                $worker->stop();
            }
        }
    }
});
