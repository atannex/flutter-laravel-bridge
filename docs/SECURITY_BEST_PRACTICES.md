# Enterprise Security & Hardening

Security is paramount in enterprise mobile architectures. This checklist details security configurations implemented and recommended for the Laravel & Flutter Bridge.

---

## 1. SSL / TLS Certificate Pinning

To protect against Man-In-The-Middle (MITM) attacks on compromised networks or corporate proxies, configure Certificate Pinning on Dio in Flutter:

```dart
import 'dart:io';
import 'package:dio/io.dart';

void setupSecurity(LaravelClient client) {
  (client.rawDio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
    final client = HttpClient();
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
      // Validate cert.sha256 matches your enterprise certificate fingerprint
      const expectedFingerprint = 'YOUR_SHA256_CERT_FINGERPRINT_HEX';
      final actualFingerprint = cert.sha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      return actualFingerprint.toUpperCase() == expectedFingerprint.toUpperCase();
    };
    return client;
  };
}
```

---

## 2. Token Security & Storage

- **Android**: Use Android Keystore via EncryptedSharedPreferences (`FlutterSecureStorage`).
- **iOS**: Store in Apple Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so tokens cannot be transferred via iCloud backups.
- **Never store tokens in plain SharedPreferences or LocalStorage**.

The default `InMemoryTokenStorage` keeps tokens only for the lifetime of the process: users are
logged out on every restart, and debug/profile builds print a one-time warning. Plug in secure
storage without adding a dependency to the bridge itself:

```dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const secure = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
);

await Laravel.initialize<User>(
  options: options,
  userParser: User.fromJson,
  // Tokens (namespaced per connection profile), profiles, offline queue and cache.
  storage: DelegateKeyValueStore(
    read: (key) => secure.read(key: key),
    write: (key, value) => secure.write(key: key, value: value),
    delete: (key) => secure.delete(key: key),
  ),
);

// Or tokens only:
// tokenStorage: DelegateTokenStorage.fromKeyValue(
//   read: (key) => secure.read(key: key),
//   write: (key, value) => secure.write(key: key, value: value),
//   delete: (key) => secure.delete(key: key),
// ),
```

- Token keys: `flutter_laravel_access_token` / `flutter_laravel_refresh_token` for the default
  profile and `…:<profileId>` for every other profile; removing a profile deletes its tokens.
- The offline queue persists request **bodies**. If they may contain personal data, keep
  `offlineQueueStore` on secure storage too; only route it (and `cacheStore`) to
  `shared_preferences` when payloads and cached responses are non-sensitive.
- Call `Laravel.auth().logout()` on sign-out; consider `cacheManager.clear()` and
  `offlineQueue.clear()` when a different user may sign in on the same device.

---

## 3. Backend Rate Limiting

In Laravel, apply strict rate limiting to auth routes (`app/Providers/RouteServiceProvider.php` or `bootstrap/app.php`):

```php
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Http\Request;

RateLimiter::for('flutter-auth', function (Request $request) {
    return Limit::perMinute(5)->by($request->ip());
});
```

---

## 4. Production Logging Security

Disable HTTP body logging in production builds so sensitive credentials, passwords, and tokens are never printed to system logs:

```dart
LaravelOptions(
  baseUrl: 'https://api.domain.com',
  enableLogging: !kReleaseMode, // Automatically disabled in production release builds
);
```
