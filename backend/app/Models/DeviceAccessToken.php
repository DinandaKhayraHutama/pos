<?php

declare(strict_types=1);

namespace App\Models;

use App\Support\TenantContext;
use Laravel\Sanctum\PersonalAccessToken;

class DeviceAccessToken extends PersonalAccessToken
{
    protected $table = 'personal_access_tokens';

    public static function findToken($token)
    {
        // Verify the secret FIRST. Only this authenticated lookup may resolve a
        // device before its tenant is known; ordinary Device queries fail closed.
        $accessToken = parent::findToken($token);
        if ($accessToken !== null && $accessToken->tokenable_type === (new Device)->getMorphClass()) {
            app(TenantContext::class)->runUnscoped(fn () => $accessToken->load('tokenable'));
        }

        return $accessToken;
    }
}
