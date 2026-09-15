<?php

declare(strict_types=1);

use App\Models\Employee;
use App\Models\Outlet;
use App\Models\PosRegister;
use App\Models\Tenant;
use App\Support\TenantContext;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

it('enforces tenant outlet register device and issuer consistency in PostgreSQL', function (string $target) {
    $context = app(TenantContext::class);
    $a = Tenant::factory()->create();
    $b = Tenant::factory()->create();
    $outletA = $context->runAs($a, fn () => Outlet::create(['name' => 'A']));
    $outletB = $context->runAs($b, fn () => Outlet::create(['name' => 'B']));
    $register = $context->runAs($a, fn () => PosRegister::create(['name' => 'Till', 'outlet_id' => $outletA->id]));
    $employeeB = Employee::factory()->owner()->create(['tenant_id' => $b->id]);
    // Raw SQL deliberately bypasses model protection to prove database FKs.
    $id = (string) Str::uuid();
    match ($target) {
        'register' => DB::table('pos_registers')->insert([
            'id' => $id, 'tenant_id' => $a->id, 'outlet_id' => $outletB->id, 'name' => 'Bad',
        ]),
        'device' => DB::table('devices')->insert([
            'id' => $id, 'tenant_id' => $a->id, 'outlet_id' => $outletB->id,
            'pos_register_id' => $register->id, 'device_uuid' => (string) Str::uuid(),
        ]),
        'issuer' => DB::table('activation_codes')->insert([
            'id' => $id, 'tenant_id' => $a->id, 'pos_register_id' => $register->id,
            'issued_by_employee_id' => $employeeB->id, 'code_hash' => str_repeat('a', 64), 'expires_at' => now(),
        ]),
    };
})->with(['register', 'device', 'issuer'])->throws(QueryException::class);
