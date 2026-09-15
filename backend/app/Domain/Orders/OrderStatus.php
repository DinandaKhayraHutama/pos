<?php

declare(strict_types=1);

namespace App\Domain\Orders;

/**
 * Where an order stands. Mirrors the device's `OrderStatus` wire values exactly.
 */
enum OrderStatus: string
{
    case Pending = 'pending';
    case Preparing = 'preparing';
    case Ready = 'ready';
    case Served = 'served';
    case Paid = 'paid';
    case Cancelled = 'cancelled';
    case Refunded = 'refunded';

    /**
     * Statuses that count towards takings.
     *
     * The server mirror of the device's `kRevenueStatusSql`, which lives in ONE
     * place there because it appears in seven aggregates — and a report where
     * six of them exclude refunds and the seventh does not is a bug nobody
     * spots until the columns fail to add up. Same rule here.
     *
     * @return list<string>
     */
    public static function revenueValues(): array
    {
        return array_values(
            array_map(
                fn (self $s): string => $s->value,
                array_filter(self::cases(), fn (self $s): bool => ! $s->isSettled())
            )
        );
    }

    /**
     * True once the sale has been undone — cancelled or refunded.
     *
     * Called "settled" rather than "cancelled" because both share the property
     * that matters: stock has been returned, the money is no longer revenue,
     * and neither may happen twice.
     */
    public function isSettled(): bool
    {
        return $this === self::Cancelled || $this === self::Refunded;
    }
}
