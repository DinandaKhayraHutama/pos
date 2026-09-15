<?php

declare(strict_types=1);

namespace App\Domain\Auth;

/**
 * The three roles, and what each one carries.
 *
 * This is a deliberate port of `mobile/lib/core/auth/permissions.dart`, kept in
 * code rather than in database rows. Two properties of the Dart original are
 * the reason:
 *
 * 1. `owner` is DERIVED — every permission except the till set. A new
 *    permission therefore reaches the owner automatically. A seeded
 *    role-permission table cannot have that property: it would need re-seeding
 *    on every new permission, and forgetting is silent.
 * 2. There is exactly one source of truth. A DB-backed copy of this mapping
 *    would be a second place for it to live, free to drift from the device's
 *    copy — which is the failure the "screens ask for a permission, never a
 *    role" discipline exists to prevent in the first place.
 *
 * Custom, merchant-editable roles are a later phase. When they land, they layer
 * ON TOP of these three defaults rather than replacing them, and that is the
 * point at which a database-backed permission package earns its place.
 */
enum Role: string
{
    case Cashier = 'cashier';
    case Manager = 'manager';
    case Owner = 'owner';

    /**
     * Running the till: taking money, and being accountable for a drawer.
     *
     * Held ONLY by cashiers. A manager or owner covering the counter signs in
     * on a cashier account — which is also the honest outcome for attribution,
     * since the sale belongs to whoever was actually at the till.
     *
     * @return list<Permission>
     */
    public static function tillPermissions(): array
    {
        return [Permission::Sell, Permission::OpenCloseShift];
    }

    /**
     * The permissions this role carries.
     *
     * @return list<Permission>
     */
    public function permissions(): array
    {
        return match ($this) {
            self::Cashier => [
                ...self::tillPermissions(),
                Permission::ManageTables,
                Permission::ViewOwnOrders,
            ],

            // Spelled out rather than spread from cashier, because a manager is
            // no longer a superset of one: their job is the numbers and the
            // exceptions, not ringing up sales. Screens they do not need are
            // screens they cannot mis-tap during service.
            self::Manager => [
                Permission::ManageTables,
                Permission::ViewAllOrders,
                Permission::VoidOrder,
                Permission::RefundOrder,
                Permission::ApplyManualDiscount,
                Permission::ViewCashDrawer,
                Permission::AdjustStock,
                Permission::ViewDailySummary,
                Permission::ManageOutlets,
            ],

            // Everything except the till — derived, so a newly added permission
            // reaches the owner without anyone remembering to add it here.
            self::Owner => array_values(
                array_udiff(
                    Permission::cases(),
                    self::tillPermissions(),
                    static fn (Permission $a, Permission $b): int => $a->value <=> $b->value,
                )
            ),
        };
    }

    /** @return list<string> */
    public function permissionValues(): array
    {
        return array_map(static fn (Permission $p): string => $p->value, $this->permissions());
    }

    public function grants(Permission $permission): bool
    {
        return in_array($permission, $this->permissions(), strict: true);
    }

    /**
     * True when this role can authorize an action a cashier is blocked from.
     *
     * Used by the device's override prompt: a cashier hands the till to someone
     * senior, who approves one action without signing anyone out.
     */
    public function canAuthorizeOverrides(): bool
    {
        return $this !== self::Cashier;
    }

    /**
     * Where someone lands after signing in on the device.
     *
     * A cashier opens on the till because that is the job; everyone else has no
     * till permissions at all and would be bounced straight back out of it.
     */
    public function homeRoute(): string
    {
        return $this === self::Cashier ? '/' : '/dashboard';
    }

    /**
     * True when this role belongs in the web Backoffice.
     *
     * A cashier's world is the till app. They hold no permission that the
     * Backoffice surfaces, so letting them reach a login form for it would be
     * an empty panel and a support question.
     */
    public function usesBackoffice(): bool
    {
        return $this !== self::Cashier;
    }
}
