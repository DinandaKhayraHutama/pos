<?php

declare(strict_types=1);

namespace App\Domain\Sync;

use App\Domain\Orders\OrderStatus;
use App\Models\Device;
use App\Models\Order;
use App\Models\OrderItem;
use App\Models\OrderItemModifier;
use App\Models\Tenant;
use App\Support\TenantContext;
use DateTimeInterface;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;

/**
 * Accepts sales pushed up by a till. The most consequential code in the system.
 *
 * Three guarantees, and each one is a different way money goes missing:
 *
 * **Never twice.** The device's UUID is the key. A push that timed out after
 * the server committed gets retried, and the retry must update the same sale
 * rather than record a second one. Idempotency here is not an optimisation —
 * without it, a flaky connection inflates a merchant's takings.
 *
 * **Never partly.** An order, its lines and their modifiers arrive as one
 * nested payload and are written in one transaction. A sale whose header landed
 * without its lines is a total nobody can explain, and it would pass every
 * check that only looks at `orders`.
 *
 * **Never rolled back.** Once a sale is settled — voided or refunded — a late
 * packet describing the earlier state must not undo it. The device holds the
 * same rule in `_settle`, which no-ops when the order already returned its
 * stock; a double-tap on Void must not credit the shelf twice, and a stale push
 * must not un-void a sale a manager already signed off.
 */
class OrderIngest
{
    public function __construct(private readonly TenantContext $context) {}

    /**
     * @param  array<int, array<string, mixed>>  $rows
     * @return array{accepted: list<string>, rejected: list<array{id: string, reason: string}>}
     */
    public function ingest(Device $device, array $rows): array
    {
        $accepted = [];
        $rejected = [];

        foreach ($rows as $row) {
            try {
                $accepted[] = $this->ingestOne($device, $row);
            } catch (ValidationException $e) {
                // One malformed sale must not fail the batch — the rest is
                // money already taken from customers. The device drops a
                // rejected row rather than retrying bytes that will always be
                // refused.
                $rejected[] = [
                    'id' => (string) ($row['id'] ?? ''),
                    'reason' => implode(' ', $e->validator->errors()->all()),
                ];
            }
        }

        return ['accepted' => $accepted, 'rejected' => $rejected];
    }

    private function ingestOne(Device $device, array $row): string
    {
        return DB::transaction(function () use ($device, $row): string {
            $tenant = Tenant::query()
                ->whereKey($this->context->requireId())
                ->lockForUpdate()
                ->firstOrFail();
            $this->context->set($tenant);

            $data = $this->validate($row);
            $existing = Order::query()->find($data['id']);

            if ($existing !== null) {
                return $this->applyUpdate($existing, $data);
            }

            return $this->create($device, $tenant, $data);
        }, 3);
    }

    /**
     * A sale that is already here.
     *
     * Only the fields a device can legitimately change after the fact are
     * touched: the status and its audit trail. The money and the lines are
     * NOT rewritten — a retry sends the same figures, and a later push must
     * never be able to restate what a customer paid.
     */
    private function applyUpdate(Order $order, array $data): string
    {
        $incoming = OrderStatus::from($data['status']);

        // Settle-once. A void that arrives twice, or a stale packet describing
        // the sale before it was voided, both land here and both must change
        // nothing — the second would un-void a sale a manager signed off.
        if ($order->isSettled()) {
            return $order->id;
        }

        $order->forceFill([
            'status' => $incoming,
            'authorized_by' => $data['authorized_by'] ?? $order->authorized_by,
            'void_reason' => $data['void_reason'] ?? $order->void_reason,
            'refunded_amount' => $data['refunded_amount'] ?? $order->refunded_amount,
        ])->save();

        return $order->id;
    }

    private function create(Device $device, Tenant $tenant, array $data): string
    {
        $order = new Order;
        $order->forceFill([
            'id' => $data['id'],
            'tenant_id' => $tenant->id,
            'outlet_id' => $device->outlet_id,
            'pos_register_id' => $device->pos_register_id,
            'device_id' => $device->id,
            'pos_session_id' => $data['pos_session_id'] ?? null,

            'number' => $data['number'],
            'placed_at' => $this->fromEpochMillis($data['placed_at']),
            'type' => $data['type'],
            'status' => OrderStatus::from($data['status']),

            'table_id' => $data['table_id'] ?? null,
            'table_name' => $data['table_name'] ?? null,
            'customer_name' => $data['customer_name'] ?? null,
            'note' => $data['note'] ?? null,

            'subtotal' => $data['subtotal'],
            'discount' => $data['discount'] ?? 0,
            'tax' => $data['tax'] ?? 0,
            'service_charge_amount' => $data['service_charge_amount'] ?? 0,
            'total' => $data['total'],
            'amount_paid' => $data['amount_paid'] ?? 0,
            'pb1_rate' => $data['pb1_rate'] ?? null,
            'service_charge_rate' => $data['service_charge_rate'] ?? null,

            'payment_method' => $data['payment_method'],
            'promo_name' => $data['promo_name'] ?? null,

            'cashier_id' => $data['cashier_id'] ?? null,
            'cashier_name' => $data['cashier_name'],
            'outlet_name' => $data['outlet_name'] ?? null,
            'pos_name' => $data['pos_name'] ?? null,

            'authorized_by' => $data['authorized_by'] ?? null,
            'void_reason' => $data['void_reason'] ?? null,
            'refunded_amount' => $data['refunded_amount'] ?? null,
        ]);
        $order->save();

        foreach ($data['items'] as $itemRow) {
            $item = new OrderItem;
            $item->forceFill([
                'id' => $itemRow['id'],
                'tenant_id' => $tenant->id,
                'order_id' => $order->id,
                'product_id' => $itemRow['product_id'] ?? null,
                'product_name' => $itemRow['product_name'],
                'variant_name' => $itemRow['variant_name'] ?? null,
                'unit_price' => $itemRow['unit_price'],
                'unit_cost' => $itemRow['unit_cost'] ?? null,
                'quantity' => $itemRow['quantity'],
                'note' => $itemRow['note'] ?? null,
                'category_id' => $itemRow['category_id'] ?? null,
                'category_name' => $itemRow['category_name'] ?? null,
            ]);
            $item->save();

            foreach ($itemRow['modifiers'] ?? [] as $index => $modifierRow) {
                $modifier = new OrderItemModifier;
                $modifier->forceFill([
                    'id' => $modifierRow['id'],
                    'tenant_id' => $tenant->id,
                    'order_item_id' => $item->id,
                    'group_name' => $modifierRow['group_name'],
                    'option_name' => $modifierRow['option_name'],
                    'price_delta' => $modifierRow['price_delta'] ?? 0,
                    'sort_order' => $modifierRow['sort_order'] ?? $index,
                ]);
                $modifier->save();
            }
        }

        return $order->id;
    }

    /**
     * @return array<string, mixed>
     */
    private function validate(array $row): array
    {
        return Validator::make($row, [
            'id' => ['required', 'uuid'],
            'number' => ['required', 'string', 'max:64'],
            'placed_at' => ['required', 'integer', 'min:0'],
            'type' => ['required', 'string', 'max:32'],
            'status' => ['required', Rule::enum(OrderStatus::class)],
            'pos_session_id' => ['nullable', 'uuid'],

            'table_id' => ['nullable', 'uuid'],
            'table_name' => ['nullable', 'string', 'max:255'],
            'customer_name' => ['nullable', 'string', 'max:255'],
            'note' => ['nullable', 'string', 'max:2000'],

            // Money is integer rupiah. A float here would be a rounding error
            // that compounds silently across a month of sales.
            'subtotal' => ['required', 'integer'],
            'discount' => ['nullable', 'integer'],
            'tax' => ['nullable', 'integer'],
            'service_charge_amount' => ['nullable', 'integer'],
            'total' => ['required', 'integer'],
            'amount_paid' => ['nullable', 'integer'],
            'pb1_rate' => ['nullable', 'numeric'],
            'service_charge_rate' => ['nullable', 'numeric'],

            'payment_method' => ['required', 'string', 'max:32'],
            'promo_name' => ['nullable', 'string', 'max:255'],

            'cashier_id' => ['nullable', 'uuid'],
            'cashier_name' => ['required', 'string', 'max:255'],
            'outlet_name' => ['nullable', 'string', 'max:255'],
            'pos_name' => ['nullable', 'string', 'max:255'],

            'authorized_by' => ['nullable', 'string', 'max:255'],
            'void_reason' => ['nullable', 'string', 'max:2000'],
            'refunded_amount' => ['nullable', 'integer'],

            // A sale with no lines is a total nobody can explain. Required, so
            // a payload that lost its items in transit is refused rather than
            // stored as a mystery.
            'items' => ['required', 'array', 'min:1'],
            'items.*.id' => ['required', 'uuid'],
            'items.*.product_id' => ['nullable', 'uuid'],
            'items.*.product_name' => ['required', 'string', 'max:255'],
            'items.*.variant_name' => ['nullable', 'string', 'max:255'],
            'items.*.unit_price' => ['required', 'integer'],
            'items.*.unit_cost' => ['nullable', 'integer'],
            'items.*.quantity' => ['required', 'integer', 'min:1'],
            'items.*.note' => ['nullable', 'string', 'max:2000'],
            'items.*.category_id' => ['nullable', 'uuid'],
            'items.*.category_name' => ['nullable', 'string', 'max:255'],

            'items.*.modifiers' => ['nullable', 'array'],
            'items.*.modifiers.*.id' => ['required', 'uuid'],
            'items.*.modifiers.*.group_name' => ['required', 'string', 'max:255'],
            'items.*.modifiers.*.option_name' => ['required', 'string', 'max:255'],
            'items.*.modifiers.*.price_delta' => ['nullable', 'integer'],
            'items.*.modifiers.*.sort_order' => ['nullable', 'integer', 'min:0'],

            // Identity is the token's, never the payload's.
            'tenant_id' => ['prohibited'],
            'outlet_id' => ['prohibited'],
            'pos_register_id' => ['prohibited'],
        ])->validate();
    }

    private function fromEpochMillis(int $millis): DateTimeInterface
    {
        return Carbon::createFromTimestampMs($millis);
    }
}
