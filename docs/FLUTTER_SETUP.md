# Flutter Client Setup Guide

This guide details how to integrate `flutter_laravel_bridge` into your Flutter mobile or web application.

---

## 1. Installation

Add the package dependency to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_laravel_bridge:
    path: ../flutter-laravel-bridge # or pub version
```

Run pub get:

```bash
flutter pub get
```

---

## 2. Initialization in `main.dart`

Initialize the bridge inside your `main()` method before calling `runApp()`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'models/user.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Laravel.initialize<User>(
    options: const LaravelOptions(
      baseUrl: 'https://api.yourdomain.com',
      platform: 'android', // or 'ios', 'web'
      appVersion: '1.0.0',
      deviceId: 'unique-device-uuid',
      enableLogging: true,
    ),
    echoOptions: const EchoOptions(
      appKey: 'reverb_app_key',
      wsHost: 'ws.yourdomain.com',
      wsPort: 8080,
      encrypted: true,
    ),
    userParser: (json) => User.fromJson(json),
    onSessionExpired: () {
      debugPrint('User session has expired. Redirecting to login...');
    },
  );

  runApp(const MyApp());
}
```

---

## 3. State Management Integration

### Riverpod Integration
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'models/user.dart';

// StreamProvider for reactive AuthState
final authStateProvider = StreamProvider<AuthState>((ref) {
  return Laravel.auth<User>().stateStream;
});

// Current User Provider
final currentUserProvider = Provider<User?>((ref) {
  final authState = ref.watch(authStateProvider).value;
  if (authState is Authenticated<User>) {
    return authState.user;
  }
  return null;
});
```

### Flutter BLoC Integration
```dart
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';

class AuthCubit extends Cubit<AuthState> {
  AuthCubit() : super(Laravel.auth<User>().currentState) {
    Laravel.auth<User>().stateStream.listen(emit);
  }

  Future<void> login(String email, String password) async {
    await Laravel.auth<User>().login(email: email, password: password);
  }

  Future<void> logout() async {
    await Laravel.auth<User>().logout();
  }
}
```

---

## 4. Making API Requests

```dart
// Standard GET Request
final response = await Laravel.client.get<Map<String, dynamic>>('/api/dashboard');
print(response.data);

// Standard POST Request
try {
  final result = await Laravel.client.post<Map<String, dynamic>>(
    '/api/orders',
    data: {'item_id': 102, 'quantity': 2},
  );
  print('Order created with ID: ${result.data?['id']}');
} on LaravelValidationError catch (e) {
  print('Validation errors: ${e.allMessages}');
} on LaravelAuthenticationException catch (e) {
  print('Authentication required: ${e.message}');
}
```
