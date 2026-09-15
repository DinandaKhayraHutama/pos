<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * A merchant's staff member — the server side of the Flutter app's `employees`
 * table, and the authenticatable behind the Backoffice panel.
 *
 * One row per person, not one per surface. The same human is the Owner who
 * signs into the Backoffice with an email and the person whose name lands on a
 * receipt, so splitting this into "backoffice users" and "till employees"
 * would be two rows to keep in step for no gain.
 *
 * That is why both credentials are nullable and neither implies the other:
 *
 * - `password` — set only for staff who actually open the Backoffice in a
 *   browser (Owner, Manager). A cashier who never logs into a browser has none.
 * - `pin_hash` — set only for staff who stand at a till. Hashed, never plain:
 *   the Flutter app's plaintext `pin` column is documented in its own source as
 *   a demo shortcut that must move behind the API, and this is that move.
 *
 * `id` is a UUID so a row created here can be referenced by an offline device
 * without a server round-trip to learn its key — the same reason the Flutter
 * app already generates UUIDs for orders and shifts.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('employees', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->foreignUuid('tenant_id')->constrained()->cascadeOnDelete();
            $table->string('name');

            // Globally unique, not per-tenant: Backoffice login resolves an
            // account from the email alone, so the same address in two tenants
            // would make "who is signing in" ambiguous.
            $table->string('email')->nullable()->unique();
            $table->string('password')->nullable();

            // Bcrypt, so it cannot be searched by value. PIN uniqueness within
            // a tenant is therefore an application-level check (hash-compare
            // across the tenant's staff), not a unique index — see the
            // Employee model.
            $table->string('pin_hash')->nullable();

            $table->string('role')->index();
            $table->boolean('active')->default(true);
            $table->unsignedInteger('sort_order')->default(0);
            $table->rememberToken();
            $table->timestamps();

            // Every tenant-scoped read filters on tenant_id first; the role
            // and active flags are what the Backoffice staff list sorts on.
            $table->index(['tenant_id', 'active']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('employees');
    }
};
