<?php

declare(strict_types=1);

namespace App\Domain\Reporting;

/**
 * One category's contribution to a sales report.
 *
 * `grossSales` is the sum of line totals before any order-level discount;
 * `netSales` is that minus the discount allocated to this category. Both are
 * **pre-tax and pre-service-charge**, deliberately: PB1 and service charge have
 * their own lines in the report, and allocating either per category would be a
 * second proportional split nobody asked for.
 *
 * The consequence, which surprises people: `Σ netSales` reconciles to
 * `Σ(subtotal − discount)`, NOT to the report's revenue figure.
 */
final class CategorySales
{
    /** Lines that had no category at all — a product deleted before the snapshot existed. */
    public const UNCATEGORISED_ID = '__uncategorised__';

    public function __construct(
        public readonly string $categoryId,
        public readonly string $name,
        public readonly int $grossSales,
        public readonly int $netSales,
        public readonly int $itemsSold,
        public readonly float $contributionPercent,
    ) {}

    /** @return array<string, mixed> */
    public function toArray(): array
    {
        return [
            'category_id' => $this->categoryId,
            'name' => $this->name,
            'gross_sales' => $this->grossSales,
            'net_sales' => $this->netSales,
            'items_sold' => $this->itemsSold,
            'contribution_percent' => $this->contributionPercent,
        ];
    }
}
