import 'package:flutter/foundation.dart';

import '../connection/bridge_endpoints.dart';
import '../connection/bridge_ids.dart';
import '../exceptions/laravel_exception.dart';
import 'auth_manager.dart';
import 'fortify_models.dart';

/// Authenticator-app (TOTP) management of the signed-in user, through
/// Fortify's two-factor actions (FORTIFY.md §2). Reach it via
/// `auth.twoFactor`.
///
/// When the server's `two_factor_confirm_password` option is on, [enable],
/// [recoveryCodes], [regenerateRecoveryCodes] and [disable] need a recent
/// password confirmation and otherwise throw
/// [LaravelPasswordConfirmationRequiredException]; see
/// [AuthManager.runWithPasswordConfirmation].
class TwoFactorManager<TUser> {
  final AuthManager<TUser> auth;

  TwoFactorManager(this.auth);

  static const String feature = 'two_factor_authentication';

  /// Turn two-factor authentication on. When the result has
  /// `requiresConfirmation`, show [qrCode] and finish with [confirm].
  Future<TwoFactorStatus> enable() async {
    auth.requireFortifyFeature(feature);
    final response = await _guard(() => auth.client.post<dynamic>(
        auth.client.endpoint(BridgeEndpoints.authTwoFactorEnable)));
    final status = TwoFactorStatus.fromJson(parseBridgeMap(response.data));
    await _reloadQuietly();
    return status;
  }

  /// QR code (SVG + `otpauth://` URL) to scan with an authenticator app.
  /// Throws [LaravelNotFoundException] (`two_factor_not_enabled`) before
  /// [enable].
  Future<TwoFactorQrCode> qrCode() async {
    auth.requireFortifyFeature(feature);
    final response = await _guard(() => auth.client.get<dynamic>(
        auth.client.endpoint(BridgeEndpoints.authTwoFactorQrCode)));
    return TwoFactorQrCode.fromJson(parseBridgeMap(response.data));
  }

  /// The shared secret, for typing into an authenticator app by hand.
  Future<String> secretKey() async {
    auth.requireFortifyFeature(feature);
    final response = await _guard(() => auth.client.get<dynamic>(
        auth.client.endpoint(BridgeEndpoints.authTwoFactorSecretKey)));
    return parseBridgeMap(response.data)['secret_key']?.toString() ?? '';
  }

  /// Confirm the authenticator app with a [code] it shows. Returns (and
  /// publishes) the refreshed user. A wrong code throws
  /// [LaravelTwoFactorRequiredException] with `invalid == true`.
  Future<TUser> confirm(String code) async {
    auth.requireFortifyFeature(feature);
    final response = await _guard(() => auth.client.post<dynamic>(
          auth.client.endpoint(BridgeEndpoints.authTwoFactorConfirm),
          data: {'code': code},
        ));
    return auth.applyUserPayload(response.data);
  }

  /// The current recovery codes.
  Future<List<String>> recoveryCodes() async {
    auth.requireFortifyFeature(feature);
    final response = await _guard(() => auth.client.get<dynamic>(
        auth.client.endpoint(BridgeEndpoints.authTwoFactorRecoveryCodes)));
    return _codes(response.data);
  }

  /// Replace the recovery codes with a new set and return it.
  Future<List<String>> regenerateRecoveryCodes() async {
    auth.requireFortifyFeature(feature);
    final response = await _guard(() => auth.client.post<dynamic>(auth.client
        .endpoint(BridgeEndpoints.authTwoFactorRegenerateRecoveryCodes)));
    return _codes(response.data);
  }

  /// Turn two-factor authentication off.
  Future<void> disable() async {
    auth.requireFortifyFeature(feature);
    await _guard(() => auth.client.delete<dynamic>(
        auth.client.endpoint(BridgeEndpoints.authTwoFactorDisable)));
    await _reloadQuietly();
  }

  static List<String> _codes(dynamic data) {
    final raw = data is Map ? data['recovery_codes'] : data;
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return const [];
  }

  Future<void> _reloadQuietly() async {
    try {
      await auth.reloadUser();
    } catch (e) {
      debugPrint('TwoFactorManager could not reload the user: $e');
    }
  }

  Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on LaravelPasswordConfirmationRequiredException {
      auth.markPasswordUnconfirmed();
      rethrow;
    }
  }
}
