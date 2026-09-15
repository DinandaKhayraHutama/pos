<?php

declare(strict_types=1);

namespace Database\Factories;

use App\Domain\Auth\Role;
use App\Models\Employee;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Facades\Hash;

/** @extends Factory<Employee> */
class EmployeeFactory extends Factory
{
    protected $model = Employee::class;

    public function definition(): array
    {
        return [
            'name' => $this->faker->name(),
            'email' => $this->faker->unique()->safeEmail(),
            'password' => 'password',
            'pin_hash' => null,
            'role' => Role::Owner,
            'active' => true,
            'sort_order' => 0,
        ];
    }

    public function owner(): static
    {
        return $this->state(fn (): array => ['role' => Role::Owner]);
    }

    public function manager(): static
    {
        return $this->state(fn (): array => ['role' => Role::Manager]);
    }

    /**
     * A till account: a PIN, and no browser password at all.
     *
     * Mirrors the real shape — a cashier never signs into the Backoffice, so
     * giving them a password in tests would hide a missing guard check.
     */
    public function cashier(string $pin = '2345'): static
    {
        return $this->state(fn (): array => [
            'role' => Role::Cashier,
            'email' => null,
            'password' => null,
            'pin_hash' => Hash::make($pin),
        ]);
    }

    public function inactive(): static
    {
        return $this->state(fn (): array => ['active' => false]);
    }
}
