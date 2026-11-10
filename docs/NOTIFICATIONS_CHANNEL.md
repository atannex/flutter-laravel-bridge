# Laravel Native Notification Channel for Flutter

The Laravel backend package registers a first-class notification driver named `flutter_push`. This enables you to send push notifications to Flutter mobile devices using Laravel's native Notification class system (`$user->notify(...)`).

---

## 1. Creating a Push Notification

Generate or create a standard Laravel Notification class:

```bash
php artisan make:notification OrderShippedNotification
```

Configure `via()` to return `['flutter_push']` and define `toFlutterPush()`:

```php
<?php

namespace App\Notifications;

use Atannex\LaravelFlutterBridge\Notifications\Messages\FlutterPushMessage;
use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Notifications\Notification;

class OrderShippedNotification extends Notification implements ShouldQueue
{
    use Queueable;

    public function __construct(
        public int $orderId,
        public string $trackingCode
    ) {}

    /**
     * Specify the notification delivery channels.
     */
    public function via(mixed $notifiable): array
    {
        return ['flutter_push', 'database'];
    }

    /**
     * Build the push message for Flutter mobile devices.
     */
    public function toFlutterPush(mixed $notifiable): FlutterPushMessage
    {
        return (new FlutterPushMessage())
            ->title('📦 Order Dispatched!')
            ->body("Your order #{$this->orderId} is on its way.")
            ->channelId('orders_channel')
            ->sound('default')
            ->badge(1)
            ->clickAction('OPEN_ORDER_DETAILS')
            ->data([
                'order_id' => $this->orderId,
                'tracking_code' => $this->trackingCode,
                'screen' => '/orders/details',
            ]);
    }
}
```

---

## 2. Dispatching Notifications

Dispatch notifications anywhere in your controllers, jobs, or event listeners:

```php
use App\Models\User;
use App\Notifications\OrderShippedNotification;

// Send to a single user (dispatches to all active devices registered by that user)
$user = User::find(1);
$user->notify(new OrderShippedNotification($order->id, 'TRK-987654'));

// Or send to a collection of users in bulk:
Notification::send($premiumUsers, new FlashSaleNotification());
```

---

## 3. Configuration (Firebase service account)

1. In the Firebase console open **Project settings → Service accounts → Generate new private key** and
   download the JSON file. Keep it out of version control.
2. Point the bridge at it in `.env`:

```ini
FCM_CREDENTIALS=/path/to/service-account.json
# Optional: defaults to "project_id" from the credentials
FCM_PROJECT_ID=your-firebase-project-id
```

`FCM_CREDENTIALS` also accepts the raw JSON string or base64-encoded JSON (handy for secret managers and
container platforms). The channel signs an RS256 JWT with the service account's private key, exchanges it at
`https://oauth2.googleapis.com/token` for an OAuth2 access token (scope
`https://www.googleapis.com/auth/firebase.messaging`) and caches it in the Laravel cache until a minute
before it expires. If FCM answers 401, the cached token is dropped and the request retried once.

| Key (`flutter-bridge.notifications.*`) | Env | Default | Purpose |
| :--- | :--- | :--- | :--- |
| `fcm_credentials` | `FCM_CREDENTIALS` | `null` | Service-account JSON: file path, raw JSON or base64 JSON. |
| `fcm_project_id` | `FCM_PROJECT_ID` | `null` | Firebase project; falls back to the credentials' `project_id`. |
| `fcm_bearer_token` | `FCM_BEARER_TOKEN` | `null` | Static access token used only without credentials (testing; expires after an hour). |
| `fcm_concurrency` | `FCM_CONCURRENCY` | `10` | Concurrent FCM requests per batch (`Http::pool`). |
| `fcm_timeout` | `FCM_TIMEOUT` | `10` | Request timeout in seconds. |

Run `php artisan flutter:status` to check the configuration: it validates the credentials and private key
locally (no network call) and shows the project and service-account email.

Without credentials or a bearer token the `FlutterPushChannel` logs the intended payload instead of sending
it, allowing frictionless local development.

---

## 4. Message fields

`FlutterPushMessage::toArray()` produces an FCM v1 `message`:

| Builder | FCM field |
| :--- | :--- |
| `title()`, `body()`, `image()` | `notification.title/body/image` |
| `data([...])` | `data` (values stringified; non-strings JSON-encoded) |
| `clickAction()` | `data.click_action` |
| `channelId()` | `android.notification.channel_id` |
| `sound()` (default `"default"`) | `android.notification.sound` and `apns.payload.aps.sound` |
| `badge()` | `apns.payload.aps.badge` |

---

## 5. Delivery results & dead tokens

- Tokens FCM reports as dead (`UNREGISTERED`, HTTP 404, or `INVALID_ARGUMENT` about the registration
  token) get `fcm_token = null` on their `flutter_devices` rows, and
  `FlutterPushTokenInvalidated(string $token, ?int $deviceRowId)` is fired.
- Other per-token failures are logged as warnings with the FCM error code; `send()` never throws for them.
  Unusable credentials are logged as an error.
- After each delivery `FlutterPushSent($notifiable, $notification, $sent, $failed, $invalidated,
  $invalidatedTokens)` is fired; the same `['sent' => …, 'failed' => …, 'invalidated' => …]` summary is
  returned by the channel (available as `$event->response` on Laravel's `NotificationSent`).
