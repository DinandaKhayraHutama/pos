<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        foreach (['outlets', 'employees', 'devices', 'pos_registers'] as $name) {
            Schema::table($name, fn (Blueprint $table) => $table->unique(['tenant_id', 'id']));
        }
        Schema::table('pos_registers', function (Blueprint $table) {
            $table->unique(['tenant_id', 'outlet_id', 'id']);
            $table->foreign(['tenant_id', 'outlet_id'])->references(['tenant_id', 'id'])->on('outlets');
        });
        Schema::table('devices', function (Blueprint $table) {
            $table->foreign(['tenant_id', 'outlet_id', 'pos_register_id'], 'devices_register_context_fk')
                ->references(['tenant_id', 'outlet_id', 'id'])->on('pos_registers');
        });
        Schema::table('activation_codes', function (Blueprint $table) {
            $table->foreign(['tenant_id', 'pos_register_id'])->references(['tenant_id', 'id'])->on('pos_registers');
            $table->foreign(['tenant_id', 'issued_by_employee_id'], 'activation_codes_issuer_context_fk')
                ->references(['tenant_id', 'id'])->on('employees');
            $table->foreign(['tenant_id', 'device_id'])->references(['tenant_id', 'id'])->on('devices');
        });
    }

    public function down(): void
    {
        Schema::table('activation_codes', function (Blueprint $table) {
            $table->dropForeign(['tenant_id', 'pos_register_id']);
            $table->dropForeign('activation_codes_issuer_context_fk');
            $table->dropForeign(['tenant_id', 'device_id']);
        });
        Schema::table('devices', fn (Blueprint $table) => $table->dropForeign('devices_register_context_fk'));
        Schema::table('pos_registers', function (Blueprint $table) {
            $table->dropForeign(['tenant_id', 'outlet_id']);
            $table->dropUnique(['tenant_id', 'outlet_id', 'id']);
        });
        foreach (['outlets', 'employees', 'devices', 'pos_registers'] as $name) {
            Schema::table($name, fn (Blueprint $table) => $table->dropUnique(['tenant_id', 'id']));
        }
    }
};
