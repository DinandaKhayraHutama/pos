<?php

use App\Http\Middleware\AuthenticateDevice;
use App\Http\Middleware\ResolveTenant;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;
use Illuminate\Routing\Middleware\ThrottleRequests;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        api: __DIR__.'/../routes/api.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
        apiPrefix: 'api/v1',
    )
    ->withMiddleware(function (Middleware $middleware): void {
        // Wrap the entire web request, including Livewire hydration/actions.
        // Persistent middleware runs in a short inner pipeline; putting tenant
        // cleanup there clears the context BEFORE the component is executed.
        // The web group has already started the session at this point.
        $middleware->web(append: [ResolveTenant::class]);

        $middleware->prependToPriorityList(
            ThrottleRequests::class,
            AuthenticateDevice::class,
        );
        // Retain the alias for explicitly scoped routes outside the web group.
        // API devices resolve their identity in their own middleware.
        $middleware->alias([
            'tenant' => ResolveTenant::class,
            'device' => AuthenticateDevice::class,
        ]);
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        $exceptions->shouldRenderJsonWhen(fn (Request $request, Throwable $e) => $request->is('api/*') || $request->expectsJson());
        $exceptions->dontFlash(['code', 'token', 'password', 'password_confirmation', 'current_password']);
    })->create();
