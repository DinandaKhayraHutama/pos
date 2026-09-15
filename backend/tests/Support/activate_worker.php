<?php

use App\Domain\Devices\DeviceActivation;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\ValidationException;

require __DIR__.'/../../vendor/autoload.php';
$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

if (! $app->environment('testing') || config('database.connections.pgsql.database') !== 'justclick_pos_test') {
    exit(2);
}
$input = json_decode(stream_get_contents(STDIN), true, flags: JSON_THROW_ON_ERROR);
DB::select("SELECT set_config('application_name', ?, false)", [$input['worker_name']]);
try {
    app(DeviceActivation::class)->activate($input['payload']);
    echo '201';
} catch (ValidationException) {
    echo '422';
}
