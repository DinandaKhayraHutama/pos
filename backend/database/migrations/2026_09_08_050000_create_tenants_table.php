<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * A merchant. The root of every isolation boundary in this system.
 *
 * Created by platform staff (`super_admins`), never self-service in the MVP —
 * onboarding a business is a commercial act, not a signup form.
 *
 * Lives OUTSIDE tenant scope for the obvious reason: it is the table the scope
 * is resolved FROM.
 */
return new class extends Migration
{
    public function up(): void
    {
        Schema::create('tenants', function (Blueprint $table) {
            $table->uuid('id')->primary();
            $table->string('name');
            // Stable, human-readable handle. Not derived from `name` at read
            // time: a merchant renaming their business must not silently break
            // anything already keyed on the slug.
            $table->string('slug')->unique();
            $table->string('status')->default('active')->index();
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('tenants');
    }
};
