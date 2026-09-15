<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Platform-level accounts and the session store.
 *
 * Laravel's default `users` table is deliberately replaced by `super_admins`.
 * There is no generic "user" in this system: a person is either platform staff
 * (this table — creates merchants, never belongs to one) or a merchant's
 * employee (`employees` — always belongs to exactly one tenant). Keeping a
 * `users` table alongside those two would be a third identity nobody owns.
 *
 * `super_admins` lives OUTSIDE tenant scope on purpose: it is the one table
 * whose rows must be readable while no tenant is resolved yet.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('super_admins', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->string('email')->unique();
            $table->timestamp('email_verified_at')->nullable();
            $table->string('password');
            $table->rememberToken();
            $table->timestamps();
        });

        Schema::create('password_reset_tokens', function (Blueprint $table) {
            $table->string('email')->primary();
            $table->string('token');
            $table->timestamp('created_at')->nullable();
        });

        Schema::create('sessions', function (Blueprint $table) {
            $table->string('id')->primary();
            // String rather than foreignId: this table is shared by two guards
            // whose keys differ in type — super admins are auto-increment ints,
            // employees are UUIDs. A bigint column would silently truncate one
            // of them.
            $table->string('user_id')->nullable()->index();
            $table->string('ip_address', 45)->nullable();
            $table->text('user_agent')->nullable();
            $table->longText('payload');
            $table->integer('last_activity')->index();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('super_admins');
        Schema::dropIfExists('password_reset_tokens');
        Schema::dropIfExists('sessions');
    }
};
