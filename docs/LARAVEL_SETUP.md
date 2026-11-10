# Laravel Backend Setup Guide

This guide details how to install and configure the `atannex/laravel-flutter-bridge` package in your Laravel application.

---

## 1. Prerequisites

- PHP 8.2 or higher
- Laravel 12.x or 13.x (PHP 8.3+ for Laravel 13)
- Composer 2.x
- Laravel Sanctum (`composer require laravel/sanctum`)
- (Optional, recommended for real-time) Laravel Reverb (`composer require laravel/reverb`)

---

## 2. Installation

Install the package into your Laravel application:

```bash
composer require atannex/laravel-flutter-bridge
```

Publish configuration and database migrations:

```bash
php artisan flutter:install
```

Run database migrations to create the `flutter_devices` table:

```bash
php artisan migrate
```

Verify your environment configuration:

```bash
php artisan flutter:status
```

---

## 3. Configuring the User Model

Add the bridge traits to your `App\Models\User` model:

```php
<?php

namespace App\Models;

use Atannex\LaravelFlutterBridge\Traits\HasFlutterDevices;
use Atannex\LaravelFlutterBridge\Traits\HasFlutterTokens;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Laravel\Sanctum\HasApiTokens;

class User extends Authenticatable
{
    use HasApiTokens, HasFlutterTokens, HasFlutterDevices;

    protected $fillable = [
        'name',
        'email',
        'password',
    ];

    protected $hidden = [
        'password',
        'remember_token',
    ];
}
```

---

## 4. Configuring Real-Time Broadcasting (Reverb)

Ensure your `.env` contains Reverb broadcasting credentials:

```ini
BROADCAST_CONNECTION=reverb

REVERB_APP_ID=my_reverb_app
REVERB_APP_KEY=my_reverb_key
REVERB_APP_SECRET=my_reverb_secret
REVERB_HOST="0.0.0.0"
REVERB_PORT=8080
REVERB_SCHEME=http

VITE_REVERB_APP_KEY="${REVERB_APP_KEY}"
VITE_REVERB_HOST="${REVERB_HOST}"
VITE_REVERB_PORT="${REVERB_PORT}"
VITE_REVERB_SCHEME="${REVERB_SCHEME}"
```

In `routes/channels.php`, define your channel authorization callbacks:

```php
use App\Models\User;
use Illuminate\Support\Facades\Broadcast;

// Private user notification channel
Broadcast::channel('users.{id}', function (User $user, int $id) {
    return (int) $user->id === (int) $id;
});

// Presence chat room channel
Broadcast::channel('chat.room.{roomId}', function (User $user, int $roomId) {
    return [
        'id' => $user->id,
        'name' => $user->name,
        'email' => $user->email,
    ];
});
```

The bridge automatically provides `/api/flutter/broadcasting/auth` which resolves Sanctum Bearer tokens and executes these channel policies for Flutter clients.

---

## 5. Controller Usage & Response Macros

You can return standardized Flutter responses using response macros:

```php
<?php

namespace App\Http\Controllers\Api;

use App\Http\Controllers\Controller;
use App\Models\Order;
use Illuminate\Http\Request;

class OrderController extends Controller
{
    public function index(Request $request)
    {
        $orders = Order::where('user_id', $request->user()->id)
            ->latest()
            ->paginate(15);

        // Standardized paginated response
        return response()->flutterPaginated($orders, 'Orders fetched successfully');
    }

    public function show(Order $order)
    {
        // Standardized single resource response
        return response()->flutterSuccess($order);
    }

    public function cancel(Order $order)
    {
        $order->update(['status' => 'cancelled']);
        return response()->flutterSuccess($order, 'Order cancelled');
    }
}
```
