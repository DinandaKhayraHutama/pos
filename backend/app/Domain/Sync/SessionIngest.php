<?php

declare(strict_types=1);

namespace App\Domain\Sync;

use App\Models\Device;
use App\Models\PosSession;
use App\Models\Tenant;
use App\Support\TenantContext;
use DateTimeInterface;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Illuminate\Validation\ValidationException;

/**
 * Accepts cash sessions pushed up by a till.
 *
 * The first ingest point in the system, and the shape the order ingest follows.
 *
 * **Idempotent by the device's own id.** The till generates a UUID before it
 * writes the row locally, so a push that timed out after the server committed
 * can be retried safely: the second attempt updates the same row instead of
 * opening a second drawer. That property is the whole reason the device
 * generates keys rather than asking the server for one.
 *
 * **A closed session never reopens.** The device is the authority on a drawer
 * while it is open, but once a count has been signed off, a late-arriving push
 * of the earlier open state must not erase it — that would delete a variance
 * somebody has already explained.
 */
class SessionIngest
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
                // One bad row must not fail the batch: the others are money
                // already taken, and holding them hostage to a neighbour's
                // problem is the wrong risk. A rejected row is dropped from the
                // device's queue rather than retried forever, because the same
                // bytes will always get the same answer.
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
            // Serialises this merchant's pushes, so two tablets sending
            // sessions for one register cannot both pass the open-drawer check
            // before either commits.
            $tenant = Tenant::query()
                ->whereKey($this->context->requireId())
                ->lockForUpdate()
                ->firstOrFail();
            $this->context->set($tenant);

            $data = Validator::make($row, [
                'id' => ['required', 'uuid'],
                'employee_id' => ['nullable', 'uuid'],
                'employee_name' => ['required', 'string', 'max:255'],
                'pos_name' => ['nullable', 'string', 'max:255'],
                'outlet_name' => ['nullable', 'string', 'max:255'],
                'opened_at' => ['required', 'integer', 'min:0'],
                'opening_cash' => ['required', 'integer'],
                'closed_at' => ['nullable', 'integer', 'min:0'],
                'counted_cash' => ['nullable', 'integer'],
                'expected_cash' => ['nullable', 'integer'],
                'closed_by_id' => ['nullable', 'uuid'],
                'closed_by_name' => ['nullable', 'string', 'max:255'],
                'note' => ['nullable', 'string', 'max:2000'],

                // A till may not name its own outlet or register: those come
                // from the token, exactly as everywhere else. A device that
                // could choose would be a device that could write into another
                // branch's books.
                'tenant_id' => ['prohibited'],
                'outlet_id' => ['prohibited'],
                'pos_register_id' => ['prohibited'],
            ])->validate();

            $existing = PosSession::query()->find($data['id']);

            if ($existing !== null && ! $existing->isOpen() && ($data['closed_at'] ?? null) === null) {
                throw ValidationException::withMessages([
                    'closed_at' => 'This session is already closed; a reopen was ignored.',
                ]);
            }

            $this->assertRegisterFree($device, $data);

            $session = $existing ?? new PosSession;
            $session->forceFill([
                'id' => $data['id'],
                'tenant_id' => $tenant->id,
                'outlet_id' => $device->outlet_id,
                'pos_register_id' => $device->pos_register_id,
                'device_id' => $device->id,
                'employee_id' => $data['employee_id'] ?? null,
                'employee_name' => $data['employee_name'],
                'pos_name' => $data['pos_name'] ?? null,
                'outlet_name' => $data['outlet_name'] ?? null,
                'opened_at' => $this->fromEpochMillis($data['opened_at']),
                'opening_cash' => $data['opening_cash'],
                'closed_at' => $this->fromEpochMillis($data['closed_at'] ?? null),
                'counted_cash' => $data['counted_cash'] ?? null,
                'expected_cash' => $data['expected_cash'] ?? null,
                'closed_by_id' => $data['closed_by_id'] ?? null,
                'closed_by_name' => $data['closed_by_name'] ?? null,
                'note' => $data['note'] ?? null,
            ]);
            $session->save();

            return $session->id;
        }, 3);
    }

    /**
     * Refuse a second open drawer on one register.
     *
     * The database enforces this as well, with a partial unique index — but
     * reaching it surfaces as an opaque constraint violation. Checking here
     * produces a message naming who holds the till, which is what the cashier
     * standing in front of it actually needs. It is the same information
     * `RegisterBusyException` carries on the device.
     */
    private function assertRegisterFree(Device $device, array $data): void
    {
        if (($data['closed_at'] ?? null) !== null) {
            return;
        }

        $holder = PosSession::query()
            ->open()
            ->where('pos_register_id', $device->pos_register_id)
            ->whereKeyNot($data['id'])
            ->first();

        if ($holder !== null) {
            throw ValidationException::withMessages([
                'pos_register_id' => sprintf(
                    'This register already has an open session held by %s.',
                    $holder->employee_name,
                ),
            ]);
        }
    }

    /**
     * The device's clock, kept as the till recorded it.
     *
     * Not trusted for ordering — that is what the server's own `created_at` is
     * for — but it is the only record of when the drawer was really opened, and
     * a reconciliation needs both.
     */
    private function fromEpochMillis(?int $millis): ?DateTimeInterface
    {
        return $millis === null ? null : Carbon::createFromTimestampMs($millis);
    }
}
