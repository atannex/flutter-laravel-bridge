# Push Notifications & Device Management

This document explains how the Laravel backend and Flutter frontend coordinate mobile device registration and Firebase Cloud Messaging (FCM) tokens.

---

## 1. The Multi-Device Challenge

In enterprise applications, a single user often accesses the system across multiple devices (e.g. an iPhone, an Android tablet, and a web browser). When sending a notification, the backend needs to reach all active devices belonging to the user while pruning stale or uninstalled tokens.

---

## 2. Flutter Device Registration

In Flutter, retrieve the FCM token via `firebase_messaging` and synchronize it with Laravel:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';

Future<void> syncPushToken() async {
  final messaging = FirebaseMessaging.instance;
  final settings = await messaging.requestPermission(alert: true, badge: true, sound: true);

  if (settings.authorizationStatus == AuthorizationStatus.authorized) {
    final token = await messaging.getToken();

    if (token != null) {
      await Laravel.devices.registerDevice(
        deviceId: 'unique-hardware-uuid',
        platform: 'ios', // or 'android'
        fcmToken: token,
        deviceName: 'iPhone 15 Pro',
        osVersion: 'iOS 17.5',
        appVersion: '1.0.0',
      );
    }
  }

  // Listen to token refresh
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
    await Laravel.devices.registerDevice(
      deviceId: 'unique-hardware-uuid',
      platform: 'ios',
      fcmToken: newToken,
    );
  });
}
```

---

## 3. Sending Notifications in Laravel

### Firebase credentials

Download a service-account key (Firebase console → **Project settings → Service accounts → Generate new
private key**) and point the bridge at it:

```ini
FCM_CREDENTIALS=/path/to/service-account.json
# FCM_PROJECT_ID=...   optional, defaults to the credentials' project_id
```

`FCM_CREDENTIALS` may also hold the raw JSON or base64-encoded JSON. The bridge mints and caches the OAuth2
access tokens itself (no Google SDK needed); `php artisan flutter:status` validates the setup offline.

### Using the `flutter_push` channel

Return `['flutter_push']` from a notification's `via()` and build a `FlutterPushMessage` in
`toFlutterPush()` (see [NOTIFICATIONS_CHANNEL.md](NOTIFICATIONS_CHANNEL.md)). The channel sends to every
token returned by `HasFlutterDevices::getActiveFcmTokens()` (or `routeNotificationForFlutterPush()`),
concurrently via FCM HTTP v1:

```php
$user->notify(new OrderShippedNotification($order->id, 'TRK-987654'));
```

### Stale token pruning

When FCM reports a token as `UNREGISTERED` (or 404 / an invalid registration token), the channel sets
`fcm_token = null` on the matching `flutter_devices` rows and fires
`FlutterPushTokenInvalidated($token, $deviceRowId)`, so uninstalled apps stop being targeted. A
`FlutterPushSent` event with `sent` / `failed` / `invalidated` counts is fired after each delivery.

---

## 4. Device Unregistration on Logout

When the user logs out or disables notifications:

```dart
await Laravel.devices.unregisterDevice('unique-hardware-uuid');
await Laravel.auth<User>().logout();
```
