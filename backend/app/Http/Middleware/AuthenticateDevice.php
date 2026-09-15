<?php

declare(strict_types=1);

namespace App\Http\Middleware;

use App\Models\Device;
use App\Support\TenantContext;
use Closure;
use Illuminate\Auth\AuthenticationException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Laravel\Sanctum\PersonalAccessToken;
use Symfony\Component\HttpFoundation\Response;

class AuthenticateDevice
{
    public function __construct(private readonly TenantContext $context) {}

    public function handle(Request $request, Closure $next): Response
    {
        $this->context->clear();
        try {
            Auth::shouldUse('sanctum');
            $device = $request->user();
            if (! $device instanceof Device || ! $device->currentAccessToken() instanceof PersonalAccessToken
                || $device->revoked_at !== null || ! $device->tenant?->isActive()) {
                throw new AuthenticationException;
            }
            $this->context->set($device->tenant);
            $register = $device->posRegister;
            $outlet = $device->outlet;
            if (! $register?->active || ! $outlet?->active
                || $register->outlet_id !== $outlet->id) {
                throw new AuthenticationException;
            }
            abort_unless($device->tokenCan('device:access'), 403);
            $device->forceFill(['last_seen_at' => now()])->save();

            return $next($request);
        } finally {
            $this->context->clear();
        }
    }
}
