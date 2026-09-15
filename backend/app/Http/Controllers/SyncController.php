<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Domain\Sync\CataloguePuller;
use App\Domain\Sync\OrderIngest;
use App\Domain\Sync\SessionIngest;
use App\Domain\Sync\SyncRegistry;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

class SyncController extends Controller
{
    /**
     * `GET /api/v1/sync/pull?entity=products&after_seq=412`
     *
     * One entity per call, deliberately. The device has to apply categories
     * before products anyway (its SQLite enforces the foreign key), so it is
     * already sequencing these requests — a batched response would just move
     * that ordering somewhere it is harder to see.
     *
     * The tenant is never a parameter. It comes from the device token, via the
     * `device` middleware, via the global scope on every model.
     */
    public function pull(Request $request, CataloguePuller $puller): JsonResponse
    {
        $input = $request->validate([
            'entity' => ['required', 'string', Rule::in(SyncRegistry::names())],
            'after_seq' => ['nullable', 'integer', 'min:0'],
            'limit' => ['nullable', 'integer', 'min:1', 'max:'.CataloguePuller::MAX_LIMIT],
            'tenant_id' => ['prohibited'],
        ]);

        $result = $puller->pull(
            $input['entity'],
            (int) ($input['after_seq'] ?? 0),
            (int) ($input['limit'] ?? CataloguePuller::DEFAULT_LIMIT),
        );

        return response()->json([
            'entity' => $input['entity'],
            ...$result,
        ])->header('Cache-Control', 'no-store, private');
    }

    /**
     * `POST /api/v1/sync/push` — rows a till authored, arriving from the till.
     *
     * The response names which ids were accepted and which were refused,
     * because the device has to know exactly what it may drop from its queue.
     * A blanket 200 would leave it guessing, and guessing about money means
     * either sending a sale twice or losing it.
     *
     * Rejections are 200-with-detail, not a failed request: one malformed row
     * must not fail the whole batch, and the rest of the batch is money already
     * taken from customers.
     */
    public function push(
        Request $request,
        SessionIngest $sessions,
        OrderIngest $orders,
    ): JsonResponse {
        $input = $request->validate([
            'entity' => ['required', 'string', Rule::in(self::PUSHABLE)],
            'rows' => ['required', 'array', 'min:1', 'max:200'],
            'rows.*' => ['required', 'array'],
            'tenant_id' => ['prohibited'],
        ]);

        // `$request->user()` is the Device, resolved by the `device` middleware
        // from the bearer token — which is also where the outlet and register
        // come from. Nothing in the payload may name them.
        $device = $request->user();

        $result = match ($input['entity']) {
            'pos_sessions' => $sessions->ingest($device, $input['rows']),
            'orders' => $orders->ingest($device, $input['rows']),
        };

        return response()->json([
            'entity' => $input['entity'],
            ...$result,
        ])->header('Cache-Control', 'no-store, private');
    }

    /**
     * Entities a till may push.
     *
     * An allow-list for the same reason the pull side has one: the name arrives
     * from a client, and matching it to a handler by convention is how a device
     * token ends up able to write into a table nobody meant to expose.
     */
    private const PUSHABLE = ['pos_sessions', 'orders'];

    /**
     * The order a device must pull in, published rather than hardcoded on the
     * client.
     *
     * Adding an entity server-side then becomes a server-only change: a till
     * that has not been updated keeps pulling the entities it knows, and starts
     * pulling the new one as soon as it learns about it.
     */
    public function manifest(): JsonResponse
    {
        return response()->json([
            'entities' => SyncRegistry::names(),
            'max_limit' => CataloguePuller::MAX_LIMIT,
        ])->header('Cache-Control', 'no-store, private');
    }
}
