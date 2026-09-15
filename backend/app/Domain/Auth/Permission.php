<?php

declare(strict_types=1);

namespace App\Domain\Auth;

/**
 * A single capability — the server mirror of the Flutter app's `AppPermission`.
 *
 * The string values are byte-identical to the Dart enum names in
 * `mobile/lib/core/auth/permissions.dart` on purpose: a device and the server
 * must be able to talk about the same permission without a translation table
 * in between, and a translation table is a second thing to keep in step.
 *
 * Phrased as actions ("void an order"), never as screens — two roles can share
 * a screen and still differ on what the buttons do.
 */
enum Permission: string
{
    case Sell = 'sell';
    case ManageTables = 'manageTables';
    case OpenCloseShift = 'openCloseShift';
    case ViewOwnOrders = 'viewOwnOrders';
    case ViewAllOrders = 'viewAllOrders';
    case VoidOrder = 'voidOrder';
    case RefundOrder = 'refundOrder';
    case ApplyManualDiscount = 'applyManualDiscount';
    case ViewCashDrawer = 'viewCashDrawer';
    case AdjustStock = 'adjustStock';
    case ManageCatalogue = 'manageCatalogue';
    case ManageEmployees = 'manageEmployees';
    case ManagePromos = 'managePromos';
    case ViewDailySummary = 'viewDailySummary';
    case ViewFinancialReports = 'viewFinancialReports';
    case ManageSettings = 'manageSettings';
    case ManageOutlets = 'manageOutlets';

    /** @return list<string> */
    public static function values(): array
    {
        return array_map(static fn (self $p): string => $p->value, self::cases());
    }
}
