# Changelog

All notable changes to `flutter_laravel_bridge` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## 2.2.0 - 2026-11-10

Laravel Fortify over the bridge (Bridge 2.2, see `docs/FORTIFY.md`). Pairs with
`atannex/laravel-flutter-bridge` 2.2.0; wire protocol unchanged (`2.0.0`). Fully backwards
compatible with 2.1.0: against an older server the new calls simply answer 404.

### Added

- **Feature discovery**: `FortifyFeatures` parsed from `features.fortify` of the handshake (or
  `GET config` via `AuthManager.refreshFortifyFeatures()`), exposed as `ServerFeatures.fortify`,
  `ServerInfo.fortify`, `LaravelConnectionManager.fortify`, `AuthManager.fortify` and
  `Laravel.fortify`. Without the block every Fortify flag is `false` and nothing is blocked.
  `fortifyListenable` (`ValueListenable<FortifyFeatures>`) on `AuthManager` and
  `LaravelConnectionManager` (survives profile switches) notifies when the features change;
  `FortifyFeatures` has value equality. `LaravelClient.serverInfoListenable` notifies on every new
  handshake.
- **Password reset with emailed codes**: `forgotPassword(email)` → `PasswordResetRequest`
  (`channel`, `expiresIn`), `verifyPasswordResetCode(email:, code:)` → reset token,
  `resetPassword(email:, password:, passwordConfirmation:, resetToken: | token:)`.
- **Email verification**: `sendEmailVerification()` → `VerificationCodeRequest` (`sent`,
  `expiresIn`), `verifyEmail(code)` (updates `currentUser`, the offline user cache and the auth
  state), and `emailVerificationRequired` — the server's `email_verification_required` after
  `register` / `updateProfile`, cleared by `verifyEmail` and sign-out.
- **Account**: `updateProfile(fields)` (publishes the updated user), `updatePassword(...,
  revokeOtherSessions:)`.
- **Password confirmation**: `confirmPassword(password)` / `confirmedPasswordStatus()` →
  `PasswordConfirmation` (`confirmed`, `expiresIn`, `confirmedAt`, `isConfirmed()`),
  `isPasswordConfirmed`, and `runWithPasswordConfirmation(action, askPassword)` which catches a 423,
  asks for the password, confirms and retries once; `runWithPasswordPrompt(action, prompt)` hands the
  prompt a `confirm(password)` function so the UI keeps its sheet open on a wrong password and shows
  the error inline (`PasswordConfirmer` / `PasswordConfirmationPrompt` typedefs).
- **`auth.twoFactor`** (`TwoFactorManager`): `enable()` → `TwoFactorStatus`, `qrCode()` →
  `TwoFactorQrCode` (`svg`, `url`), `secretKey()`, `confirm(code)` (refreshes the user),
  `recoveryCodes()`, `regenerateRecoveryCodes()`, `disable()`.
- **`auth.passkeys`** (`PasskeyManager`): `list()` → `List<Passkey>`, `rename(id, name)`,
  `delete(id)`.
- **Feature gating**: a call to a feature the server published as off throws
  `LaravelFeatureDisabledException` locally, without a request (`register` included).
- **Typed exceptions**: `LaravelPasswordConfirmationRequiredException` (423),
  `LaravelCodeException` with `kind` `invalid` / `expired` / `locked` (`code_invalid`,
  `code_expired`, `code_locked`, `reset_token_invalid`; a `LaravelValidationError`),
  `LaravelFeatureDisabledException` (404 `feature_disabled`, a `LaravelNotFoundException`),
  `LaravelAlreadyVerifiedException` (409). New `LaravelErrorCode` constants for every Fortify code.
- `LaravelClient.patch`, `AuthManager.reloadUser()` and `AuthManager.applyUserPayload()`.
- `BridgeEndpoints` keys for every Fortify endpoint.

### Notes

- A 429 without a `Retry-After` header gives `LaravelRateLimitException.retryAfter == null`.

### Unchanged

- Every existing exception mapping, including 403 `feature_disabled` (a bridge feature switched
  off) → `LaravelPermissionException`, and `AuthState` (verification is a property of the user).

## 2.1.0 - 2026-11-10

Pairs with `atannex/laravel-flutter-bridge` 2.1.0 (authenticator-app two-step sign-in). Fully
backwards compatible with 2.0.0.

### Added

- **Two-step sign-in**: `AuthManager.login` accepts `code`, `recoveryCode` (sent as `code` /
  `recovery_code`) and an `extra` map merged into the request like `register`.
  `loginWithSocial` accepts `code` / `recoveryCode`.
- `LaravelTwoFactorRequiredException` (extends `LaravelValidationError`) with `invalid`, thrown for
  422 `two_factor_required` / `two_factor_invalid`. During a challenge `AuthManager` emits
  `Unauthenticated` (not `AuthError`), stores no tokens and rethrows so the UI can ask for the code.
- `LaravelErrorCode.twoFactorRequired`, `LaravelErrorCode.twoFactorInvalid` and
  `LaravelErrorCode.isTwoFactorChallenge`.
- **Plain JSON endpoints**: `ApiResponse.fromJson` treats a map without the envelope as `data`;
  `LaravelClient.get/post/put/delete` accept top-level JSON arrays. New `ApiResponse.isEnvelope`,
  `ApiResponse.raw`, `ApiResponse.fromBody`.
- `LaravelClient.getJson` returns a raw JSON object and honours cache policies like `get`.
- **Signed in while offline**: the signed-in user is remembered per connection profile (in the
  `storage:` / new `userStore:` store), so an app that starts without a connection restores the
  session instead of showing the user signed out. The cached user is cleared with the session.
  `AuthManager.attachUserCache` for standalone use.

### Changed

- Responses with a `success` or `data` key (the bridge envelope, Laravel API resources) are parsed
  exactly as before; empty bodies still have no data.

## 2.0.0 - 2026-11-09

Bridge protocol v2: connection management between Flutter and Laravel. Requires
`atannex/laravel-flutter-bridge` 2.0.0 on the server.

### Added

- **Connection profiles**: `LaravelConnection` (const-constructible, also generated by
  `php artisan flutter:export-config`) plus `ConnectionStore`, `InMemoryConnectionStore` and
  `DelegateConnectionStore`. Users can add, test, edit, switch and delete backends; each profile
  keeps its own tokens, offline queue and cache.
- **`LaravelConnectionManager`**: handshake, session connect, heartbeats, automatic reconnect with
  exponential backoff, latency, remote sessions (`sessions`, `revokeSession`,
  `revokeOtherSessions`), and server commands on the `commands` stream (de-duplicated across
  heartbeat and broadcast).
- `ServerInfo` from the handshake, with endpoint resolution and `BroadcastingConfig.toEchoOptions()`
  so Echo configures itself.
- `ConnectionStatus` and `LaravelConnectionState`, including `revoked` and `upgradeRequired`.
- Widgets: `LaravelConnectionManagerView`, `LaravelConnectionEditor`, `LaravelSessionsView`,
  `LaravelConnectionBuilder`, `LaravelConnectionBanner`, `LaravelConnectionStatusChip`.
- `Laravel.initialize` options: `storage`, `connectionStore`, `tokenStorageFactory`, `autoConnect`,
  `autoConfigureEcho`, `onSessionRevoked`, `onUpgradeRequired`, `onCommand`. New statics
  `Laravel.connections`, `Laravel.server`, `Laravel.switchConnection`, `Laravel.changes`,
  `Laravel.isInitialized`, `Laravel.reset`.
- **Persistent storage**: `BridgeKeyValueStore` (`InMemoryKeyValueStore`, `DelegateKeyValueStore`)
  backs tokens, profiles, offline queue and cache from one app-provided store (e.g.
  `flutter_secure_storage`). A debug warning is printed when tokens are memory-only.
- **Persistent offline queue**: survives restarts; FIFO replay; requests the server rejects (4xx) are
  dropped; server errors are retried up to `maxRetries`; being offline never consumes retries;
  `failures` stream.
- **Persistent cache**: expiry stored, LRU eviction (`maxEntries`), `invalidatePrefix`.
- Typed exceptions with `errorCode`: `LaravelUpgradeRequiredException`,
  `LaravelConnectionRevokedException`, `LaravelConnectionNotFoundException`,
  `LaravelAppKeyException`, `LaravelRateLimitException` (`retryAfter`),
  `LaravelMaintenanceException`.
- `LaravelOptions.appKey`, `prefix`, `deviceName`, `osVersion`; headers `X-Flutter-App-Key`,
  `X-Flutter-Connection-Id`, `X-Flutter-Bridge-Version`.

### Changed

- Minimum SDK: Dart 3.6 / Flutter 3.27.
- `LaravelConnectionIndicator` accepts either `echo` or `manager`.
- `AuthManager` saves refresh tokens on register and 2FA, honours `expires_in` with proactive refresh,
  and exposes `onSessionExpired`.

### Fixed

- Token refresh could dead-lock the client when the refresh failed.
- Base URLs without a trailing slash produced malformed request URLs.
- `queueIfOffline` and the `networkFirst` cache fallback never triggered.
- Starting the app offline logged the user out.
- Private and presence channels never subscribed (authorization payload read from the wrong place).
- `LaravelEcho.disconnect()` and `LaravelSseClient.disconnect()` immediately reconnected.
- Presence member removal now matches on `user_id`.
- A revoked device briefly still reported itself as authenticated.

### Upgrade notes

- Existing `Laravel.initialize(...)` calls keep working unchanged.
- Users sign in once more after the server upgrade (1.x refresh tokens were never stored).
- Pass `storage:` to keep sessions across app restarts.
- If you `implements TokenStorage`, nothing changes; scoping is opt-in through `ScopedTokenStorage`.

## 1.0.0

- Initial release: Dio client with standardized envelope parsing, Sanctum auth lifecycle with
  refresh, Reverb/Pusher Echo client (public, private, presence, whispers), SSE fallback, device
  registration, offline mutation queue, cache policies, query builder, pagination, uploads, and
  auth/realtime/pagination widgets.
