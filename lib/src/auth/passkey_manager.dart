import '../connection/bridge_endpoints.dart';
import '../connection/bridge_ids.dart';
import '../exceptions/laravel_exception.dart';
import 'auth_manager.dart';
import 'fortify_models.dart';

/// Passkeys of the signed-in user (FORTIFY.md §2). Reach it via
/// `auth.passkeys`.
///
/// Passkeys are created (and used to sign in) on the website; the app lists,
/// renames and removes them. Removing one may need a recent password
/// confirmation ([LaravelPasswordConfirmationRequiredException]).
class PasskeyManager {
  final AuthManager<dynamic> auth;

  PasskeyManager(this.auth);

  static const String feature = 'passkeys';

  /// Every passkey of the signed-in user.
  Future<List<Passkey>> list() async {
    auth.requireFortifyFeature(feature);
    final response = await auth.client
        .get<dynamic>(auth.client.endpoint(BridgeEndpoints.authPasskeys));
    final data = response.data;
    final raw = data is Map ? data['passkeys'] : data;
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Passkey.fromJson(parseBridgeMap(e)))
        .toList();
  }

  /// Rename the passkey [id]; returns the updated passkey.
  Future<Passkey> rename(Object id, String name) async {
    auth.requireFortifyFeature(feature);
    final response = await auth.client.patch<dynamic>(
      auth.client.endpoint(BridgeEndpoints.authPasskeyUpdate,
          params: {'passkey': id, 'id': id}),
      data: {'name': name},
    );
    final data = parseBridgeMap(response.data);
    final raw = data['passkey'] is Map ? parseBridgeMap(data['passkey']) : data;
    return Passkey.fromJson(raw);
  }

  /// Remove the passkey [id].
  Future<void> delete(Object id) async {
    auth.requireFortifyFeature(feature);
    try {
      await auth.client.delete<dynamic>(
        auth.client.endpoint(BridgeEndpoints.authPasskeyDestroy,
            params: {'passkey': id, 'id': id}),
      );
    } on LaravelPasswordConfirmationRequiredException {
      auth.markPasswordUnconfirmed();
      rethrow;
    }
  }
}
