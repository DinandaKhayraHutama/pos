<?php

declare(strict_types=1);

namespace App\Filament\Backoffice\Resources\DeviceResource\Pages;

use App\Filament\Backoffice\Resources\DeviceResource;
use Filament\Resources\Pages\ManageRecords;

class ManageDevices extends ManageRecords
{
    protected static string $resource = DeviceResource::class;
}
