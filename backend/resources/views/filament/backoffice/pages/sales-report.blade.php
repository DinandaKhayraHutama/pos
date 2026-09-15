@php
    $report = $this->getReport();
@endphp

<x-filament-panels::page>
    {{ $this->form }}

    {{-- The four figures a merchant reads first. --}}
    <div class="grid gap-4 md:grid-cols-4">
        @foreach ([
            ['Revenue', $this->rupiah($report['revenue']), $report['order_count'] . ' sales'],
            ['Average sale', $this->rupiah($report['average_order']), $report['items_sold'] . ' items'],
            ['Gross profit', $this->rupiah($report['gross_profit']), 'COGS ' . $this->rupiah($report['cost_of_goods'])],
            ['Discounts given', $this->rupiah($report['discount']), 'PB1 ' . $this->rupiah($report['tax'])],
        ] as [$label, $value, $note])
            <x-filament::section>
                <div class="text-sm text-gray-500 dark:text-gray-400">{{ $label }}</div>
                <div class="text-2xl font-semibold tabular-nums">{{ $value }}</div>
                <div class="text-xs text-gray-500 dark:text-gray-400">{{ $note }}</div>
            </x-filament::section>
        @endforeach
    </div>

    {{-- Only shown when it is low. A margin computed over half a catalogue
         looks excellent and means nothing, so the caveat has to travel with the
         number rather than live in a footnote nobody reads. --}}
    @if ($report['items_sold'] > 0 && $report['cost_coverage'] < 0.66)
        <x-filament::section>
            <p class="text-sm text-warning-600 dark:text-warning-400">
                Only {{ round($report['cost_coverage'] * 100) }}% of items sold have a cost recorded,
                so gross profit is an estimate. Fill in product costs to make it reliable.
            </p>
        </x-filament::section>
    @endif

    <div class="grid gap-4 md:grid-cols-2">
        <x-filament::section heading="By outlet">
            @forelse ($report['by_outlet'] as $row)
                <div class="flex justify-between py-1 text-sm">
                    <span>{{ $row['key'] ?? '—' }}</span>
                    <span class="tabular-nums">{{ $this->rupiah($row['value']) }}</span>
                </div>
            @empty
                <p class="text-sm text-gray-500">No sales in this window.</p>
            @endforelse
        </x-filament::section>

        <x-filament::section heading="By payment">
            @forelse ($report['by_payment'] as $row)
                <div class="flex justify-between py-1 text-sm">
                    <span>{{ $row['key'] }}</span>
                    <span class="tabular-nums">{{ $this->rupiah($row['value']) }}</span>
                </div>
            @empty
                <p class="text-sm text-gray-500">No sales in this window.</p>
            @endforelse
        </x-filament::section>

        <x-filament::section heading="By cashier">
            @forelse ($report['by_cashier'] as $row)
                <div class="flex justify-between py-1 text-sm">
                    <span>{{ $row['key'] ?? '—' }}</span>
                    <span class="tabular-nums">{{ $this->rupiah($row['value']) }}</span>
                </div>
            @empty
                <p class="text-sm text-gray-500">No sales in this window.</p>
            @endforelse
        </x-filament::section>

        {{-- Pre-tax and pre-service-charge on purpose: PB1 and service charge
             have their own lines above, and allocating either per category
             would be a second proportional split nobody asked for. So these
             sum to subtotal minus discount, NOT to revenue. --}}
        <x-filament::section heading="By category">
            @forelse ($report['by_category'] as $row)
                <div class="flex justify-between py-1 text-sm">
                    <span>{{ $row['name'] ?: 'Uncategorised' }}</span>
                    <span class="tabular-nums">
                        {{ $this->rupiah($row['net_sales']) }}
                        <span class="text-gray-500">({{ round($row['contribution_percent']) }}%)</span>
                    </span>
                </div>
            @empty
                <p class="text-sm text-gray-500">No sales in this window.</p>
            @endforelse
            <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Before tax and service charge, so these add up to revenue less PB1 and service charge.
            </p>
        </x-filament::section>
    </div>

    @if (filled($report['undone']))
        <x-filament::section heading="Voided and refunded">
            @foreach ($report['undone'] as $row)
                <div class="flex justify-between py-1 text-sm">
                    <span>{{ ucfirst($row['key']) }} ({{ $row['count'] }})</span>
                    <span class="tabular-nums">{{ $this->rupiah($row['value']) }}</span>
                </div>
            @endforeach
            <p class="mt-2 text-xs text-gray-500 dark:text-gray-400">
                Excluded from every figure above.
            </p>
        </x-filament::section>
    @endif
</x-filament-panels::page>
