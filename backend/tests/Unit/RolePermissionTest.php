<?php

declare(strict_types=1);

use App\Domain\Auth\Permission;
use App\Domain\Auth\Role;

/**
 * Locks the server's role map to the device's.
 *
 * These expectations are a transcription of
 * `mobile/lib/core/auth/permissions.dart`. If that file changes and this one
 * does not, a permission means one thing on the tablet and another on the
 * server — which surfaces as a cashier being allowed to do something the till
 * refused, or the reverse.
 */
it('mirrors the device permission vocabulary exactly', function () {
    expect(Permission::values())->toBe([
        'sell',
        'manageTables',
        'openCloseShift',
        'viewOwnOrders',
        'viewAllOrders',
        'voidOrder',
        'refundOrder',
        'applyManualDiscount',
        'viewCashDrawer',
        'adjustStock',
        'manageCatalogue',
        'manageEmployees',
        'managePromos',
        'viewDailySummary',
        'viewFinancialReports',
        'manageSettings',
        'manageOutlets',
    ]);
});

it('gives a cashier the till, the floor and their own sales', function () {
    expect(Role::Cashier->permissionValues())
        ->toEqualCanonicalizing(['sell', 'openCloseShift', 'manageTables', 'viewOwnOrders']);
});

it('keeps the till away from managers and owners', function (Role $role) {
    expect($role->grants(Permission::Sell))->toBeFalse()
        ->and($role->grants(Permission::OpenCloseShift))->toBeFalse();
})->with([Role::Manager, Role::Owner]);

it('withholds the catalogue and financial reports from a manager', function () {
    expect(Role::Manager->grants(Permission::ManageCatalogue))->toBeFalse()
        ->and(Role::Manager->grants(Permission::ViewFinancialReports))->toBeFalse()
        ->and(Role::Manager->grants(Permission::ManageEmployees))->toBeFalse()
        ->and(Role::Manager->grants(Permission::ManageSettings))->toBeFalse();
});

it('gives a manager the exceptions and the floor', function () {
    expect(Role::Manager->permissionValues())->toEqualCanonicalizing([
        'manageTables',
        'viewAllOrders',
        'voidOrder',
        'refundOrder',
        'applyManualDiscount',
        'viewCashDrawer',
        'adjustStock',
        'viewDailySummary',
        'manageOutlets',
    ]);
});

it('derives the owner as everything except the till', function () {
    $expected = array_values(array_diff(
        Permission::values(),
        ['sell', 'openCloseShift'],
    ));

    expect(Role::Owner->permissionValues())->toEqualCanonicalizing($expected)
        ->and(Role::Owner->permissionValues())->toHaveCount(count(Permission::cases()) - 2);
});

it('reaches the owner automatically when a permission is added', function () {
    // The property that makes the owner set derived rather than hand-listed:
    // every permission except the two till ones is covered, whatever the enum
    // grows to next.
    foreach (Permission::cases() as $permission) {
        $expected = ! in_array($permission, Role::tillPermissions(), strict: true);

        expect(Role::Owner->grants($permission))->toBe(
            $expected,
            'Owner should '.($expected ? 'hold' : 'not hold')." {$permission->value}",
        );
    }
});

it('lets only senior roles authorize an override', function () {
    expect(Role::Cashier->canAuthorizeOverrides())->toBeFalse()
        ->and(Role::Manager->canAuthorizeOverrides())->toBeTrue()
        ->and(Role::Owner->canAuthorizeOverrides())->toBeTrue();
});

it('sends everyone except a cashier to the dashboard', function () {
    expect(Role::Cashier->homeRoute())->toBe('/')
        ->and(Role::Manager->homeRoute())->toBe('/dashboard')
        ->and(Role::Owner->homeRoute())->toBe('/dashboard');
});

it('keeps a cashier out of the backoffice', function () {
    expect(Role::Cashier->usesBackoffice())->toBeFalse()
        ->and(Role::Manager->usesBackoffice())->toBeTrue()
        ->and(Role::Owner->usesBackoffice())->toBeTrue();
});
