<?php

declare(strict_types=1);

namespace App\Http\Controllers;

use App\Domain\Devices\DeviceActivation;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class DeviceController extends Controller
{
    public function activate(Request $request, DeviceActivation $activation): JsonResponse
    {
        $input = $request->validate([
            'code' => ['required', 'string', 'regex:/^[A-Z2-9]{12}$/'],
            'device_uuid' => ['required', 'uuid'],
            'label' => ['nullable', 'string', 'max:100'],
            'platform' => ['nullable', 'string', 'in:android,ios,macos,windows,linux,web'],
            'tenant_id' => ['prohibited'],
            'outlet_id' => ['prohibited'],
            'pos_register_id' => ['prohibited'],
        ]);

        return response()->json($activation->activate($input), 201)
            ->header('Cache-Control', 'no-store, private');
    }

    public function show(Request $request): JsonResponse
    {
        $device = $request->user();

        return response()->json([
            'device' => $device->only(['id', 'device_uuid', 'label', 'platform']),
            'tenant' => $device->tenant->only(['id', 'name']),
            'outlet' => $device->outlet->only(['id', 'name', 'address', 'phone']),
            'pos_register' => $device->posRegister->only(['id', 'outlet_id', 'name', 'table_service']),
        ])->header('Cache-Control', 'no-store, private');
    }
}
