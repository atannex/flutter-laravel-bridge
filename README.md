# Flutter Laravel Bridge (Client Package)

[![Pub Version](https://img.shields.io/pub/v/flutter_laravel_bridge?style=flat-square)](https://pub.dev/packages/flutter_laravel_bridge)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An enterprise-grade Flutter client package providing reactive authentication, native Laravel Reverb / Pusher WebSockets, unified API response envelopes, auto-refresh token interception, FCM push notification registration, offline mutation queueing, and infinite-scroll pagination.

---

## 🌟 Key Features

- **Standardized API Client**: Pre-configured `Dio` client mapping Laravel HTTP status codes (422, 401, 403, 404, 500) into typed exceptions.
- **Sanctum Device Auth**: Built-in `AuthManager` with automatic `401 Unauthorized` token refreshing, secure token storage, and session event streams.
- **Real-Time Laravel Echo (Reverb & Pusher)**: Native WebSocket client supporting public, private, and presence channels with Bearer token authentication.
- **FCM Device Registration**: Automatically registers mobile device hardware details and FCM tokens with Laravel backend.
- **Offline Mutation Queue**: Queues POST/PUT/DELETE requests during network dropouts and automatically replays them when back online.
- **Connection Management (Bridge v2)**: Multiple backend profiles with per-profile tokens, handshake-driven endpoint discovery, live sessions with heartbeats, remote sign-out, server commands, version policy (426) and ready-made Material 3 screens.
- **Laravel Fortify over the bridge**: password reset and email verification with 6-digit codes, profile and password updates, password confirmation, authenticator-app setup, recovery codes and passkey management, all through Fortify's own actions and feature switches.
- **Pagination & UI Widgets**: Ready-to-use `LaravelPaginatedListView` with pull-to-refresh and infinite scrolling, plus reactive `LaravelAuthBuilder` and `LaravelRealtimeBuilder`.

---

## 📦 Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_laravel_bridge:
    path: ../flutter-laravel-bridge # or pub version
```

---

## 🚀 Quick Setup

### 1. Initialization
Initialize the bridge in your `main()` before running `runApp()`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Laravel.initialize<User>(
    options: const LaravelOptions(
      baseUrl: 'https://api.yourdomain.com',
      platform: 'android', // or 'ios', 'web'
      appVersion: '1.0.0',
      deviceId: 'custom-unique-uuid',
    ),
    echoOptions: const EchoOptions(
      appKey: 'your-reverb-or-pusher-key',
      wsHost: 'ws.yourdomain.com',
      wsPort: 8080,
      encrypted: true,
    ),
    userParser: (json) => User.fromJson(json),
  );

  runApp(const MyApp());
}
```

> Without `storage:` / `tokenStorage:` tokens live in memory and **users are logged out on every
> restart** (a one-time warning is printed in debug builds). See below.

### 2. Persistent & secure storage

The package does not depend on any storage plugin. Give it one async key-value store and it is
used for **tokens** (namespaced per connection profile), **connection profiles** (plus the active
profile and generated device id), each profile's **offline queue** and **response cache**:

```dart
// pubspec.yaml (your app): flutter_secure_storage: ^11.2.0
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const secure = FlutterSecureStorage();

await Laravel.initialize<User>(
  options: const LaravelOptions(baseUrl: 'https://api.yourdomain.com'),
  userParser: User.fromJson,
  storage: DelegateKeyValueStore(
    read: (key) => secure.read(key: key),
    write: (key, value) => secure.write(key: key, value: value),
    delete: (key) => secure.delete(key: key),
  ),
);
```

Keep secrets in secure storage and put bulky, non-secret data (offline queue, cache) in
`shared_preferences` — the more specific parameters override `storage` for their part:

```dart
// pubspec.yaml (your app): shared_preferences: ^2.3.0
final prefs = SharedPreferencesAsync();
final plain = DelegateKeyValueStore(
  read: prefs.getString,
  write: prefs.setString,
  delete: prefs.remove,
);

await Laravel.initialize<User>(
  options: options,
  userParser: User.fromJson,
  storage: secureStore,        // tokens + connection profiles
  offlineQueueStore: plain,    // flutter_laravel_offline_queue:<profileId>
  cacheStore: plain,           // flutter_laravel_cache:<profileId>
);
```

---

## 🔌 Connection management

Bridge v2 (wire protocol `2.0.0`, see `docs/CONNECTIONS.md`) separates two things:

| Concept | Where | What |
| :--- | :--- | :--- |
| **Connection profile** (`LaravelConnection`) | device only | A saved backend (name, base URL, app key, prefix) the user can add, test, edit, switch and delete. |
| **Connection session** (`ConnectionSession`) | Laravel DB | The live link of this install, kept alive by heartbeats, listed and revocable by the user and admins. |

### Setup

```dart
await Laravel.initialize<User>(
  options: const LaravelOptions(
    baseUrl: 'https://api.acme.com',
    appKey: 'fba_…',            // php artisan flutter:app:create
    prefix: 'api/flutter',      // flutter-bridge.prefix
    appVersion: '1.4.2',
    platform: 'android',
  ),
  userParser: User.fromJson,
  // Persist profiles + active profile (+ generated device id).
  connectionStore: DelegateConnectionStore(
    onRead: prefs.read, onWrite: prefs.write, onDelete: prefs.delete,
  ),
  // Root token storage; every profile except `default` gets a namespaced view
  // (`flutter_laravel_access_token:<profileId>`).
  tokenStorage: DelegateTokenStorage(
    onRead: secure.read, onWrite: secure.write, onDelete: secure.delete,
  ),
  autoConnect: true,          // handshake → connect → heartbeats
  autoConfigureEcho: true,    // build & connect Echo from the handshake `broadcasting` block
  onSessionRevoked: (reason) => router.go('/login'),
  onUpgradeRequired: (e) => launchUrl(Uri.parse(e.updateUrl!)),
  onCommand: (command) => print('Server says ${command.type}: ${command.payload}'),
);
```

Without a `connectionStore`, a `default` profile is seeded from `LaravelOptions`
(`baseUrl`, `appKey`, `prefix`), so existing apps keep working unchanged.

### Profiles & switching

```dart
final manager = Laravel.connections;               // LaravelConnectionManager

final probe = await manager.test(LaravelConnection.create(
  name: 'Staging', baseUrl: 'https://staging.acme.com', appKey: 'fba_…',
));
print(probe.ok ? '${probe.latency!.inMilliseconds} ms' : probe.errorMessage);

await manager.add(staging, makeActive: true);      // connects
await Laravel.switchConnection('default');         // rebuilds client/auth/echo, restores that profile's login

Laravel.changes.listen((_) => rebuildEverything()); // fired when client/auth/echo were rebuilt
print(Laravel.server?.app?.latestVersion);          // handshake info (ServerInfo)
```

`LaravelConnection` has a `const` constructor (the `flutter:export-config` artisan
command generates code calling it), plus `LaravelConnection.create`, `toJson`/`fromJson`,
`copyWith` and value equality.

### State, sessions & commands

```dart
manager.stateStream.listen((state) {
  // idle · connecting · connected · reconnecting · offline · failed · revoked · upgradeRequired
  print('${state.status} ${state.latency} attempt=${state.reconnectAttempt}');
});

final devices = await manager.sessions();          // sessions of the logged-in user
await manager.revokeSession(devices.last.id);       // sign out one device
final count = await manager.revokeOtherSessions(); // "sign out all other devices"

manager.commands.listen((command) { /* message, custom types… (de-duplicated by id) */ });
```

### Ready-made widgets

```dart
MaterialApp(
  // Animated banner for offline / reconnecting / revoked / update required.
  builder: (context, child) => LaravelConnectionBanner(
    onUpdate: (e) => launchUrl(Uri.parse(e.updateUrl!)),
    child: child!,
  ),
  routes: {
    '/connections': (_) => const LaravelConnectionManagerView(), // add / test / edit / switch / delete
    '/sessions': (_) => const LaravelSessionsView(),             // signed-in devices, revoke
  },
);

LaravelConnectionBuilder(builder: (context, state) => Text(state.status.name));
LaravelConnectionIndicator(manager: Laravel.connections);
```

All widgets accept an optional `manager` and default to `Laravel.connections`.
---

## 🔐 Authentication

### Log In
```dart
try {
  final user = await Laravel.auth<User>().login(
    email: 'user@example.com',
    password: 'password123',
    deviceName: 'iPhone 15 Pro',
  );
  print('Welcome back, ${user.name}');
} on LaravelValidationError catch (e) {
  print('Email error: ${e.first('email')}');
} on LaravelAuthenticationException catch (e) {
  print('Invalid credentials: ${e.message}');
}
```

### Reactive Auth UI
```dart
class RootView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LaravelAuthBuilder<User>(
      authManager: Laravel.auth<User>(),
      authenticated: (context, user) => DashboardScreen(user: user),
      unauthenticated: (context) => LoginScreen(),
      loading: (context) => const SplashScreen(),
    );
  }
}
```

### Two-step sign-in (authenticator apps)

Requires `atannex/laravel-flutter-bridge` 2.1.0. When an account has an authenticator app turned on,
the first `login` call throws `LaravelTwoFactorRequiredException` (a `LaravelValidationError`, so
existing handlers still catch it). The auth state goes back to `Unauthenticated` (not `AuthError`)
and no tokens are stored. Ask for the code and call `login` again with `code:` (or
`recoveryCode:`). A wrong code throws the same exception with `invalid == true`.

```dart
Future<void> signIn(BuildContext context, String email, String password) async {
  final auth = Laravel.auth<User>();
  String? code;
  while (true) {
    try {
      await auth.login(email: email, password: password, code: code);
      return; // Authenticated
    } on LaravelTwoFactorRequiredException catch (e) {
      // e.invalid: the previous code was wrong. e.first('code') has the server message.
      code = await askForCode(context, error: e.invalid ? e.message : null);
      if (code == null) return; // user cancelled
    }
  }
}
```

`login` also takes `recoveryCode:` (sent as `recovery_code`) and an `extra` map of additional
fields, like `register`. `loginWithSocial` accepts `code:` / `recoveryCode:` too. The `user` object
in the login/register response is whatever your app returns; it is passed to your `userParser`.

### Laravel Fortify

Requires `atannex/laravel-flutter-bridge` 2.2.0 (with or without `laravel/fortify` installed; when it
is, Fortify's own actions, rules, events and `config/fortify.php` features are used). Protocol:
[`docs/FORTIFY.md`](https://github.com/atannex/flutter-laravel-bridge/blob/main/docs/FORTIFY.md).

**Discovery.** The handshake says which features are on, so the app only shows what works. Calling a
feature the server switched off throws `LaravelFeatureDisabledException` without sending anything.

```dart
final auth = Laravel.auth<User>();
final fortify = auth.fortify; // also Laravel.fortify / Laravel.connections.fortify
if (fortify.resetPasswords) showForgotPasswordLink();
if (fortify.twoFactorAuthentication) showSecuritySettings();

// Rebuild when the handshake arrives or the user switches servers:
ValueListenableBuilder<FortifyFeatures>(
  valueListenable: Laravel.connections.fortifyListenable, // or auth.fortifyListenable
  builder: (context, fortify, _) => fortify.passkeys ? passkeysTile : const SizedBox(),
);
```

**Forgot password** — the app asks for the code emailed by the server (links in the same email keep
opening the website):

```dart
final request = await auth.forgotPassword(email); // always "sent", no account enumeration
try {
  final resetToken = await auth.verifyPasswordResetCode(email: email, code: code);
  await auth.resetPassword(
    email: email,
    password: newPassword,
    passwordConfirmation: newPassword,
    resetToken: resetToken, // or token: <broker token from the email link>
  );
} on LaravelCodeException catch (e) {
  // e.kind: invalid (try again), expired or locked (e.needsNewCode → forgotPassword again)
}
```

**Email verification, profile and password** (signed in):

```dart
await auth.register(name: name, email: email, password: password);
if (auth.emailVerificationRequired) openCodeScreen(); // the server already emailed a code
final sent = await auth.sendEmailVerification(); // LaravelAlreadyVerifiedException when done already
showExpiry(sent.expiresIn ?? auth.fortify.codes.ttl);
final user = await auth.verifyEmail(code);    // currentUser, cached user and stateStream updated
await auth.updateProfile({'name': name, 'email': email});
if (auth.emailVerificationRequired) openCodeScreen(); // new address: a code was emailed
await auth.updatePassword(
  currentPassword: current,
  password: next,
  passwordConfirmation: next,
  revokeOtherSessions: true,
);
```

**Password confirmation.** Two-factor and passkey management need a recent password confirmation
(Fortify's `confirmPassword` option). Wrap the action; on a 423 the bridge asks, confirms and retries
once:

```dart
final status = await auth.runWithPasswordConfirmation(
  () => auth.twoFactor.enable(),
  () => askForPassword(context), // returns null when the user cancels
);
// Keep the sheet open on a wrong password: the prompt confirms by itself.
await auth.runWithPasswordPrompt(
  () => auth.twoFactor.enable(),
  (confirm) => showPasswordSheet(context, onSubmit: confirm),
  // onSubmit: try { if (await confirm(text)) Navigator.pop(context, true); }
  //           on LaravelValidationError catch (e) { showInline(e.message); }
);
// Or by hand: await auth.confirmPassword(password); auth.isPasswordConfirmed;
//             (await auth.confirmedPasswordStatus()).expiresIn
```

**Authenticator app and recovery codes:**

```dart
if (status.needsConfirmation) {
  final qr = await auth.twoFactor.qrCode();   // qr.svg (flutter_svg), qr.url (otpauth://)
  final secret = await auth.twoFactor.secretKey();
  await auth.twoFactor.confirm(codeFromApp);  // refreshes the user (two_factor_enabled)
}
final codes = await auth.twoFactor.recoveryCodes();
await auth.twoFactor.regenerateRecoveryCodes();
await auth.twoFactor.disable();
```

**Passkeys** are created and used on the website (they need platform credential APIs and a verified
domain); the app lists, renames and removes them:

```dart
final passkeys = await auth.passkeys.list();
await auth.passkeys.rename(passkeys.first.id, 'Work laptop');
await auth.runWithPasswordConfirmation(
    () => auth.passkeys.delete(passkeys.first.id), () => askForPassword(context));
```

| Exception | When |
|---|---|
| `LaravelCodeException` (`kind`: invalid / expired / locked) | wrong, old or locked emailed code; used reset token |
| `LaravelPasswordConfirmationRequiredException` | 423: confirm the password first |
| `LaravelFeatureDisabledException` | feature off on the server (404 `feature_disabled`, or locally) |
| `LaravelAlreadyVerifiedException` | 409: email already verified |
| `LaravelRateLimitException` | 429; `retryAfter` is `null` when the server sends no `Retry-After` |

The user payload gains `email_verified`, `email_verified_at`, `two_factor_enabled`,
`two_factor_pending_confirmation` and `passkeys_count`; read them in your `userParser`.

---

## 📡 Real-Time Broadcasting (Reverb / Pusher)

```dart
// Connect to WebSockets
await Laravel.echo.connect();

// Listen to a public channel
Laravel.echo
    .channel('orders')
    .listen('OrderCreated', (data) {
      print('New order received: $data');
    });

// Listen to a private channel (authenticated via Bearer token)
Laravel.echo
    .private('users.${user.id}')
    .listen('NotificationReceived', (data) {
      print('User alert: $data');
    });

// Join a presence channel
Laravel.echo
    .join('chat.room.1')
    .here((members) => print('Active members: $members'))
    .joining((member) => print('Joined: $member'))
    .leaving((member) => print('Left: $member'));
```

---

## 🧾 Plain JSON endpoints

Not every Laravel endpoint returns the bridge envelope (`success`, `message`, `data`, `meta`).
`get`, `post`, `put` and `delete` also accept plain JSON: a JSON object without the envelope keys,
or a top-level JSON array, becomes `response.data` (with `success == true` and an empty `message`).
A body counts as wrapped when it has `success` or `data` (the bridge envelope, or a Laravel API resource), so `data` is the inner value exactly as in 2.0.0.

```dart
final todos = await Laravel.client.get<List<dynamic>>('api/todos'); // returns [...]
print(todos.data?.length);

// Raw JSON object, returned exactly as the server sent it. Cache policies work like get().
final stats = await Laravel.client.getJson(
  'api/stats',
  queryParameters: {'range': '7d'},
  cachePolicy: CachePolicy.cacheFirst,
  cacheTtl: const Duration(minutes: 1),
);
print(stats['visits']);
```

`getJson` throws a `LaravelException` when the body is not a JSON object.

---

## 📜 Paginated Infinite Scroll

```dart
LaravelPaginatedListView<Post>(
  fetchPage: (page) => Laravel.client.paginate<Post>(
    '/api/posts',
    page: page,
    itemParser: (json) => Post.fromJson(json),
  ),
  itemBuilder: (context, post, index) => ListTile(
    title: Text(post.title),
    subtitle: Text(post.body),
  ),
  emptyBuilder: (context) => const Center(child: Text('No posts yet!')),
);
```
