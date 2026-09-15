<?php

declare(strict_types=1);

use App\Domain\Devices\DeviceActivation;
use App\Models\ActivationCode;
use App\Models\Device;
use App\Models\DeviceAccessToken;
use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

beforeEach(function () {
    $this->context = app(TenantContext::class);
    $this->tenant = Tenant::factory()->create();
    $this->owner = Employee::factory()->owner()->create(['tenant_id' => $this->tenant->id]);
    $this->context->set($this->tenant);
    $this->outlet = Outlet::create(['name' => 'Pusat']);
    $this->register = PosRegister::create(['name' => 'Kasir 1', 'outlet_id' => $this->outlet->id]);
    $this->activation = app(DeviceActivation::class);
    $this->code = $this->activation->issue($this->owner, $this->register->id)['code'];
    $this->payload = ['code' => $this->code, 'device_uuid' => (string) Str::uuid()];
    $this->context->clear();
});

function deviceRequest($test, string $token)
{
    Auth::forgetGuards();

    return $test->withToken($token)->getJson('/api/v1/devices/me');
}

it('activates a UUID device with a real Sanctum token and correct context', function () {
    $body = $this->postJson('/api/v1/devices/activate', $this->payload)
        ->assertCreated()->assertHeader('Cache-Control', 'no-store, private')
        ->assertJsonPath('outlet.id', $this->outlet->id)
        ->assertJsonPath('pos_register.id', $this->register->id)->json();
    expect(Str::isUuid($body['device']['id']))->toBeTrue()
        ->and($body['token'])->not->toBe(DB::table('personal_access_tokens')->value('token'));
    deviceRequest($this, $body['token'])->assertOk()->assertJsonPath('tenant.id', $this->tenant->id);
    expect($this->context->hasTenant())->toBeFalse();
    $this->context->runAs($this->tenant, function () {
        expect(Device::first()->last_seen_at)->not->toBeNull()
            ->and(ActivationCode::first()->used_at)->not->toBeNull();
    });
});

it('never stores plaintext activation codes or exposes their hash in model JSON', function () {
    $record = $this->context->runAs($this->tenant, fn () => ActivationCode::first());
    expect($record->code_hash)->toBe(DeviceActivation::fingerprint($this->code))
        ->and($record->toArray())->not->toHaveKey('code_hash')
        ->and(json_encode(DB::table('activation_codes')->first()))->not->toContain($this->code);
});

it('rejects expired codes including the exact expiry boundary', function () {
    $expires = $this->context->runAs($this->tenant, fn () => ActivationCode::first()->expires_at);
    $this->travelTo($expires);
    $this->postJson('/api/v1/devices/activate', $this->payload)->assertUnprocessable()->assertJsonValidationErrors('code');
    expect(DB::table('devices')->count())->toBe(0);
});

it('burns a code once and never returns a second token', function () {
    $this->postJson('/api/v1/devices/activate', $this->payload)->assertCreated();
    $this->postJson('/api/v1/devices/activate', $this->payload)->assertUnprocessable();
    expect(DB::table('devices')->count())->toBe(1)->and(DB::table('personal_access_tokens')->count())->toBe(1);
});

it('cancels an older code when a replacement is issued', function () {
    $new = $this->context->runAs($this->tenant, fn () => $this->activation->issue($this->owner, $this->register->id));
    $this->postJson('/api/v1/devices/activate', $this->payload)->assertUnprocessable();
    $this->postJson('/api/v1/devices/activate', [...$this->payload, 'code' => $new['code']])->assertCreated();
});

it('rejects inactive activation targets', function (string $target) {
    if ($target === 'tenant') {
        $this->tenant->update(['status' => Tenant::STATUS_SUSPENDED]);
    } else {
        $this->context->runAs($this->tenant, fn () => $this->{$target}->update(['active' => false]));
    }
    $this->postJson('/api/v1/devices/activate', $this->payload)->assertUnprocessable();
    expect(DB::table('personal_access_tokens')->count())->toBe(0);
})->with(['tenant', 'outlet', 'register']);

it('rejects client supplied context', function (string $field) {
    $this->postJson('/api/v1/devices/activate', [...$this->payload, $field => (string) Str::uuid()])
        ->assertUnprocessable()->assertJsonValidationErrors($field);
})->with(['tenant_id', 'outlet_id', 'pos_register_id']);

it('validates input without consuming a valid code', function (array $bad) {
    $this->postJson('/api/v1/devices/activate', [...$this->payload, ...$bad])->assertUnprocessable();
    expect(DB::table('activation_codes')->value('used_at'))->toBeNull();
})->with([
    [['device_uuid' => 'bad']],
    [['code' => '1234']],
    [['platform' => 'unknown']],
    [['label' => str_repeat('a', 101)]],
]);

it('rate limits malformed attempts even when UUID and code change', function () {
    for ($i = 0; $i < 5; $i++) {
        $this->postJson('/api/v1/devices/activate', ['code' => (string) $i, 'device_uuid' => (string) Str::uuid()])->assertUnprocessable();
    }
    $this->postJson('/api/v1/devices/activate', $this->payload)->assertTooManyRequests()->assertHeader('Retry-After');
    expect(DB::table('devices')->count())->toBe(0);
});

it('revokes all tokens immediately and cancels pending setup codes', function () {
    $body = $this->postJson('/api/v1/devices/activate', $this->payload)->assertCreated()->json();
    $second = $this->context->runAs($this->tenant, function () use ($body) {
        return Device::findOrFail($body['device']['id'])->createToken('second', ['device:access'])->plainTextToken;
    });
    $pending = $this->context->runAs($this->tenant, fn () => $this->activation->issue($this->owner, $this->register->id));
    $this->context->runAs($this->tenant, fn () => $this->activation->revoke($this->owner, $body['device']['id']));
    deviceRequest($this, $body['token'])->assertUnauthorized();
    deviceRequest($this, $second)->assertUnauthorized();
    $this->postJson('/api/v1/devices/activate', [...$this->payload, 'code' => $pending['code']])->assertUnprocessable();
    expect(DB::table('personal_access_tokens')->count())->toBe(0);
});

it('rotates tokens when a new code reactivates the same installation', function () {
    $old = $this->postJson('/api/v1/devices/activate', $this->payload)->assertCreated()->json();
    $newCode = $this->context->runAs($this->tenant, fn () => $this->activation->issue($this->owner, $this->register->id));
    $new = $this->postJson('/api/v1/devices/activate', [...$this->payload, 'code' => $newCode['code']])->assertCreated()->json();
    expect($new['device']['id'])->toBe($old['device']['id']);
    deviceRequest($this, $old['token'])->assertUnauthorized();
    deviceRequest($this, $new['token'])->assertOk();
});

it('rejects revoked devices and inactive context even if a token row remains', function (string $target) {
    $body = $this->postJson('/api/v1/devices/activate', $this->payload)->assertCreated()->json();
    $this->context->runAs($this->tenant, function () use ($target, $body) {
        match ($target) {
            'device' => Device::find($body['device']['id'])->forceFill(['revoked_at' => now()])->save(),
            'tenant' => $this->tenant->update(['status' => Tenant::STATUS_SUSPENDED]),
            default => $this->{$target}->update(['active' => false]),
        };
    });
    deviceRequest($this, $body['token'])->assertUnauthorized();
    expect($this->context->hasTenant())->toBeFalse();
})->with(['device', 'tenant', 'outlet', 'register']);

it('rejects missing malformed and expired bearer tokens as JSON without Accept', function () {
    $this->get('/api/v1/devices/me')->assertUnauthorized();
    deviceRequest($this, '123|invalid')->assertUnauthorized();
    $body = $this->postJson('/api/v1/devices/activate', $this->payload)->assertCreated()->json();
    $this->travel(366)->days();
    deviceRequest($this, $body['token'])->assertUnauthorized();
});

it('requires the device ability and does not authenticate a backoffice cookie', function () {
    $body = $this->postJson('/api/v1/devices/activate', $this->payload)->assertCreated()->json();
    $token = $this->context->runAs($this->tenant, fn () => Device::find($body['device']['id'])->createToken('wrong', ['other'])->plainTextToken);
    deviceRequest($this, $token)->assertForbidden();
    Auth::forgetGuards();
    $this->flushHeaders()->actingAs($this->owner, 'backoffice')->getJson('/api/v1/devices/me')->assertUnauthorized();
});

it('rolls back code consumption and device creation when token storage fails', function () {
    DeviceAccessToken::creating(fn () => throw new RuntimeException('Token failure'));
    $this->withoutExceptionHandling();
    try {
        $this->postJson('/api/v1/devices/activate', $this->payload);
        test()->fail('Expected token failure');
    } catch (RuntimeException $exception) {
        expect($exception->getMessage())->toBe('Token failure');
    } finally {
        DeviceAccessToken::flushEventListeners();
    }
    expect(DB::table('devices')->count())->toBe(0)->and(DB::table('activation_codes')->value('used_at'))->toBeNull();
});

it('keeps the same client UUID independent across tenants and ignores forged context on reads', function () {
    $a = $this->postJson('/api/v1/devices/activate', $this->payload)->assertCreated()->json();
    $other = Tenant::factory()->create();
    $actor = Employee::factory()->owner()->create(['tenant_id' => $other->id]);
    $code = $this->context->runAs($other, function () use ($actor) {
        $outlet = Outlet::create(['name' => 'Other outlet']);
        $register = PosRegister::create(['name' => 'Other till', 'outlet_id' => $outlet->id]);

        return $this->activation->issue($actor, $register->id)['code'];
    });
    $b = $this->postJson('/api/v1/devices/activate', [...$this->payload, 'code' => $code])->assertCreated()->json();
    expect($a['device']['id'])->not->toBe($b['device']['id']);
    $this->context->set($other);
    Auth::forgetGuards();
    $this->withToken($a['token'])->getJson('/api/v1/devices/me?tenant_id='.$other->id)
        ->assertOk()->assertJsonPath('tenant.id', $this->tenant->id);
    deviceRequest($this, $b['token'])->assertOk()->assertJsonPath('tenant.id', $other->id);
});

it('does not move an existing installation to another register or burn its new code', function () {
    $this->postJson('/api/v1/devices/activate', $this->payload)->assertCreated();
    $code = $this->context->runAs($this->tenant, function () {
        $register = PosRegister::create(['name' => 'Other till', 'outlet_id' => $this->outlet->id]);

        return $this->activation->issue($this->owner, $register->id)['code'];
    });
    $this->postJson('/api/v1/devices/activate', [...$this->payload, 'code' => $code])
        ->assertUnprocessable()->assertJsonValidationErrors('device_uuid');
    expect(DB::table('activation_codes')->where('code_hash', DeviceActivation::fingerprint($code))->value('used_at'))->toBeNull();
});
