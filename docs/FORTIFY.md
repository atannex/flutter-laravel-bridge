# Laravel Fortify over the bridge (Bridge 2.2)

Everything a Fortify web app can do with its session (sign up, sign in,
two-step challenge, forgot / reset password, email verification, profile and
password updates, password confirmation, authenticator-app management,
recovery codes, passkey management) available to the Flutter app with bearer
tokens, **through Fortify's own actions, rules, events and settings**.

Wire protocol stays `2.0.0`; every endpoint below is additive. Envelope and
`meta.error_code` exactly as in CONNECTIONS.md §3.

## 1. Principles

1. **Fortify is the source of truth.** When `laravel/fortify` is installed the
   bridge resolves Fortify's bound contracts and callbacks instead of its own:
   * sign in: `Fortify::$authenticateUsingCallback` (else the bridge's
     `auth.authenticate_using`, else email + hash check); `fortify.username`,
     `fortify.lowercase_usernames`;
   * sign up: `Laravel\Fortify\Contracts\CreatesNewUsers` (fires `Registered`);
   * reset: `ResetsUserPasswords` (fires `PasswordReset`), the `fortify.passwords` broker;
   * profile: `UpdatesUserProfileInformation`; password: `UpdatesUserPasswords`;
   * two-factor: `TwoFactorAuthenticationProvider`, `EnableTwoFactorAuthentication`,
     `ConfirmTwoFactorAuthentication`, `DisableTwoFactorAuthentication`,
     `GenerateNewRecoveryCodes` (and their events), `Features::optionEnabled(...)`
     for `confirm` and `confirmPassword`;
   * verification: `MustVerifyEmail`, `Verified` event.
2. **Features mirror the server.** An endpoint for a Fortify feature that is
   disabled in `config/fortify.php` answers 404 `feature_disabled`. The handshake
   and `GET config` publish `features.fortify` (§3) so the app only shows what works.
3. **Codes, not links, on phones.** Reset and verification links in emails
   open the website; the app instead asks for a **6-digit code** emailed by
   the bridge (config `fortify.codes`). Codes: random_int, stored hashed in the
   cache, 10 min TTL, max 5 attempts then `code_locked`, single use, rate limited.
   The web flows (links) keep working unchanged.
4. **Sensitive actions need a recent password confirmation** when Fortify's
   `confirmPassword` option is on (two-factor enable/disable/recovery codes,
   passkey removal): `POST auth/user/confirm-password` marks the current
   token as confirmed for `auth.password_timeout` seconds (default 10800);
   otherwise 423 `password_confirmation_required`.
5. Every new route: rate limited (named limiters, keyed by token/user or
   email+IP), JSON envelope, localized messages (`__()`), no user enumeration
   (forgot-password and resend always answer 200 with the same message).

## 2. Endpoints (prefix `api/flutter`, `X-Flutter-App-Key` as usual)

### Guest

| Method & path | Body | Success `data` | Errors |
|---|---|---|---|
| `POST auth/login` (existing) | `email` (or the Fortify username), `password`, `device_name`, `code?`, `recovery_code?` | user + authorization | 422 `invalid_credentials`, `two_factor_required` (`data.two_factor=true`), `two_factor_invalid`; 429 |
| `POST auth/register` (existing, now via `CreatesNewUsers`) | the app's fields (`name`/`first_name`…, `email`, `password`, `password_confirmation`, `terms`, extras) | user + authorization; `data.email_verification_required` | 422 validation |
| `POST auth/forgot-password` | `email` | `{sent: true, channel: "code"\|"link", expires_in}` | 429 |
| `POST auth/reset-password/verify-code` | `email`, `code` | `{reset_token, expires_in}` (short-lived, one use) | 422 `code_invalid`, `code_expired`, 423 `code_locked` |
| `POST auth/reset-password` | `email`, `password`, `password_confirmation`, and `reset_token` **or** `token` (Fortify broker token from the email link) | `{reset: true}`; all the user's bridge tokens/connections revoked | 422 validation / `reset_token_invalid` |

### Authenticated (`Authorization: Bearer …`)

| Method & path | Body | Success `data` | Errors |
|---|---|---|---|
| `GET auth/me` (existing) | | user (now with the fields in §4) | |
| `POST auth/email/verification-notification` | | `{sent: true, expires_in}` (emails a code) | 409 `already_verified`, 429 |
| `POST auth/email/verify` | `code` | user | 422 `code_invalid`/`code_expired`, 423 `code_locked` |
| `PUT auth/user/profile-information` | fields of `UpdatesUserProfileInformation` | user (`email_verification_required` when the email changed and `MustVerifyEmail`) | 422 |
| `PUT auth/user/password` | `current_password`, `password`, `password_confirmation`, `revoke_other_sessions?` | `{updated: true}` | 422 |
| `POST auth/user/confirm-password` | `password` | `{confirmed: true, expires_in}` | 422 `password_invalid` |
| `GET auth/user/confirmed-password-status` | | `{confirmed: bool, expires_in}` | |
| `POST auth/user/two-factor-authentication` | | `{enabled: true, confirmed: false, requires_confirmation}` | 423 `password_confirmation_required` |
| `GET auth/user/two-factor-qr-code` | | `{svg, url}` (`otpauth://…`) | 404 `two_factor_not_enabled` |
| `GET auth/user/two-factor-secret-key` | | `{secret_key}` | 404 |
| `POST auth/user/confirmed-two-factor-authentication` | `code` | `{confirmed: true}` + user | 422 `two_factor_invalid` |
| `GET auth/user/two-factor-recovery-codes` | | `{recovery_codes: [...]}` | 423, 404 |
| `POST auth/user/two-factor-recovery-codes` | | `{recovery_codes: [...]}` (new set) | 423 |
| `DELETE auth/user/two-factor-authentication` | | `{enabled: false}` | 423 |
| `GET auth/user/passkeys` | | `[{id, name, created_at, last_used_at}]` | 404 `feature_disabled` |
| `PATCH auth/user/passkeys/{id}` | `name` | passkey | |
| `DELETE auth/user/passkeys/{id}` | | `{deleted: true}` | 423 |

Passkey **creation and sign-in** need the platform credential APIs plus a
verified HTTPS domain (Digital Asset Links / Associated Domains); until the
app runs against one, passkeys are created on the website and managed here.

## 3. Feature discovery

`GET handshake` and `GET config` add:

```json
"features": {
  "fortify": {
    "installed": true,
    "registration": true, "reset_passwords": true, "email_verification": true,
    "update_profile_information": true, "update_passwords": true,
    "two_factor_authentication": true, "two_factor_confirm": true,
    "two_factor_confirm_password": true, "passkeys": true,
    "username": "email", "password_min": 12, "password_timeout": 10800,
    "codes": {"length": 6, "ttl": 600}
  }
}
```

## 4. User payload additions

`email_verified` (bool), `email_verified_at`, `two_factor_enabled` (bool, i.e.
confirmed when confirmation is on), `two_factor_pending_confirmation` (bool),
`passkeys_count` when available. The app's `user_presenter` still decides the
rest of the shape.

## 5. Dart API (flutter_laravel_bridge 2.2)

On `AuthManager` (and passed through by `LaravelConnectionManager`):

```dart
// discovery
FortifyFeatures get fortify;                      // from handshake/config
// guest
Future<TUser> login({...existing, String? code, String? recoveryCode});
Future<TUser> register({...existing});
Future<PasswordResetRequest> forgotPassword(String email);
Future<String> verifyPasswordResetCode({required String email, required String code}); // reset token
Future<void> resetPassword({required String email, required String password,
    required String passwordConfirmation, String? resetToken, String? token});
// signed in
Future<void> sendEmailVerification();
Future<TUser> verifyEmail(String code);
Future<TUser> updateProfile(Map<String, dynamic> fields);
Future<void> updatePassword({required String currentPassword, required String password,
    required String passwordConfirmation, bool revokeOtherSessions = false});
Future<PasswordConfirmation> confirmPassword(String password);
Future<PasswordConfirmation> confirmedPasswordStatus();
TwoFactorManager get twoFactor; // enable(), qrCode() -> TwoFactorQrCode{svg,url},
                                // secretKey(), confirm(code), recoveryCodes(),
                                // regenerateRecoveryCodes(), disable()
PasskeyManager get passkeys;    // list(), rename(id, name), delete(id)
```

New typed exceptions (all extend the existing hierarchy, carry `errorCode`):
`LaravelPasswordConfirmationRequiredException` (423),
`LaravelCodeException` (`invalid` / `expired` / `locked`),
`LaravelFeatureDisabledException` (404 `feature_disabled`),
`LaravelAlreadyVerifiedException` (409). The user model exposes
`emailVerified`, `twoFactorEnabled` through the app's parser; `AuthState`
gains nothing new (verification is a property of the user).

## 6. Client notes (flutter_laravel_bridge 2.2.0)

Decisions the contract above leaves open, as implemented by the Dart client.
All of them are additive and tolerant.

* **Endpoint keys.** The client resolves the paths of §2 through the handshake
  `endpoints` table under these keys (route names without the `flutter.`
  prefix), falling back to the paths of §2 under the bridge prefix when a key
  is not advertised: `auth.password.forgot`, `auth.password.verify_code`,
  `auth.password.reset`, `auth.email.send`, `auth.email.verify`,
  `auth.user.profile`, `auth.user.password`, `auth.user.confirm_password`,
  `auth.user.confirmed_password_status`, `auth.two_factor.enable` /
  `.disable` / `.confirm` / `.qr_code` / `.secret_key` / `.recovery_codes` /
  `.regenerate_recovery_codes`, `auth.passkeys.index` / `.update` /
  `.destroy` (placeholder `{passkey}`; `{id}` is accepted too).
* **"user" in a success column** means `data.user` (as in `auth/me`); a bare
  user object as `data` is accepted too, and when neither is present the
  client re-reads `auth/me`. `verifyEmail`, `updateProfile` and
  `twoFactor.confirm` publish the user: `currentUser`, the offline user cache
  and an `Authenticated` state event. `twoFactor.enable()` / `disable()`
  re-read `auth/me` afterwards (best effort) so `two_factor_enabled` /
  `two_factor_pending_confirmation` stay current.
* **Lists.** `GET auth/user/passkeys` may answer the array as `data` (as in
  §2) or `{passkeys: [...]}`; recovery codes likewise `{recovery_codes}` or
  the bare array. `PATCH auth/user/passkeys/{id}` may answer the passkey or
  `{passkey}`. Passkey ids are read as strings.
* **Discovery.** `features.fortify` is read from the handshake (and from
  `GET config` → `data.features.fortify`, or `data.fortify`, via
  `AuthManager.refreshFortifyFeatures()`). Extra keys published by the
  server are parsed when known (`enabled`, `passkeys_confirm_password`,
  `lowercase_usernames`, `reset_channel`) and always reachable through
  `FortifyFeatures.has(name)` / `.raw`. Without the block every Fortify flag
  is `false` (registration mirrors `features.registration`) and **nothing is
  blocked locally**; only an explicit `false` in a published block makes the
  client throw `LaravelFeatureDisabledException` without sending the request.
  Gated: `registration` (register), `reset_passwords`, `email_verification`,
  `update_profile_information`, `update_passwords`,
  `two_factor_authentication` (all of `twoFactor`), `passkeys`. Password
  confirmation is never gated.
* **Error mapping.** `meta.error_code` wins over the status:
  `code_invalid` / `reset_token_invalid` → `LaravelCodeException(kind:
  invalid)`, `code_expired` → `expired`, `code_locked` → `locked` (all
  `LaravelValidationError`s); `password_confirmation_required` (or a 423
  without a code, as Fortify's own middleware sends) →
  `LaravelPasswordConfirmationRequiredException`; `already_verified` →
  `LaravelAlreadyVerifiedException`; **404** `feature_disabled` →
  `LaravelFeatureDisabledException` (a `LaravelNotFoundException`, `feature`
  read from `errors.feature`). A 403 `feature_disabled` (a bridge feature
  switched off) keeps its `LaravelPermissionException` mapping.
  `two_factor_invalid` on `confirmed-two-factor-authentication` maps to the
  existing `LaravelTwoFactorRequiredException(invalid: true)`;
  `password_invalid` and `two_factor_not_enabled` stay plain
  `LaravelValidationError` / `LaravelNotFoundException` with the code.
* **Password confirmation.** `PasswordConfirmation.confirmedAt` is the local
  time of a successful `confirmPassword`; for `confirmedPasswordStatus` it is
  `confirmed_at` when sent, else derived as
  `now - (password_timeout - expires_in)`. `isConfirmed()` is judged locally
  from `expires_in`. A 423 from two-factor / passkey calls forgets the
  locally known confirmation. `runWithPasswordConfirmation` retries exactly
  once and rethrows the 423 when the prompt returns `null`.
* **Token rotation.** If `PUT auth/user/password` ever returns an
  `authorization` object the client stores it; today it is not required.
