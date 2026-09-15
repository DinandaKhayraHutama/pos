<?php

declare(strict_types=1);

use App\Http\Controllers\DeviceController;
use App\Http\Controllers\SyncController;
use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\Route;

Route::post('/devices/activate', [DeviceController::class, 'activate'])
    ->middleware('throttle:device-activation')->name('devices.activate');
Route::get('/devices/me', [DeviceController::class, 'show'])
    ->middleware(['device', 'throttle:device-api'])->name('devices.me');

// Catalogue pull. Same guard as every other device route: the token identifies
// the till, and the tenant is resolved from it — never from a parameter.
Route::middleware(['device', 'throttle:device-api'])->group(function (): void {
    Route::get('/sync/manifest', [SyncController::class, 'manifest'])->name('sync.manifest');
    Route::get('/sync/pull', [SyncController::class, 'pull'])->name('sync.pull');

    // The other direction: rows a till authored. Same guard, because the token
    // is what says which register the sale or session belongs to.
    Route::post('/sync/push', [SyncController::class, 'push'])->name('sync.push');
});

/*
|--------------------------------------------------------------------------
| API v1
|--------------------------------------------------------------------------
|
| Versioned in the path (`/api/v1/...`, set in bootstrap/app.php). A breaking
| change gets a `/api/v2` rather than a quiet edit to these contracts: a till
| that has not been updated must keep working when the server moves on, and a
| device in a shop with no wifi can be weeks behind.
|
*/

/**
 * Liveness probe.
 *
 * Deliberately the first endpoint in the system and deliberately trivial: when
 * a device cannot reach the API, the first question is whether the problem is
 * the network, the server, or the request — and this answers it without
 * credentials, a database, or any tenant resolution in the way.
 */
Route::get('/health', fn (): JsonResponse => response()->json([
    'status' => 'ok',
    'service' => config('app.name'),
    'time' => now()->toIso8601String(),
]))->name('health');
