# Authentication & Token Lifecycle

This document describes the enterprise authentication architecture implemented by the Laravel & Flutter Bridge.

---

## 1. Authentication Strategy

Traditional web applications rely on stateful HTTP-only session cookies and CSRF tokens. Mobile applications require stateless Bearer token authorization due to native network stack characteristics, background push workers, and cross-origin environments.

The bridge combines:
1. **Short-Lived Access Tokens**: Personal access tokens with a configurable TTL (e.g. 60 minutes) to minimize exposure windows.
2. **Long-Lived Refresh Tokens**: Secure cryptographically generated refresh tokens (e.g. 30 days) stored exclusively in the mobile OS keychain.
3. **Physical Device Binding**: Each token is associated with a specific device identifier (`device_id`).

---

## 2. Token Storage Adapter

The package decouples storage so you can easily plug in encrypted storage:

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';

final secureStorage = const FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
);

final tokenStorage = DelegateTokenStorage(
  onWrite: (key, val) => secureStorage.write(key: key, value: val),
  onRead: (key) => secureStorage.read(key: key),
  onDelete: (key) => secureStorage.delete(key: key),
);

// Pass to Laravel.initialize:
await Laravel.initialize<User>(
  options: options,
  tokenStorage: tokenStorage,
  userParser: (json) => User.fromJson(json),
);
```

---

## 3. Handling 401 Unauthorized Automatically

When an access token expires:
1. `AuthInterceptor` intercepts the 401 response from Laravel.
2. It locks further outgoing requests in a queue to prevent token stampedes.
3. It performs a refresh request against `/api/flutter/auth/refresh`.
4. Once a new token is returned, it saves it to `TokenStorage`.
5. It replays the original failed request and all queued requests with the new Bearer token.
6. The caller receives the expected 200 response without knowing a refresh occurred.
7. If the refresh token itself has expired or been revoked, `onSessionExpired` is invoked to redirect the user to login.

---

## 4. Biometric Authentication Pattern

For enterprise security, you can store the refresh token behind a local biometric gate:

```dart
import 'package:local_auth/local_auth.dart';

final auth = LocalAuthentication();

Future<bool> authenticateWithBiometrics() async {
  final canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
  if (!canAuthenticateWithBiometrics) return false;

  return await auth.authenticate(
    localizedReason: 'Scan fingerprint or FaceID to authenticate',
    options: const AuthenticationOptions(stickyAuth: true),
  );
}
```
