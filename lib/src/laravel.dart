import 'dart:async';

import 'auth/auth_manager.dart';
import 'auth/token_storage.dart';
import 'client/laravel_client.dart';
import 'client/laravel_options.dart';
import 'connection/bridge_command.dart';
import 'connection/connection_manager.dart';
import 'connection/connection_store.dart';
import 'connection/laravel_connection.dart';
import 'connection/server_info.dart';
import 'device/device_manager.dart';
import 'echo/echo_options.dart';
import 'echo/laravel_echo.dart';
import 'exceptions/laravel_exception.dart';
import 'storage/key_value_store.dart';
import 'upload/laravel_uploader.dart';

/// Top-level facade offering access to the bridge subsystems.
///
/// Every subsystem is bound to the **active connection profile**; switching
/// profiles with [switchConnection] rebuilds them and fires [changes].
class Laravel {
  Laravel._();

  /// Id of the profile seeded from [LaravelOptions] when the store is empty.
  static const String defaultConnectionId = 'default';

  static LaravelConnectionManager? _manager;
  static LaravelClient? _client;
  static AuthManager<dynamic>? _auth;
  static LaravelEcho? _echo;
  static DeviceManager? _devices;
  static LaravelUploader? _uploader;
  static StreamSubscription<void>? _runtimeSubscription;
  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  /// Whether [initialize] has completed.
  static bool get isInitialized => _manager != null;

  /// Fires when [client], [auth], [echo], [devices] and [uploader] were rebuilt
  /// (connection switched, profile edited or Echo configured from the server).
  static Stream<void> get changes => _changes.stream;

  /// Connection profile & session manager.
  static LaravelConnectionManager get connections {
    final manager = _manager;
    if (manager == null) {
      throw StateError(
          'Laravel.initialize() must be called before accessing Laravel.connections');
    }
    return manager;
  }

  /// Handshake information of the active server (null until connected).
  static ServerInfo? get server => _manager?.serverInfo;

  /// Global client instance.
  static LaravelClient get client {
    if (_client == null) {
      throw StateError(
          'Laravel.initialize() must be called before accessing Laravel.client');
    }
    return _client!;
  }

  /// Global authentication manager instance.
  static AuthManager<TUser> auth<TUser>() {
    if (_auth == null) {
      throw StateError(
          'Laravel.initialize() must be called before accessing Laravel.auth');
    }
    return _auth! as AuthManager<TUser>;
  }

  /// Global real-time Reverb/Pusher Echo instance.
  static LaravelEcho get echo {
    if (_echo == null) {
      throw StateError(
        'Laravel Echo is not initialized. Provide echoOptions in Laravel.initialize() '
        'or enable broadcasting on the server (autoConfigureEcho).',
      );
    }
    return _echo!;
  }

  /// Whether an Echo instance is available for the active connection.
  static bool get hasEcho => _echo != null;

  /// Global device and FCM manager instance.
  static DeviceManager get devices {
    if (_devices == null) {
      throw StateError(
          'Laravel.initialize() must be called before accessing Laravel.devices');
    }
    return _devices!;
  }

  /// Global multipart file uploader instance.
  static LaravelUploader get uploader {
    if (_uploader == null) {
      throw StateError(
          'Laravel.initialize() must be called before accessing Laravel.uploader');
    }
    return _uploader!;
  }

  /// Switch the active backend. Client, auth (with that profile's own tokens),
  /// devices, uploader and echo are rebuilt, the profile's session is restored
  /// and [changes] fires.
  static Future<void> switchConnection(String id) => connections.switchTo(id);

  /// Initialize the global Laravel Flutter Bridge environment.
  ///
  /// * [connectionStore] persists profiles; when omitted (or empty) a `default`
  ///   profile is seeded from [options] (`baseUrl`, `appKey`, `prefix`).
  /// * [tokenStorage] is the root token storage; every non-default profile
  ///   uses a namespaced view of it. [tokenStorageFactory] overrides this.
  /// * [storage] is one app-provided key-value store (e.g. FlutterSecureStorage
  ///   through [DelegateKeyValueStore]) used for tokens (namespaced per
  ///   profile), connection profiles, offline queues and response caches
  ///   (namespaced per profile) — unless [tokenStorage] / [tokenStorageFactory],
  ///   [connectionStore], [offlineQueueStore] or [cacheStore] override a part.
  ///   Without any of them tokens live in memory and users are logged out on
  ///   every restart (a debug warning is printed).
  /// * [autoConnect] performs handshake + session connect immediately.
  /// * [autoConfigureEcho] builds and connects Echo from the server handshake.
  static Future<void> initialize<TUser>({
    required LaravelOptions options,
    required TUser Function(Map<String, dynamic> json) userParser,
    EchoOptions? echoOptions,
    TokenStorage? tokenStorage,
    void Function()? onSessionExpired,
    ConnectionStore? connectionStore,
    TokenStorage Function(LaravelConnection connection)? tokenStorageFactory,
    bool autoConnect = true,
    bool autoConfigureEcho = true,
    void Function(String? reason)? onSessionRevoked,
    void Function(LaravelUpgradeRequiredException e)? onUpgradeRequired,
    void Function(BridgeCommand command)? onCommand,
    HttpClientAdapterFactory? httpClientAdapterFactory,
    bool enableTimers = true,
    BridgeKeyValueStore? storage,
    BridgeKeyValueStore? offlineQueueStore,
    BridgeKeyValueStore? cacheStore,
  }) async {
    await reset();

    final manager = LaravelConnectionManager(
      options: options,
      store: connectionStore,
      storage: storage,
      offlineQueueStore: offlineQueueStore,
      cacheStore: cacheStore,
      tokenStorage: tokenStorage,
      tokenStorageFactory: tokenStorageFactory,
      unscopedProfileId: defaultConnectionId,
      authFactory: (client, storage, profile) => AuthManager<TUser>(
        client: client,
        tokenStorage: storage,
        userParser: userParser,
        onSessionExpired: onSessionExpired,
        proactiveRefresh: enableTimers,
      ),
      httpClientAdapterFactory: httpClientAdapterFactory,
      autoConfigureEcho: autoConfigureEcho,
      enableTimers: enableTimers,
      onSessionRevoked: onSessionRevoked,
      onUpgradeRequired: onUpgradeRequired,
      onCommand: onCommand,
    );
    _manager = manager;
    _runtimeSubscription = manager.runtimeChanges.listen((_) => _bindRuntime());

    await manager.load();

    final seeded = manager.connectionById(defaultConnectionId);
    if (manager.connections.isEmpty) {
      await manager.add(
        LaravelConnection(
          id: defaultConnectionId,
          name: 'Default',
          baseUrl: options.baseUrl,
          prefix: options.normalizedPrefix,
          appKey: options.appKey,
          autoConfigureEcho: autoConfigureEcho,
          echoOptions: echoOptions,
        ),
        makeActive: true,
        connect: false,
      );
    } else if (seeded != null &&
        echoOptions != null &&
        seeded.echoOptions != echoOptions) {
      // Keep code-level Echo configuration of the default profile in sync.
      await manager.update(seeded.copyWith(echoOptions: echoOptions));
    }

    _bindRuntime();

    if (autoConnect && manager.active != null) {
      await manager.connect();
    } else {
      await _auth?.initialize();
    }
  }

  static void _bindRuntime() {
    final manager = _manager;
    if (manager == null) return;
    final client = manager.client;
    final changed = !identical(client, _client) ||
        !identical(manager.auth, _auth) ||
        !identical(manager.echo, _echo);

    _client = client;
    _auth = manager.auth;
    _echo = manager.echo;
    if (client == null) {
      _devices = null;
      _uploader = null;
    } else if (!identical(_devices?.client, client)) {
      _devices = DeviceManager(client);
      _uploader = LaravelUploader(client);
    }

    if (changed && !_changes.isClosed) _changes.add(null);
  }

  /// Tear down every subsystem (mainly for tests). [initialize] can be called again.
  static Future<void> reset() async {
    await _runtimeSubscription?.cancel();
    _runtimeSubscription = null;
    final manager = _manager;
    _manager = null;
    final hadState = _client != null;
    _client = null;
    _auth = null;
    _echo = null;
    _devices = null;
    _uploader = null;
    if (manager != null) await manager.dispose();
    if (hadState && !_changes.isClosed) _changes.add(null);
  }
}
