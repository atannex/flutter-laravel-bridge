# Flutter Laravel Bridge

[![Pub Version](https://img.shields.io/pub/v/flutter_laravel_bridge?style=flat-square)](https://pub.dev/packages/flutter_laravel_bridge)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Flutter package for connecting apps to Laravel backends through
[`atannex/laravel-flutter-bridge`](https://github.com/atannex/laravel-flutter-bridge).

It provides a ready-to-use API client, Sanctum authentication, connection management,
realtime events, offline support, push notifications, and useful Flutter widgets.

## Features

- **API requests:** Dio client with typed Laravel exceptions and validation handling.
- **Authentication:** Sanctum login, registration, refresh-token rotation, and automatic 401 recovery.
- **Account security:** Fortify password reset, email verification, two-factor authentication, and passkey management.
- **Connections:** Multiple backend profiles, device sessions, heartbeats, and remote sign-out.
- **Realtime:** Laravel Reverb/Pusher support for public, private, and presence channels.
- **Offline support:** Cached GET requests and queued mutations that sync when online.
- **Push notifications:** Firebase Cloud Messaging device registration.
- **Widgets:** Authentication, pagination, realtime, presence, and connection UI components.

## Requirements

- Flutter and Dart versions compatible with the package release.
- A Laravel backend using `atannex/laravel-flutter-bridge`.
- PHP 8.2+ and Laravel 12 or 13.
- Laravel Sanctum.
- Laravel Reverb for realtime features (optional).
- Laravel Fortify for Fortify-backed account features (optional).

## 1. Set up Laravel

Install and configure the backend package:

```bash
composer require laravel/sanctum
composer require atannex/laravel-flutter-bridge

php artisan flutter:install
php artisan migrate
php artisan flutter:status
```

Add the bridge traits to your `User` model:

```php
use Atannex\LaravelFlutterBridge\Traits\HasFlutterDevices;
use Atannex\LaravelFlutterBridge\Traits\HasFlutterTokens;
use Laravel\Sanctum\HasApiTokens;

class User extends Authenticatable
{
    use HasApiTokens, HasFlutterTokens, HasFlutterDevices;
}
```

Register your Flutter application and generate its configuration:

```bash
php artisan flutter:app:create
php artisan flutter:export-config
```

Keep the generated app key private. Do not commit production secrets to your repository.

## 2. Install the Flutter package

Add the dependency to `pubspec.yaml`:

```yaml
dependencies:
  flutter_laravel_bridge: ^2.2.0
```

Then run:

```bash
flutter pub get
```

## 3. Initialize the client

Initialize the package before `runApp()`. Replace the URL and app key with your Laravel details.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Laravel.initialize<User>(
    options: const LaravelOptions(
      baseUrl: 'https://api.example.com',
      appKey: 'YOUR_APP_KEY',
      platform: 'android',
      appVersion: '1.0.0',
    ),
    userParser: User.fromJson,
    storage: secureStore,
    onSessionExpired: () => router.go('/login'),
  );

  runApp(const MyApp());
}
```

`User.fromJson` should convert the user object returned by your Laravel API into your app's user model.

Pass a persistent storage adapter to keep tokens and connection information between app launches. Without storage, tokens remain in memory and users will be signed out when the app restarts. Use secure storage for authentication tokens.

## 4. Make API requests

```dart
final response = await Laravel.client.get<Map<String, dynamic>>(
  '/api/dashboard',
);

final result = await Laravel.client.post<Map<String, dynamic>>(
  '/api/orders',
  data: {
    'item_id': 102,
    'quantity': 2,
  },
);

print(result.data);
```

Handle validation errors with the package's typed exceptions:

```dart
try {
  await Laravel.client.post('/api/orders', data: orderData);
} on LaravelValidationError catch (error) {
  print(error.first('item_id'));
} on LaravelAuthenticationException catch (error) {
  print(error.message);
} on LaravelNetworkException {
  print('Check your internet connection.');
}
```

## 5. Authentication

```dart
final auth = Laravel.auth<User>();

final user = await auth.login(
  email: 'user@example.com',
  password: 'password123',
  deviceName: 'My phone',
);

// Sign out
await auth.logout();
```

The client handles access-token refresh and retries eligible requests after a 401 response. Authentication state is also available through `auth.stateStream` and `auth.currentUser`.

## 6. Realtime events

When Reverb or Pusher is configured on the Laravel backend, listen for events through Echo:

```dart
Laravel.echo
    .private('users.${user.id}')
    .listen('OrderUpdated', (data) {
  print(data);
});
```

The package also supports public and presence channels, whispers, and realtime widgets.

## More capabilities

The package also includes:

- Paginated requests and `LaravelPaginatedListView`.
- Query building with `LaravelQuery`.
- GET caching and an offline mutation queue.
- File uploads through `Laravel.uploader`.
- FCM device registration through `Laravel.devices`.
- Multiple backend profiles and session management through `Laravel.connections`.
- Model, route, and connection configuration generation from Laravel Artisan commands.
- Riverpod and Bloc integration examples.

## Troubleshooting

- **Android emulator cannot reach localhost:** use `http://10.0.2.2:8000`.
- **Users are signed out after restarting:** configure persistent `storage` or `tokenStorage`.
- **401 errors after login:** ensure the Laravel `User` model uses `HasApiTokens` and protected routes use `auth:sanctum`.
- **Realtime connection fails:** check that Reverb is running and its host, port, and scheme are configured correctly.

## Links

- [Laravel backend package](https://github.com/atannex/laravel-flutter-bridge)
- [Package on pub.dev](https://pub.dev/packages/flutter_laravel_bridge)
