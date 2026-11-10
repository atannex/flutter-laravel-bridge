/// Built-in endpoint table of the bridge protocol (CONNECTIONS.md §4).
///
/// The server advertises the authoritative table in its handshake; this class
/// provides the defaults used before the handshake completes or when a server
/// omits a key, so the client keeps working against older or partial servers.
class BridgeEndpoints {
  BridgeEndpoints._();

  /// Default bridge route prefix.
  static const String defaultPrefix = 'api/flutter';

  static const String ping = 'ping';
  static const String handshake = 'handshake';
  static const String config = 'config';
  static const String authLogin = 'auth.login';
  static const String authRegister = 'auth.register';
  static const String authSocial = 'auth.social';
  static const String authRefresh = 'auth.refresh';
  static const String authTwoFactorSend = 'auth.2fa.send';
  static const String authTwoFactorVerify = 'auth.2fa.verify';
  static const String authMe = 'auth.me';
  static const String authLogout = 'auth.logout';

  // Laravel Fortify over the bridge (FORTIFY.md §2).
  static const String authForgotPassword = 'auth.password.forgot';
  static const String authResetPasswordVerifyCode = 'auth.password.verify_code';
  static const String authResetPassword = 'auth.password.reset';
  static const String authEmailVerificationNotification = 'auth.email.send';
  static const String authEmailVerify = 'auth.email.verify';
  static const String authProfileInformation = 'auth.user.profile';
  static const String authUserPassword = 'auth.user.password';
  static const String authConfirmPassword = 'auth.user.confirm_password';
  static const String authConfirmedPasswordStatus =
      'auth.user.confirmed_password_status';
  static const String authTwoFactorEnable = 'auth.two_factor.enable';
  static const String authTwoFactorDisable = 'auth.two_factor.disable';
  static const String authTwoFactorQrCode = 'auth.two_factor.qr_code';
  static const String authTwoFactorSecretKey = 'auth.two_factor.secret_key';
  static const String authTwoFactorConfirm = 'auth.two_factor.confirm';
  static const String authTwoFactorRecoveryCodes =
      'auth.two_factor.recovery_codes';
  static const String authTwoFactorRegenerateRecoveryCodes =
      'auth.two_factor.regenerate_recovery_codes';
  static const String authPasskeys = 'auth.passkeys.index';
  static const String authPasskeyUpdate = 'auth.passkeys.update';
  static const String authPasskeyDestroy = 'auth.passkeys.destroy';

  static const String devicesRegister = 'devices.register';
  static const String devicesUnregister = 'devices.unregister';
  static const String broadcastingAuth = 'broadcasting.auth';
  static const String connectionsConnect = 'connections.connect';
  static const String connectionsHeartbeat = 'connections.heartbeat';
  static const String connectionsDisconnect = 'connections.disconnect';
  static const String connectionsIndex = 'connections.index';
  static const String connectionsRevoke = 'connections.revoke';
  static const String connectionsRevokeOthers = 'connections.revoke_others';

  /// Endpoint paths relative to the bridge prefix.
  static const Map<String, String> relativePaths = {
    ping: 'ping',
    handshake: 'handshake',
    config: 'config',
    authLogin: 'auth/login',
    authRegister: 'auth/register',
    authSocial: 'auth/social',
    authRefresh: 'auth/refresh',
    authTwoFactorSend: 'auth/2fa/send-otp',
    authTwoFactorVerify: 'auth/2fa/verify',
    authMe: 'auth/me',
    authLogout: 'auth/logout',
    authForgotPassword: 'auth/forgot-password',
    authResetPasswordVerifyCode: 'auth/reset-password/verify-code',
    authResetPassword: 'auth/reset-password',
    authEmailVerificationNotification: 'auth/email/verification-notification',
    authEmailVerify: 'auth/email/verify',
    authProfileInformation: 'auth/user/profile-information',
    authUserPassword: 'auth/user/password',
    authConfirmPassword: 'auth/user/confirm-password',
    authConfirmedPasswordStatus: 'auth/user/confirmed-password-status',
    authTwoFactorEnable: 'auth/user/two-factor-authentication',
    authTwoFactorDisable: 'auth/user/two-factor-authentication',
    authTwoFactorQrCode: 'auth/user/two-factor-qr-code',
    authTwoFactorSecretKey: 'auth/user/two-factor-secret-key',
    authTwoFactorConfirm: 'auth/user/confirmed-two-factor-authentication',
    authTwoFactorRecoveryCodes: 'auth/user/two-factor-recovery-codes',
    authTwoFactorRegenerateRecoveryCodes: 'auth/user/two-factor-recovery-codes',
    authPasskeys: 'auth/user/passkeys',
    authPasskeyUpdate: 'auth/user/passkeys/{passkey}',
    authPasskeyDestroy: 'auth/user/passkeys/{passkey}',
    devicesRegister: 'devices/register',
    devicesUnregister: 'devices/{device}',
    broadcastingAuth: 'broadcasting/auth',
    connectionsConnect: 'connections/connect',
    connectionsHeartbeat: 'connections/{connection}/heartbeat',
    connectionsDisconnect: 'connections/{connection}/disconnect',
    connectionsIndex: 'connections',
    connectionsRevoke: 'connections/{connection}',
    connectionsRevokeOthers: 'connections',
  };

  /// Whether [key] is part of the built-in table.
  static bool isKnown(String key) => relativePaths.containsKey(key);

  /// Build the default (unresolved) path template for [key] under [prefix].
  ///
  /// Throws [ArgumentError] when the key is unknown.
  static String template(String key, {String prefix = defaultPrefix}) {
    final relative = relativePaths[key];
    if (relative == null) {
      throw ArgumentError.value(key, 'key', 'Unknown bridge endpoint');
    }
    return joinPath(prefix, relative);
  }

  /// Build and resolve the default path for [key] under [prefix].
  static String path(
    String key, {
    String prefix = defaultPrefix,
    Map<String, Object> params = const {},
  }) {
    return resolve(template(key, prefix: prefix), params);
  }

  /// Replace `{placeholder}` segments in [template] with URL-encoded [params].
  ///
  /// Throws [ArgumentError] when a placeholder has no matching parameter.
  static String resolve(String template, Map<String, Object> params) {
    return template.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\??\}'),
        (match) {
      final name = match.group(1)!;
      final value = params[name];
      if (value == null) {
        throw ArgumentError(
            'Missing value for endpoint placeholder "{$name}" in "$template"');
      }
      return Uri.encodeComponent(value.toString());
    });
  }

  /// Join two path fragments with exactly one slash between them.
  static String joinPath(String a, String b) {
    final left = a.endsWith('/') ? a.substring(0, a.length - 1) : a;
    final right = b.startsWith('/') ? b.substring(1) : b;
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    return '$left/$right';
  }

  /// Normalise a user supplied prefix (`/api/flutter/` → `api/flutter`).
  static String normalizePrefix(String prefix) {
    var result = prefix.trim();
    while (result.startsWith('/')) {
      result = result.substring(1);
    }
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }
}
