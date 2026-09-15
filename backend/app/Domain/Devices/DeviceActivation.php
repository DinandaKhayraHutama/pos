<?php

declare(strict_types=1);

namespace App\Domain\Devices;

use App\Domain\Auth\Permission;
use App\Models\ActivationCode;
use App\Models\Device;
use App\Models\Employee;
use App\Models\PosRegister;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\DB;
use Illuminate\Validation\ValidationException;

class DeviceActivation
{
    public function __construct(private readonly TenantContext $context) {}

    public static function fingerprint(string $code): string
    {
        return hash_hmac('sha256', $code, config('app.key'));
    }

    public function authorize(Employee $actor): void
    {
        $current = Employee::query()->find($actor->id);
        abort_unless($current?->canAccessBackoffice()
            && $current->hasPermission(Permission::ManageOutlets)
            && $this->context->current()?->isActive(), 403);
    }

    /** Serialize issuance, activation and revocation per merchant. */
    private function lockTenant(): Tenant
    {
        $tenant = Tenant::query()->whereKey($this->context->requireId())->lockForUpdate()->firstOrFail();
        $this->context->set($tenant);

        return $tenant;
    }

    /** Plaintext is returned once, never stored in a model or log. */
    public function issue(Employee $actor, string $registerId): array
    {
        return DB::transaction(function () use ($actor, $registerId) {
            $tenant = $this->lockTenant();
            $this->authorize($actor);
            abort_unless($tenant->isActive(), 403);
            $register = PosRegister::query()->with('outlet')->findOrFail($registerId);
            if (! $register->active || ! $register->outlet?->active) {
                throw ValidationException::withMessages(['pos_register_id' => 'Choose an active register and outlet.']);
            }

            ActivationCode::query()->where('pos_register_id', $register->id)
                ->whereNull('used_at')->whereNull('cancelled_at')->update(['cancelled_at' => now()]);
            $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
            $code = '';
            for ($i = 0; $i < 12; $i++) {
                $code .= $alphabet[random_int(0, strlen($alphabet) - 1)];
            }
            $activation = new ActivationCode;
            $activation->forceFill([
                'pos_register_id' => $register->id,
                'code_hash' => self::fingerprint($code),
                'expires_at' => now()->addMinutes(config('devices.activation_ttl_minutes')),
                'issued_by_employee_id' => $actor->id,
            ])->save();

            return ['code' => $code, 'expires_at' => $activation->expires_at->toIso8601String()];
        }, 3);
    }

    public function activate(array $input): array
    {
        $hash = self::fingerprint($input['code']);
        // The one unauthenticated cross-tenant lookup: the high-entropy secret
        // locates a merchant, never a client-supplied tenant/outlet/register ID.
        $candidate = $this->context->runUnscoped(
            fn () => ActivationCode::query()->where('code_hash', $hash)->first()
        );
        if ($candidate === null) {
            $this->invalidCode();
        }

        return DB::transaction(function () use ($candidate, $hash, $input) {
            $tenant = Tenant::query()->whereKey($candidate->tenant_id)->lockForUpdate()->first();
            if (! $tenant?->isActive()) {
                $this->invalidCode();
            }

            return $this->context->runAs($tenant, function () use ($hash, $input, $tenant) {
                $activation = ActivationCode::query()->where('code_hash', $hash)->lockForUpdate()->first();
                if ($activation === null || $activation->used_at !== null
                    || $activation->cancelled_at !== null || $activation->expires_at->lte(now())) {
                    $this->invalidCode();
                }
                $register = PosRegister::query()->with('outlet')->find($activation->pos_register_id);
                if (! $register?->active || ! $register->outlet?->active) {
                    $this->invalidCode();
                }

                // UUID is an installation identifier, not a credential. A NEW
                // code authorizes reactivation and rotates every previous token.
                $device = Device::query()->where('device_uuid', strtolower($input['device_uuid']))->first() ?? new Device;
                if ($device->exists && $device->pos_register_id !== $register->id) {
                    throw ValidationException::withMessages(['device_uuid' => 'This installation is already bound to another register.']);
                }
                $device->forceFill([
                    'device_uuid' => strtolower($input['device_uuid']),
                    'outlet_id' => $register->outlet_id,
                    'pos_register_id' => $register->id,
                    'label' => $input['label'] ?? null,
                    'platform' => $input['platform'] ?? null,
                    'revoked_at' => null,
                    'last_seen_at' => now(),
                ])->save();
                $device->tokens()->delete();
                $expiresAt = now()->addDays(config('devices.token_ttl_days'));
                $token = $device->createToken('pos-device', ['device:access'], $expiresAt);
                $activation->forceFill(['used_at' => now(), 'device_id' => $device->id])->save();

                return [
                    'token' => $token->plainTextToken,
                    'token_expires_at' => $expiresAt->toIso8601String(),
                    'device' => $device->only(['id', 'device_uuid', 'label', 'platform']),
                    'tenant' => $tenant->only(['id', 'name']),
                    'outlet' => $register->outlet->only(['id', 'name', 'address', 'phone']),
                    'pos_register' => $register->only(['id', 'outlet_id', 'name', 'table_service']),
                ];
            });
        }, 3);
    }

    public function revoke(Employee $actor, string $deviceId): void
    {
        DB::transaction(function () use ($actor, $deviceId) {
            $this->lockTenant();
            $this->authorize($actor);
            $device = Device::query()->findOrFail($deviceId);
            $device->forceFill(['revoked_at' => $device->revoked_at ?? now()])->save();
            $device->tokens()->delete();
            // Also invalidate outstanding setup credentials for this till.
            ActivationCode::query()->where('pos_register_id', $device->pos_register_id)
                ->whereNull('used_at')->whereNull('cancelled_at')->update(['cancelled_at' => now()]);
        }, 3);
    }

    private function invalidCode(): never
    {
        throw ValidationException::withMessages(['code' => 'The activation code is invalid or expired.']);
    }
}
