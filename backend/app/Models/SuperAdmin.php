<?php

declare(strict_types=1);

namespace App\Models;

use Database\Factories\SuperAdminFactory;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;

/**
 * Platform staff. Creates merchants; never belongs to one.
 *
 * Deliberately outside tenant scope and on a separate guard from
 * {@see Employee}: the two answer different questions ("who runs the
 * platform" vs "who works at this shop"), and collapsing them into one
 * table would mean a merchant's row and a platform operator's row differing
 * only by a nullable column — one missed check away from a privilege
 * escalation.
 *
 * @property int $id
 * @property string $name
 * @property string $email
 */
class SuperAdmin extends Authenticatable
{
    /** @use HasFactory<SuperAdminFactory> */
    use HasFactory;

    use Notifiable;

    protected $table = 'super_admins';

    protected $fillable = ['name', 'email', 'password'];

    protected $hidden = ['password', 'remember_token'];

    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'password' => 'hashed',
        ];
    }
}
