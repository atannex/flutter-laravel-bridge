import 'dart:convert';

import '../connection/bridge_ids.dart';

/// `features.fortify.codes`: shape of the one-time codes emailed by the bridge.
class FortifyCodeSettings {
  /// Number of digits of a code (default 6).
  final int length;

  /// Lifetime of a code (default 10 minutes).
  final Duration ttl;

  const FortifyCodeSettings({
    this.length = 6,
    this.ttl = const Duration(minutes: 10),
  });

  factory FortifyCodeSettings.fromJson(Map<String, dynamic> json) {
    final ttl = parseBridgeInt(json['ttl']);
    return FortifyCodeSettings(
      length: parseBridgeInt(json['length']) ?? 6,
      ttl: ttl != null ? Duration(seconds: ttl) : const Duration(minutes: 10),
    );
  }

  Map<String, dynamic> toJson() => {'length': length, 'ttl': ttl.inSeconds};
}

/// Which Laravel Fortify features the server exposes over the bridge
/// (`features.fortify` of `GET handshake` / `GET config`, FORTIFY.md §3).
///
/// When the server does not publish the block ([advertised] is `false`, e.g. a
/// bridge older than 2.2) every Fortify feature reads `false`, except
/// [registration], which mirrors the bridge's own `features.registration`.
/// Nothing is blocked locally in that case: only an explicit `false` from the
/// server makes [AuthManager] refuse a call without sending it.
class FortifyFeatures {
  /// Whether the server published `features.fortify` at all.
  final bool advertised;

  /// Whether `laravel/fortify` is installed on the server.
  final bool installed;

  /// Whether the bridge's Fortify integration is active (`enabled`; defaults
  /// to [installed] when the server does not send it).
  final bool enabled;
  final bool registration;
  final bool resetPasswords;
  final bool emailVerification;
  final bool updateProfileInformation;
  final bool updatePasswords;
  final bool twoFactorAuthentication;

  /// New authenticator apps must be confirmed with a code before they count.
  final bool twoFactorConfirm;

  /// Managing two-factor (and passkeys) needs a recent password confirmation.
  final bool twoFactorConfirmPassword;
  final bool passkeys;

  /// Removing a passkey needs a recent password confirmation.
  final bool passkeysConfirmPassword;

  /// Login field (`fortify.username`, usually `email`).
  final String username;

  /// Whether the server lowercases the username (`fortify.lowercase_usernames`).
  final bool lowercaseUsernames;

  /// How `forgotPassword` delivers: `code` (default) or `link`.
  final String resetChannel;

  /// Minimum password length, when published.
  final int? passwordMin;

  /// How long a password confirmation stays valid (`auth.password_timeout`).
  final Duration passwordTimeout;

  /// Shape of the emailed codes.
  final FortifyCodeSettings codes;

  /// The raw block, including flags unknown to this client version.
  final Map<String, dynamic> raw;

  const FortifyFeatures({
    this.advertised = true,
    this.installed = false,
    this.enabled = false,
    this.registration = false,
    this.resetPasswords = false,
    this.emailVerification = false,
    this.updateProfileInformation = false,
    this.updatePasswords = false,
    this.twoFactorAuthentication = false,
    this.twoFactorConfirm = false,
    this.twoFactorConfirmPassword = false,
    this.passkeys = false,
    this.passkeysConfirmPassword = false,
    this.username = 'email',
    this.lowercaseUsernames = false,
    this.resetChannel = 'code',
    this.passwordMin,
    this.passwordTimeout = const Duration(seconds: 10800),
    this.codes = const FortifyCodeSettings(),
    this.raw = const {},
  });

  /// Defaults used when the server publishes no `features.fortify` block.
  const FortifyFeatures.unavailable({this.registration = true})
      : advertised = false,
        installed = false,
        enabled = false,
        resetPasswords = false,
        emailVerification = false,
        updateProfileInformation = false,
        updatePasswords = false,
        twoFactorAuthentication = false,
        twoFactorConfirm = false,
        twoFactorConfirmPassword = false,
        passkeys = false,
        passkeysConfirmPassword = false,
        username = 'email',
        lowercaseUsernames = false,
        resetChannel = 'code',
        passwordMin = null,
        passwordTimeout = const Duration(seconds: 10800),
        codes = const FortifyCodeSettings(),
        raw = const {};

  /// Parse `features.fortify`; [json] `null` (or not a map) gives
  /// [FortifyFeatures.unavailable].
  factory FortifyFeatures.fromJson(dynamic json,
      {bool registrationFallback = true}) {
    if (json is! Map) {
      return FortifyFeatures.unavailable(registration: registrationFallback);
    }
    final map = parseBridgeMap(json);
    bool flag(String key) => parseBridgeBool(map[key]) ?? false;
    final timeout = parseBridgeInt(map['password_timeout']);
    return FortifyFeatures(
      advertised: true,
      installed: flag('installed'),
      enabled: parseBridgeBool(map['enabled']) ?? flag('installed'),
      registration:
          parseBridgeBool(map['registration']) ?? registrationFallback,
      resetPasswords: flag('reset_passwords'),
      emailVerification: flag('email_verification'),
      updateProfileInformation: flag('update_profile_information'),
      updatePasswords: flag('update_passwords'),
      twoFactorAuthentication: flag('two_factor_authentication'),
      twoFactorConfirm: flag('two_factor_confirm'),
      twoFactorConfirmPassword: flag('two_factor_confirm_password'),
      passkeys: flag('passkeys'),
      passkeysConfirmPassword: flag('passkeys_confirm_password'),
      username: map['username']?.toString() ?? 'email',
      lowercaseUsernames: flag('lowercase_usernames'),
      resetChannel: map['reset_channel']?.toString() ?? 'code',
      passwordMin: parseBridgeInt(map['password_min']),
      passwordTimeout: Duration(seconds: timeout ?? 10800),
      codes: FortifyCodeSettings.fromJson(parseBridgeMap(map['codes'])),
      raw: Map<String, dynamic>.unmodifiable(map),
    );
  }

  /// Check a flag by its server name (`reset_passwords`, `passkeys`…),
  /// including flags unknown to this client version.
  bool has(String feature) => parseBridgeBool(raw[feature]) ?? false;

  Map<String, dynamic> toJson() => {
        ...raw,
        'installed': installed,
        'enabled': enabled,
        'registration': registration,
        'reset_passwords': resetPasswords,
        'email_verification': emailVerification,
        'update_profile_information': updateProfileInformation,
        'update_passwords': updatePasswords,
        'two_factor_authentication': twoFactorAuthentication,
        'two_factor_confirm': twoFactorConfirm,
        'two_factor_confirm_password': twoFactorConfirmPassword,
        'passkeys': passkeys,
        'passkeys_confirm_password': passkeysConfirmPassword,
        'username': username,
        'lowercase_usernames': lowercaseUsernames,
        'reset_channel': resetChannel,
        'password_min': passwordMin,
        'password_timeout': passwordTimeout.inSeconds,
        'codes': codes.toJson(),
      };

  /// Two feature sets are equal when they publish the same flags (so a
  /// listener of `fortifyListenable` only hears about real changes).
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FortifyFeatures &&
          other.advertised == advertised &&
          other._signature == _signature;

  @override
  int get hashCode => Object.hash(advertised, _signature);

  String get _signature {
    try {
      return jsonEncode(toJson());
    } catch (_) {
      return toJson().toString();
    }
  }

  @override
  String toString() => 'FortifyFeatures(${advertised ? toJson() : 'none'})';
}

/// Result of `forgotPassword`: how the reset is delivered.
class PasswordResetRequest {
  /// Always `true` (the server never reveals whether the address exists).
  final bool sent;

  /// `code` (a code was emailed, use `verifyPasswordResetCode`) or `link`
  /// (the email holds a link to the website).
  final String channel;

  /// Lifetime of the emailed code / link.
  final Duration? expiresIn;

  const PasswordResetRequest({
    this.sent = true,
    this.channel = 'code',
    this.expiresIn,
  });

  /// Whether the user should type a code in the app.
  bool get usesCode => channel == 'code';

  factory PasswordResetRequest.fromJson(Map<String, dynamic> json) {
    final ttl = parseBridgeInt(json['expires_in']);
    return PasswordResetRequest(
      sent: parseBridgeBool(json['sent']) ?? true,
      channel: json['channel']?.toString() ?? 'code',
      expiresIn: ttl != null ? Duration(seconds: ttl) : null,
    );
  }
}

/// Result of `sendEmailVerification`: a verification code was emailed.
class VerificationCodeRequest {
  /// Always `true` when the call succeeded.
  final bool sent;

  /// Lifetime of the emailed code (`expires_in`), when the server sends it.
  /// Fall back to `FortifyFeatures.codes.ttl` when `null`.
  final Duration? expiresIn;

  const VerificationCodeRequest({this.sent = true, this.expiresIn});

  factory VerificationCodeRequest.fromJson(Map<String, dynamic> json) {
    final ttl = parseBridgeInt(json['expires_in']);
    return VerificationCodeRequest(
      sent: parseBridgeBool(json['sent']) ?? true,
      expiresIn: ttl != null ? Duration(seconds: ttl) : null,
    );
  }

  @override
  String toString() =>
      'VerificationCodeRequest(sent: $sent, expiresIn: $expiresIn)';
}

/// State of the password confirmation of the current token.
class PasswordConfirmation {
  /// Whether the password was confirmed recently enough.
  final bool confirmed;

  /// Remaining validity reported by the server.
  final Duration? expiresIn;

  /// When the password was confirmed (local clock), when known.
  final DateTime? confirmedAt;

  /// When the confirmation lapses (local clock), when known.
  final DateTime? expiresAt;

  const PasswordConfirmation({
    required this.confirmed,
    this.expiresIn,
    this.confirmedAt,
    this.expiresAt,
  });

  /// Build from `{confirmed, expires_in, confirmed_at?}` received at [now].
  /// [timeout] (`password_timeout`) lets [confirmedAt] be derived when the
  /// server does not send `confirmed_at`.
  factory PasswordConfirmation.fromJson(
    Map<String, dynamic> json, {
    required DateTime now,
    Duration? timeout,
    bool justConfirmed = false,
  }) {
    final confirmed = parseBridgeBool(json['confirmed']) ?? false;
    final seconds = parseBridgeInt(json['expires_in']);
    final expiresIn = seconds != null ? Duration(seconds: seconds) : null;
    DateTime? confirmedAt = parseBridgeDate(json['confirmed_at'])?.toLocal();
    if (confirmed && confirmedAt == null) {
      if (justConfirmed) {
        confirmedAt = now;
      } else if (timeout != null && expiresIn != null) {
        confirmedAt = now.subtract(timeout - expiresIn);
      }
    }
    return PasswordConfirmation(
      confirmed: confirmed,
      expiresIn: expiresIn,
      confirmedAt: confirmed ? confirmedAt : null,
      expiresAt: confirmed && expiresIn != null ? now.add(expiresIn) : null,
    );
  }

  /// Whether the confirmation is still valid at [now] (default: now), without
  /// asking the server.
  bool isConfirmed([DateTime? now]) {
    if (!confirmed) return false;
    final expiry = expiresAt;
    return expiry == null || (now ?? DateTime.now()).isBefore(expiry);
  }

  @override
  String toString() =>
      'PasswordConfirmation(confirmed: $confirmed, expiresIn: $expiresIn)';
}

/// Result of `twoFactor.enable()` (and `disable()`).
class TwoFactorStatus {
  final bool enabled;

  /// Whether the authenticator app has been confirmed with a code.
  final bool confirmed;

  /// Whether the server requires new authenticator apps to be confirmed
  /// with a code (Fortify's `confirm` option).
  final bool requiresConfirmation;

  const TwoFactorStatus({
    required this.enabled,
    this.confirmed = false,
    this.requiresConfirmation = false,
  });

  /// Whether `twoFactor.confirm(code)` is still needed.
  bool get needsConfirmation => enabled && requiresConfirmation && !confirmed;

  factory TwoFactorStatus.fromJson(Map<String, dynamic> json) =>
      TwoFactorStatus(
        enabled: parseBridgeBool(json['enabled']) ?? false,
        confirmed: parseBridgeBool(json['confirmed']) ?? false,
        requiresConfirmation:
            parseBridgeBool(json['requires_confirmation']) ?? false,
      );
}

/// QR code to scan with an authenticator app.
class TwoFactorQrCode {
  /// SVG markup of the QR code.
  final String svg;

  /// The `otpauth://` URL encoded in the QR code (open it to add the account
  /// on the same phone).
  final String url;

  const TwoFactorQrCode({required this.svg, required this.url});

  factory TwoFactorQrCode.fromJson(Map<String, dynamic> json) =>
      TwoFactorQrCode(
        svg: json['svg']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
      );
}

/// A passkey registered for the signed-in user.
class Passkey {
  final String id;
  final String name;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;

  /// The raw server payload (extra columns included).
  final Map<String, dynamic> raw;

  const Passkey({
    required this.id,
    required this.name,
    this.createdAt,
    this.lastUsedAt,
    this.raw = const {},
  });

  factory Passkey.fromJson(Map<String, dynamic> json) => Passkey(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        createdAt: parseBridgeDate(json['created_at']),
        lastUsedAt: parseBridgeDate(json['last_used_at']),
        raw: Map<String, dynamic>.unmodifiable(json),
      );

  Map<String, dynamic> toJson() => {
        ...raw,
        'id': id,
        'name': name,
        'created_at': createdAt?.toIso8601String(),
        'last_used_at': lastUsedAt?.toIso8601String(),
      };
}
