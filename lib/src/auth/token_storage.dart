import 'dart:async';

import '../storage/key_value_store.dart';

/// Abstract storage contract for persisting authentication tokens.
abstract class TokenStorage {
  /// Save the access token.
  Future<void> saveAccessToken(String token);

  /// Retrieve the saved access token.
  Future<String?> getAccessToken();

  /// Save the refresh token.
  Future<void> saveRefreshToken(String token);

  /// Retrieve the saved refresh token.
  Future<String?> getRefreshToken();

  /// Clear all stored tokens upon logout.
  Future<void> clear();
}

/// Capability implemented by token storages that can hand out isolated,
/// namespaced views of themselves — used to keep the tokens of each
/// [LaravelConnection] profile separate.
abstract class ScopedTokenStorage implements TokenStorage {
  /// Namespace of this view (`null` for the root storage).
  String? get namespace;

  /// Return a storage whose keys are isolated under [namespace].
  TokenStorage scoped(String namespace);
}

/// Adds [scoped] to every [TokenStorage].
extension TokenStorageScoping on TokenStorage {
  /// Whether this storage supports [scoped].
  bool get supportsScoping => this is ScopedTokenStorage;

  /// Return a storage isolated under [namespace].
  ///
  /// Throws [UnsupportedError] for custom storages that do not implement
  /// [ScopedTokenStorage].
  TokenStorage scoped(String namespace) {
    final self = this;
    if (self is ScopedTokenStorage) return self.scoped(namespace);
    throw UnsupportedError(
      '$runtimeType does not support scoping. Implement ScopedTokenStorage or '
      'pass a tokenStorageFactory to Laravel.initialize().',
    );
  }
}

String _scopedKey(String key, String? namespace) =>
    namespace == null || namespace.isEmpty ? key : '$key:$namespace';

String _joinNamespace(String? parent, String child) =>
    parent == null || parent.isEmpty ? child : '$parent:$child';

/// Lightweight in-memory implementation of [TokenStorage].
/// Ideal for testing or non-persistent sessions.
///
/// Tokens are lost when the app restarts, so users have to sign in again.
/// Use [DelegateTokenStorage.fromKeyValue] (e.g. over FlutterSecureStorage) in
/// production.
///
/// Scoped views created with [scoped] share the same backing map but use
/// distinct keys, so clearing one scope never affects another.
class InMemoryTokenStorage implements ScopedTokenStorage {
  final Map<String, String> _values;

  @override
  final String? namespace;

  InMemoryTokenStorage() : this._(<String, String>{}, null);

  InMemoryTokenStorage._(this._values, this.namespace);

  String get _accessKey =>
      _scopedKey(DelegateTokenStorage.accessTokenKey, namespace);
  String get _refreshKey =>
      _scopedKey(DelegateTokenStorage.refreshTokenKey, namespace);

  @override
  Future<void> saveAccessToken(String token) async {
    _values[_accessKey] = token;
  }

  @override
  Future<String?> getAccessToken() async {
    return _values[_accessKey];
  }

  @override
  Future<void> saveRefreshToken(String token) async {
    _values[_refreshKey] = token;
  }

  @override
  Future<String?> getRefreshToken() async {
    return _values[_refreshKey];
  }

  @override
  Future<void> clear() async {
    _values.remove(_accessKey);
    _values.remove(_refreshKey);
  }

  @override
  InMemoryTokenStorage scoped(String namespace) => InMemoryTokenStorage._(
      _values, _joinNamespace(this.namespace, namespace));
}

/// Custom delegate storage adapter allowing applications to pass
/// any key-value store (such as FlutterSecureStorage or SharedPreferences).
///
/// Wiring FlutterSecureStorage is a one-liner:
///
/// ```dart
/// const secure = FlutterSecureStorage();
/// final tokens = DelegateTokenStorage.fromKeyValue(
///   read: (key) => secure.read(key: key),
///   write: (key, value) => secure.write(key: key, value: value),
///   delete: (key) => secure.delete(key: key),
/// );
/// ```
///
/// With a [namespace] the keys become `flutter_laravel_access_token:<namespace>`
/// and `flutter_laravel_refresh_token:<namespace>`.
class DelegateTokenStorage implements ScopedTokenStorage {
  final Future<void> Function(String key, String value) onWrite;
  final Future<String?> Function(String key) onRead;
  final Future<void> Function(String key) onDelete;

  @override
  final String? namespace;

  static const String accessTokenKey = 'flutter_laravel_access_token';
  static const String refreshTokenKey = 'flutter_laravel_refresh_token';

  const DelegateTokenStorage({
    required this.onWrite,
    required this.onRead,
    required this.onDelete,
    this.namespace,
  });

  /// Same as the default constructor, with `read` / `write` / `delete` names
  /// matching most key-value plugins.
  const DelegateTokenStorage.fromKeyValue({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required Future<void> Function(String key) delete,
    String? namespace,
  }) : this(
          onRead: read,
          onWrite: write,
          onDelete: delete,
          namespace: namespace,
        );

  /// Store tokens in a [BridgeKeyValueStore].
  DelegateTokenStorage.fromStore(BridgeKeyValueStore store, {String? namespace})
      : this(
          onRead: store.read,
          onWrite: store.write,
          onDelete: store.delete,
          namespace: namespace,
        );

  /// Effective key used for the access token.
  String get accessKey => _scopedKey(accessTokenKey, namespace);

  /// Effective key used for the refresh token.
  String get refreshKey => _scopedKey(refreshTokenKey, namespace);

  @override
  Future<void> saveAccessToken(String token) => onWrite(accessKey, token);

  @override
  Future<String?> getAccessToken() => onRead(accessKey);

  @override
  Future<void> saveRefreshToken(String token) => onWrite(refreshKey, token);

  @override
  Future<String?> getRefreshToken() => onRead(refreshKey);

  @override
  Future<void> clear() async {
    await onDelete(accessKey);
    await onDelete(refreshKey);
  }

  @override
  DelegateTokenStorage scoped(String namespace) => DelegateTokenStorage(
        onWrite: onWrite,
        onRead: onRead,
        onDelete: onDelete,
        namespace: _joinNamespace(this.namespace, namespace),
      );
}
