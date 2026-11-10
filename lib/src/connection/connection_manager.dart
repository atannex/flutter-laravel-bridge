import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_manager.dart';
import '../auth/auth_state.dart';
import '../auth/fortify_models.dart';
import '../auth/token_storage.dart';
import '../cache/cache_policy.dart';
import '../client/interceptors/auth_interceptor.dart';
import '../client/laravel_client.dart';
import '../client/laravel_options.dart';
import '../echo/echo_options.dart';
import '../echo/laravel_echo.dart';
import '../exceptions/laravel_exception.dart';
import '../offline/offline_queue.dart';
import '../storage/key_value_store.dart';
import 'bridge_command.dart';
import 'bridge_endpoints.dart';
import 'bridge_ids.dart';
import 'bridge_version.dart';
import 'connection_session.dart';
import 'connection_state.dart';
import 'connection_store.dart';
import 'laravel_connection.dart';
import 'server_info.dart';

/// Builds the [TokenStorage] used by a connection profile.
typedef TokenStorageFactory = TokenStorage Function(LaravelConnection profile);

/// Builds the [AuthManager] bound to a profile's client.
typedef AuthManagerFactory = AuthManager<dynamic> Function(
  LaravelClient client,
  TokenStorage tokenStorage,
  LaravelConnection profile,
);

/// Builds a [LaravelEcho] instance (override in tests).
typedef EchoFactory = LaravelEcho Function(
    EchoOptions options, LaravelClient client);

/// Builds the Dio instance used by a profile's client (override in tests).
typedef DioFactory = Dio Function(
    BaseOptions options, LaravelConnection profile);

/// Builds the HTTP adapter used by a profile's client (override in tests).
typedef HttpClientAdapterFactory = HttpClientAdapter Function(
    LaravelConnection profile);

/// Everything bound to the active profile: client, auth, echo, session.
class _Runtime {
  LaravelConnection profile;
  final TokenStorage tokenStorage;
  late final LaravelClient client;
  late final AuthManager<dynamic> auth;
  ServerInfo? serverInfo;
  ConnectionSession? session;
  LaravelEcho? echo;
  EchoOptions? echoOptions;
  String? commandChannel;
  StreamSubscription<AuthState>? authSubscription;
  int heartbeatInterval = 30;

  _Runtime(this.profile, this.tokenStorage);
}

/// Manages backend connection profiles and the live connection session
/// (CONNECTIONS.md): handshake, connect, heartbeats, server commands,
/// revocation, version policy and reconnection with exponential backoff.
///
/// ```dart
/// final manager = LaravelConnectionManager(options: const LaravelOptions(baseUrl: '…'));
/// await manager.load();
/// await manager.add(LaravelConnection.create(name: 'Staging', baseUrl: '…'), makeActive: true);
/// manager.stateStream.listen((s) => print(s.status));
/// manager.commands.listen((c) => print('Command ${c.type}'));
/// ```
class LaravelConnectionManager {
  /// Request `extra` flag marking requests issued by the manager itself.
  static const String managedRequestExtra = 'bridgeConnectionManaged';

  /// Base client options; each profile overrides base URL, prefix, app key and headers.
  final LaravelOptions options;

  /// Persistence for profiles and the active id.
  final ConnectionStore store;

  /// Global switch for building/connecting Echo from the handshake.
  final bool autoConfigureEcho;

  /// Run heartbeat / reconnect timers. Disable in tests and drive the manager
  /// manually with [heartbeat] and [connect].
  final bool enableTimers;

  /// Automatically reconnect (with backoff) after network failures.
  final bool autoReconnect;

  /// First reconnect delay.
  final Duration reconnectBaseDelay;

  /// Maximum reconnect delay.
  final Duration reconnectMaxDelay;

  /// Timeout applied to [test] probes.
  final Duration probeTimeout;

  /// Profile whose tokens use the un-namespaced keys of the root storage
  /// (keeps sessions of apps upgrading from single-backend setups).
  final String? unscopedProfileId;

  /// Called when this session is revoked remotely.
  final void Function(String? reason)? onSessionRevoked;

  /// Called when the server requires an app update.
  final void Function(LaravelUpgradeRequiredException exception)?
      onUpgradeRequired;

  /// Called for every (de-duplicated) server command.
  final void Function(BridgeCommand command)? onCommand;

  /// Optional metadata sent with `connections/connect`.
  Map<String, dynamic>? sessionMetadata;

  /// FCM token sent with connect / heartbeat requests.
  String? fcmToken;

  /// `foreground` / `background`, sent with heartbeats.
  String? appState;

  /// Persists each profile's offline queue (namespaced per profile), if set.
  final BridgeKeyValueStore? offlineQueueStore;

  /// Persists each profile's response cache (namespaced per profile), if set.
  final BridgeKeyValueStore? cacheStore;

  /// Persists each profile's last signed-in user (namespaced per profile), so
  /// a session survives an offline start. Defaults to `storage`.
  final BridgeKeyValueStore? userStore;

  /// Storage key of [profileId]'s cached user in [userStore].
  static String userStorageKeyFor(String profileId) =>
      '${AuthManager.defaultUserCacheKey}:$profileId';

  /// [OfflineQueue.maxRetries] of each profile's queue.
  final int offlineQueueMaxRetries;

  /// [CacheManager.maxEntries] of each profile's cache.
  final int cacheMaxEntries;

  final TokenStorage _rootTokenStorage;
  final TokenStorageFactory? _tokenStorageFactory;
  final AuthManagerFactory? _authFactory;
  final EchoFactory? _echoFactory;
  final DioFactory? _dioFactory;
  final HttpClientAdapterFactory? _adapterFactory;
  final DateTime Function() _clock;
  final Random _random;

  final _stateController = StreamController<LaravelConnectionState>.broadcast();
  final _connectionsController =
      StreamController<List<LaravelConnection>>.broadcast();
  final _commandsController = StreamController<BridgeCommand>.broadcast();
  final _runtimeController = StreamController<void>.broadcast();

  final List<LaravelConnection> _profiles = [];
  final Map<String, TokenStorage> _tokenStorages = {};
  final LinkedHashSet<String> _seenCommandIds = LinkedHashSet<String>();
  static const int _maxSeenCommands = 512;

  LaravelConnectionState _state = const LaravelConnectionState();
  _Runtime? _runtime;
  String? _activeId;
  String? _deviceId;
  bool _loaded = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  Future<void>? _connectFuture;

  LaravelConnectionManager({
    required this.options,
    ConnectionStore? store,
    TokenStorage? tokenStorage,
    TokenStorageFactory? tokenStorageFactory,
    AuthManagerFactory? authFactory,
    EchoFactory? echoFactory,
    DioFactory? dioFactory,
    HttpClientAdapterFactory? httpClientAdapterFactory,
    this.autoConfigureEcho = true,
    this.enableTimers = true,
    this.autoReconnect = true,
    this.reconnectBaseDelay = const Duration(seconds: 1),
    this.reconnectMaxDelay = const Duration(seconds: 60),
    this.probeTimeout = const Duration(seconds: 10),
    this.unscopedProfileId,
    this.onSessionRevoked,
    this.onUpgradeRequired,
    this.onCommand,
    this.sessionMetadata,
    this.fcmToken,
    DateTime Function()? clock,
    Random? random,
    BridgeKeyValueStore? storage,
    BridgeKeyValueStore? offlineQueueStore,
    BridgeKeyValueStore? cacheStore,
    BridgeKeyValueStore? userStore,
    this.offlineQueueMaxRetries = 5,
    this.cacheMaxEntries = 200,
  })  : store = store ??
            (storage != null
                ? DelegateConnectionStore.fromStore(storage)
                : InMemoryConnectionStore()),
        offlineQueueStore = offlineQueueStore ?? storage,
        cacheStore = cacheStore ?? storage,
        userStore = userStore ?? storage,
        _rootTokenStorage = tokenStorage ??
            (storage != null
                ? DelegateTokenStorage.fromStore(storage)
                : _fallbackTokenStorage(warn: tokenStorageFactory == null)),
        _tokenStorageFactory = tokenStorageFactory,
        _authFactory = authFactory,
        _echoFactory = echoFactory,
        _dioFactory = dioFactory,
        _adapterFactory = httpClientAdapterFactory,
        _clock = clock ?? DateTime.now,
        _random = random ?? Random();

  static bool _warnedInMemoryTokens = false;

  static TokenStorage _fallbackTokenStorage({required bool warn}) {
    if (warn) warnInMemoryTokenStorage();
    return InMemoryTokenStorage();
  }

  /// Print (once, in debug and profile builds only) why tokens kept in
  /// [InMemoryTokenStorage] log users out on every restart.
  static void warnInMemoryTokenStorage() {
    if (_warnedInMemoryTokens || !(kDebugMode || kProfileMode)) return;
    _warnedInMemoryTokens = true;
    debugPrint(
      'flutter_laravel_bridge: no tokenStorage/storage was provided, so auth '
      'tokens are kept in memory (InMemoryTokenStorage) and users are logged '
      'out every time the app restarts. Pass secure storage, e.g.\n'
      '  const secure = FlutterSecureStorage();\n'
      '  Laravel.initialize(..., storage: DelegateKeyValueStore(\n'
      '    read: (k) => secure.read(key: k),\n'
      '    write: (k, v) => secure.write(key: k, value: v),\n'
      '    delete: (k) => secure.delete(key: k)));\n'
      'or tokenStorage: DelegateTokenStorage.fromKeyValue(...). '
      'See README "Persistent & secure storage".',
    );
  }

  /// Allow [warnInMemoryTokenStorage] to print again (tests).
  @visibleForTesting
  static void resetInMemoryTokenWarning() => _warnedInMemoryTokens = false;

  // ---------------------------------------------------------------------------
  // Getters & streams
  // ---------------------------------------------------------------------------

  /// Current state snapshot.
  LaravelConnectionState get state => _state;

  /// State transitions.
  Stream<LaravelConnectionState> get stateStream => _stateController.stream;

  /// Saved profiles.
  List<LaravelConnection> get connections => List.unmodifiable(_profiles);

  /// Profile list changes.
  Stream<List<LaravelConnection>> get connectionsStream =>
      _connectionsController.stream;

  /// Server commands (heartbeat + broadcast), de-duplicated by id.
  Stream<BridgeCommand> get commands => _commandsController.stream;

  /// Fires whenever [client], [auth] or [echo] are replaced.
  Stream<void> get runtimeChanges => _runtimeController.stream;

  /// The active profile.
  LaravelConnection? get active {
    final id = _activeId;
    if (id == null) return null;
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// Id of the active profile.
  String? get activeId => _activeId;

  /// HTTP client of the active profile.
  LaravelClient? get client => _runtime?.client;

  /// Authentication manager of the active profile.
  AuthManager<dynamic>? get auth => _runtime?.auth;

  /// Echo instance of the active profile, when configured.
  LaravelEcho? get echo => _runtime?.echo;

  /// Latest handshake of the active profile.
  ServerInfo? get serverInfo => _runtime?.serverInfo;

  /// Laravel Fortify features of the active profile's server (FORTIFY.md §3),
  /// as seen by its [auth] manager. [FortifyFeatures.unavailable] before the
  /// first handshake or against servers that publish none.
  FortifyFeatures get fortify =>
      _runtime?.auth.fortify ??
      serverInfo?.fortify ??
      const FortifyFeatures.unavailable();

  /// Current server-side session.
  ConnectionSession? get session => _runtime?.session;

  /// Device id sent to the server (configured or generated).
  String? get deviceId => _deviceId ?? options.deviceId;

  /// Whether [load] has completed.
  bool get isLoaded => _loaded;

  /// Find a profile by id.
  LaravelConnection? connectionById(String id) {
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Profiles
  // ---------------------------------------------------------------------------

  /// Load profiles, the active id and the device id from the [store], and
  /// prepare (without network access) the client of the active profile.
  Future<void> load() async {
    _ensureNotDisposed();
    _profiles
      ..clear()
      ..addAll(await store.loadConnections());

    if (options.deviceId == null) {
      var deviceId = await store.loadDeviceId();
      if (deviceId == null || deviceId.isEmpty) {
        deviceId = BridgeIds.uuid();
        await store.saveDeviceId(deviceId);
      }
      _deviceId = deviceId;
    }

    var activeId = await store.loadActiveId();
    if (activeId == null || connectionById(activeId) == null) {
      final fallback = _profiles.isEmpty ? null : _profiles.first.id;
      if (fallback != activeId) await store.saveActiveId(fallback);
      activeId = fallback;
    }

    _emitConnections();
    _loaded = true;

    if (activeId != null && (_activeId != activeId || _runtime == null)) {
      _teardownRuntime();
      _activeId = activeId;
      _activate(connectionById(activeId)!);
    }
  }

  /// Add a profile. With [makeActive] it becomes the active profile (and is
  /// connected unless [connect] is false). The first profile always becomes active.
  Future<void> add(
    LaravelConnection profile, {
    bool makeActive = false,
    bool connect = true,
  }) async {
    _ensureNotDisposed();
    if (connectionById(profile.id) != null) {
      throw StateError('A connection with id "${profile.id}" already exists');
    }
    _profiles.add(profile);
    await store.saveConnections(_profiles);
    _emitConnections();

    if (makeActive) {
      if (connect) {
        await switchTo(profile.id);
      } else {
        await setActive(profile.id);
      }
    } else if (_activeId == null) {
      await setActive(profile.id);
    }
  }

  /// Replace a saved profile. When the active profile's transport (URL, prefix,
  /// app key, headers, echo) changes, the client is rebuilt and reconnected.
  Future<void> update(LaravelConnection profile) async {
    _ensureNotDisposed();
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index == -1) {
      throw StateError('Unknown connection "${profile.id}"');
    }
    final previous = _profiles[index];
    _profiles[index] = profile;
    await store.saveConnections(_profiles);
    _emitConnections();

    final rt = _runtime;
    if (profile.id != _activeId || rt == null) return;

    if (profile.differsTransportFrom(previous)) {
      final wasActive = _state.status != ConnectionStatus.idle;
      await disconnect();
      _teardownRuntime();
      _activate(profile);
      if (wasActive) await connect();
    } else {
      rt.profile = profile;
      _emit(_state.copyWith(profile: profile));
    }
  }

  /// Delete a profile: disconnects it when active and clears its tokens.
  Future<void> remove(String id) async {
    _ensureNotDisposed();
    final profile = connectionById(id);
    if (profile == null) return;

    final wasActive = id == _activeId;
    final wasConnected = wasActive && _state.status != ConnectionStatus.idle;
    final storage = _tokenStorageFor(profile);
    final removedRuntime = wasActive ? _runtime : null;

    if (wasActive) {
      await disconnect();
      _teardownRuntime();
      _activeId = null;
    }

    _profiles.removeWhere((p) => p.id == id);
    await store.saveConnections(_profiles);
    try {
      await storage.clear();
    } catch (e) {
      debugPrint('LaravelConnectionManager: failed to clear tokens of $id: $e');
    }
    _tokenStorages.remove(id);
    if (removedRuntime != null) {
      // Let queued writes land before deleting the profile's data.
      await removedRuntime.client.offlineQueue.whenPersisted();
      await removedRuntime.client.cacheManager.whenPersisted();
    }
    await _deletePersisted(offlineQueueStore, OfflineQueue.storageKeyFor(id));
    await _deletePersisted(cacheStore, CacheManager.storageKeyFor(id));
    await _deletePersisted(userStore, userStorageKeyFor(id));
    _emitConnections();

    if (wasActive) {
      if (_profiles.isNotEmpty) {
        await setActive(_profiles.first.id);
        if (wasConnected) await connect();
      } else {
        await store.saveActiveId(null);
        _emit(const LaravelConnectionState());
        _runtimeController.add(null);
      }
    }
  }

  /// Make [id] the active profile without connecting. The previous session is
  /// closed and a fresh client (with that profile's own tokens) is built.
  Future<void> setActive(String id) async {
    _ensureNotDisposed();
    final profile = connectionById(id);
    if (profile == null) throw StateError('Unknown connection "$id"');
    if (id == _activeId && _runtime != null) return;

    await disconnect();
    _teardownRuntime();
    _activeId = id;
    await store.saveActiveId(id);
    _activate(profile);
  }

  /// Switch to profile [id] and connect it.
  Future<void> switchTo(String id) async {
    if (id == _activeId &&
        _runtime != null &&
        _state.status == ConnectionStatus.connected) {
      return;
    }
    await setActive(id);
    await connect();
  }

  // ---------------------------------------------------------------------------
  // Probing
  // ---------------------------------------------------------------------------

  /// Probe [profile] (handshake + ping latency) on a throw-away client.
  /// Never touches the manager state or any stored token.
  Future<ConnectionProbeResult> test(LaravelConnection profile) async {
    final opts = _optionsFor(profile).copyWith(
      connectTimeout: probeTimeout,
      receiveTimeout: probeTimeout,
      sendTimeout: probeTimeout,
      enableLogging: false,
    );
    final client = LaravelClient(
      options: opts,
      tokenStorage: InMemoryTokenStorage(),
      customDio: _createDio(profile, opts),
      clock: _clock,
    );

    try {
      final info = await _handshake(client, profile);
      client.serverInfo = info;
      final stopwatch = Stopwatch()..start();
      await client.get<dynamic>(
        client.endpoint(BridgeEndpoints.ping),
        requestOptions: _managedOptions(),
      );
      stopwatch.stop();
      return ConnectionProbeResult(
          ok: true, latency: stopwatch.elapsed, serverInfo: info);
    } catch (e) {
      return ConnectionProbeResult(ok: false, error: _unwrap(e));
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Session lifecycle
  // ---------------------------------------------------------------------------

  /// Connect the active profile (or switch to [id] first): handshake → open
  /// session → heartbeats. Failures are reported through [state], never thrown.
  Future<void> connect([String? id]) {
    _ensureNotDisposed();
    if (id != null && id != _activeId) return switchTo(id);
    return _connectFuture ??=
        _connect().whenComplete(() => _connectFuture = null);
  }

  Future<void> _connect() async {
    var rt = _runtime;
    if (rt == null) {
      final profile = active;
      if (profile == null) {
        throw StateError(
            'No connection profile is configured. Call add() first.');
      }
      rt = _activate(profile);
    }

    final generation = _generation;
    _cancelReconnect();
    _emit(_state.copyWith(
      status: _state.reconnectAttempt > 0
          ? ConnectionStatus.reconnecting
          : ConnectionStatus.connecting,
      clearNextRetryAt: true,
    ));

    try {
      await _restorePersisted(rt);
      if (!_isCurrent(rt, generation)) return;
      final stopwatch = Stopwatch()..start();
      final info = await _handshake(rt.client, rt.profile);
      stopwatch.stop();
      if (!_isCurrent(rt, generation)) return;
      _applyServerInfo(rt, info);

      final session = await _openSession(rt);
      if (!_isCurrent(rt, generation)) return;
      await _onConnected(rt, session, latency: stopwatch.elapsed);
    } catch (e) {
      if (!_isCurrent(rt, generation)) return;
      await _handleFailure(e);
    }
  }

  /// Close the current session (best effort) and stop heartbeats / reconnects.
  /// The client stays usable for plain requests.
  Future<void> disconnect() async {
    _generation++;
    _stopTimers();
    final rt = _runtime;
    final session = rt?.session;
    if (rt != null) {
      _leaveCommandChannel(rt);
      rt.session = null;
      await rt.echo?.disconnect();
    }
    _emit(_state.copyWith(
      status: ConnectionStatus.idle,
      clearSession: true,
      clearError: true,
      reconnectAttempt: 0,
      clearNextRetryAt: true,
    ));

    if (rt != null && session != null) {
      try {
        await rt.client
            .post<dynamic>(
              rt.client.endpoint(BridgeEndpoints.connectionsDisconnect,
                  params: {'connection': session.id}),
              requestOptions: _managedOptions(connectionId: session.id),
            )
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint(
            'LaravelConnectionManager: disconnect request failed: ${_unwrap(e)}');
      }
    }
  }

  /// Send a heartbeat now. Returns the newly delivered (de-duplicated) commands.
  /// Errors are reported through [state], never thrown.
  Future<List<BridgeCommand>> heartbeat() async {
    final rt = _runtime;
    final session = rt?.session;
    if (rt == null || session == null) return const [];
    final generation = _generation;

    try {
      final stopwatch = Stopwatch()..start();
      final response = await rt.client.post<Map<String, dynamic>>(
        rt.client.endpoint(BridgeEndpoints.connectionsHeartbeat,
            params: {'connection': session.id}),
        data: {
          if (appState != null) 'state': appState,
          if (fcmToken != null) 'fcm_token': fcmToken,
        },
        requestOptions: _managedOptions(),
      );
      stopwatch.stop();
      if (!_isCurrent(rt, generation) || rt.session?.id != session.id)
        return const [];

      final data = response.data ?? const <String, dynamic>{};
      final rawConnection = data['connection'];
      if (rawConnection is Map) {
        rt.session = ConnectionSession.fromJson(parseBridgeMap(rawConnection));
      }

      final interval = parseBridgeInt(data['heartbeat_interval']);
      final wasConnected = _state.status == ConnectionStatus.connected;
      if (interval != null &&
          interval > 0 &&
          interval != rt.heartbeatInterval) {
        rt.heartbeatInterval = interval;
        _startHeartbeat(rt);
      } else if (!wasConnected) {
        _startHeartbeat(rt);
      }

      _emit(_state.copyWith(
        status: ConnectionStatus.connected,
        session: rt.session,
        latency: stopwatch.elapsed,
        lastHeartbeatAt: _clock(),
        reconnectAttempt: 0,
        clearError: true,
        clearNextRetryAt: true,
      ));
      if (!wasConnected) _flushOfflineQueue(rt);

      final delivered = <BridgeCommand>[];
      final rawCommands = data['commands'];
      if (rawCommands is List) {
        for (final raw in rawCommands.whereType<Map>()) {
          final command = BridgeCommand.fromJson(parseBridgeMap(raw));
          if (await _dispatchCommand(rt, command)) delivered.add(command);
        }
      }
      return delivered;
    } catch (e) {
      if (!_isCurrent(rt, generation)) return const [];
      final error = _unwrap(e);
      if (error is LaravelConnectionNotFoundException) {
        // The server forgot this session (pruned / DB reset): open a new one silently.
        await _reopenSession(rt, generation);
      } else {
        await _handleFailure(error);
      }
      return const [];
    }
  }

  /// Measure the round-trip latency to the active backend.
  Future<Duration> ping() async {
    final rt = _requireRuntime();
    final stopwatch = Stopwatch()..start();
    try {
      await rt.client.get<dynamic>(
        rt.client.endpoint(BridgeEndpoints.ping),
        requestOptions: _managedOptions(),
      );
    } catch (e) {
      final error = _unwrap(e);
      if (error is LaravelNetworkException &&
          _state.status == ConnectionStatus.connected) {
        _goOffline(error);
      }
      throw error;
    }
    stopwatch.stop();
    _emit(_state.copyWith(latency: stopwatch.elapsed));

    // The server is reachable again: do not wait for the backoff timer.
    if (_state.status == ConnectionStatus.offline ||
        _state.status == ConnectionStatus.reconnecting) {
      unawaited(connect());
    }
    return stopwatch.elapsed;
  }

  /// Re-run the handshake and update [serverInfo] (and Echo configuration).
  Future<ServerInfo> refreshServerInfo() async {
    final rt = _requireRuntime();
    final info = await _handshake(rt.client, rt.profile);
    if (rt != _runtime) return info;
    _applyServerInfo(rt, info);
    _emit(_state.copyWith(serverInfo: info));
    if (rt.session != null) await _configureEcho(rt);
    return info;
  }

  // ---------------------------------------------------------------------------
  // Remote sessions (bearer)
  // ---------------------------------------------------------------------------

  /// Sessions of the authenticated user, newest activity first.
  Future<List<ConnectionSession>> sessions({String? status}) async {
    final rt = _requireRuntime();
    final response = await rt.client.get<Map<String, dynamic>>(
      rt.client.endpoint(BridgeEndpoints.connectionsIndex),
      queryParameters: {if (status != null) 'status': status},
    );
    final raw = response.data?['connections'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => ConnectionSession.fromJson(parseBridgeMap(e)))
        .toList(growable: false);
  }

  /// Revoke one of the user's sessions. Revoking the current session signs
  /// this device out.
  Future<ConnectionSession?> revokeSession(String id) async {
    final rt = _requireRuntime();
    final response = await rt.client.delete<Map<String, dynamic>>(
      rt.client.endpoint(BridgeEndpoints.connectionsRevoke,
          params: {'connection': id}),
    );
    final raw = response.data?['connection'];
    final revoked =
        raw is Map ? ConnectionSession.fromJson(parseBridgeMap(raw)) : null;
    if (rt == _runtime && rt.session?.id == id) {
      await _handleRevoked(rt, 'revoked_by_user');
    }
    return revoked;
  }

  /// Revoke every other active session of the user. Returns how many were revoked.
  Future<int> revokeOtherSessions() async {
    final rt = _requireRuntime();
    final response = await rt.client.delete<Map<String, dynamic>>(
      rt.client.endpoint(BridgeEndpoints.connectionsRevokeOthers),
    );
    return parseBridgeInt(response.data?['revoked']) ?? 0;
  }

  // ---------------------------------------------------------------------------
  // Internals: runtime
  // ---------------------------------------------------------------------------

  _Runtime _activate(LaravelConnection profile) {
    final opts = _optionsFor(profile);
    final storage = _tokenStorageFor(profile);
    final rt = _Runtime(profile, storage);
    _generation++;

    rt.client = LaravelClient(
      options: opts,
      tokenStorage: storage,
      customDio: _createDio(profile, opts),
      onRefreshToken: () => rt.auth.refreshToken(),
      onSessionExpired: () => unawaited(rt.auth.expireSession()),
      connectionIdProvider: () => rt.session?.id,
      onException: (exception, request) =>
          _onClientException(rt, exception, request),
      clock: _clock,
      offlineQueue: OfflineQueue(
        store: offlineQueueStore,
        storageKey: OfflineQueue.storageKeyFor(profile.id),
        maxRetries: offlineQueueMaxRetries,
      ),
      cacheManager: CacheManager(
        store: cacheStore,
        storageKey: CacheManager.storageKeyFor(profile.id),
        maxEntries: cacheMaxEntries,
        clock: _clock,
      ),
    );
    // Start loading the persisted queue / cache right away.
    unawaited(_restorePersisted(rt));
    rt.auth = _authFactory?.call(rt.client, storage, profile) ??
        AuthManager<Map<String, dynamic>>(
          client: rt.client,
          tokenStorage: storage,
          userParser: (json) => json,
          proactiveRefresh: enableTimers,
          clock: _clock,
        );
    final users = userStore;
    if (users != null) {
      rt.auth.attachUserCache(users, key: userStorageKeyFor(profile.id));
    }
    rt.authSubscription = rt.auth.stateStream.listen((authState) {
      if (rt != _runtime) return;
      _syncCommandChannel(rt);
      if (authState is Authenticated &&
          _state.status == ConnectionStatus.revoked) {
        // Signed in again after a revocation: open a fresh session.
        unawaited(connect());
      }
    });

    if (profile.echoOptions != null) {
      rt.echoOptions = profile.echoOptions;
      rt.echo = _createEcho(profile.echoOptions!, rt.client);
    }

    _runtime = rt;
    _emit(LaravelConnectionState(profile: profile));
    _runtimeController.add(null);
    return rt;
  }

  /// Load the profile's persisted offline queue and cache (idempotent).
  Future<void> _restorePersisted(_Runtime rt) async {
    try {
      await Future.wait([
        rt.client.offlineQueue.restore(),
        rt.client.cacheManager.restore(),
      ]);
    } catch (e) {
      debugPrint('LaravelConnectionManager: restoring offline data failed: $e');
    }
  }

  Future<void> _deletePersisted(BridgeKeyValueStore? store, String key) async {
    if (store == null) return;
    try {
      await store.delete(key);
    } catch (e) {
      debugPrint('LaravelConnectionManager: failed to delete $key: $e');
    }
  }

  void _teardownRuntime() {
    final rt = _runtime;
    if (rt == null) return;
    _runtime = null;
    _generation++;
    _stopTimers();
    rt.authSubscription?.cancel();
    rt.echo?.dispose();
    rt.auth.dispose();
    rt.client.close();
  }

  LaravelOptions _optionsFor(LaravelConnection profile) {
    final samePrefix = profile.normalizedPrefix == options.normalizedPrefix;
    final base = samePrefix
        ? options
        : LaravelOptions(
            baseUrl: options.baseUrl,
            connectTimeout: options.connectTimeout,
            receiveTimeout: options.receiveTimeout,
            sendTimeout: options.sendTimeout,
            headers: options.headers,
            enableLogging: options.enableLogging,
            deviceId: options.deviceId,
            appVersion: options.appVersion,
            platform: options.platform,
            deviceName: options.deviceName,
            osVersion: options.osVersion,
            maxRetries: options.maxRetries,
            retryBaseDelay: options.retryBaseDelay,
          );
    return base.copyWith(
      baseUrl: profile.baseUrl,
      prefix: profile.normalizedPrefix,
      appKey: profile.appKey,
      clearAppKey: profile.appKey == null || profile.appKey!.isEmpty,
      headers: {...options.headers, ...profile.headers},
      deviceId: deviceId,
      platform: options.platform ?? detectPlatform(),
    );
  }

  Dio _createDio(LaravelConnection profile, LaravelOptions opts) {
    final baseOptions = LaravelClient.buildBaseOptions(opts);
    final dio = _dioFactory?.call(baseOptions, profile) ?? Dio(baseOptions);
    final adapter = _adapterFactory?.call(profile);
    if (adapter != null) dio.httpClientAdapter = adapter;
    return dio;
  }

  LaravelEcho _createEcho(EchoOptions echoOptions, LaravelClient client) {
    return _echoFactory?.call(echoOptions, client) ??
        LaravelEcho(options: echoOptions, client: client);
  }

  TokenStorage _tokenStorageFor(LaravelConnection profile) {
    return _tokenStorages.putIfAbsent(profile.id, () {
      final factory = _tokenStorageFactory;
      if (factory != null) return factory(profile);
      if (profile.id == unscopedProfileId) return _rootTokenStorage;
      try {
        return _rootTokenStorage.scoped(profile.id);
      } on UnsupportedError {
        debugPrint(
          'LaravelConnectionManager: ${_rootTokenStorage.runtimeType} cannot be scoped; '
          'tokens of "${profile.id}" are kept in memory only. Provide a tokenStorageFactory.',
        );
        return InMemoryTokenStorage();
      }
    });
  }

  /// Token storage used by profile [id] (for inspection / migration).
  TokenStorage tokenStorageOf(String id) {
    final profile = connectionById(id);
    if (profile == null) throw StateError('Unknown connection "$id"');
    return _tokenStorageFor(profile);
  }

  // ---------------------------------------------------------------------------
  // Internals: protocol
  // ---------------------------------------------------------------------------

  Options _managedOptions({String? connectionId}) => Options(
        extra: {managedRequestExtra: true},
        headers: {
          if (connectionId != null) 'X-Flutter-Connection-Id': connectionId
        },
      );

  Future<ServerInfo> _handshake(
      LaravelClient client, LaravelConnection profile) async {
    final path = client.serverInfo?.endpoint(BridgeEndpoints.handshake) ??
        BridgeEndpoints.path(BridgeEndpoints.handshake,
            prefix: profile.normalizedPrefix);
    final response = await client.get<dynamic>(
      path,
      requestOptions: Options(extra: {
        managedRequestExtra: true,
        AuthInterceptor.skipAuthRefreshExtra: true,
      }),
    );
    final data = response.data;
    if (data is! Map || (data['bridge'] == null && data['server'] == null)) {
      throw const LaravelException(
        message:
            'The server did not return a Laravel Flutter Bridge handshake. '
            'Check the base URL and prefix.',
      );
    }
    return ServerInfo.fromJson(parseBridgeMap(data),
        fallbackPrefix: profile.normalizedPrefix);
  }

  void _applyServerInfo(_Runtime rt, ServerInfo info) {
    rt.serverInfo = info;
    rt.client.serverInfo = info;
    if (info.heartbeatInterval > 0)
      rt.heartbeatInterval = info.heartbeatInterval;
  }

  Future<ConnectionSession> _openSession(_Runtime rt) async {
    final opts = rt.client.options;
    final response = await rt.client.post<Map<String, dynamic>>(
      rt.client.endpoint(BridgeEndpoints.connectionsConnect),
      data: {
        'device_id': deviceId,
        'platform': opts.platform ?? detectPlatform(),
        if (opts.appVersion != null) 'app_version': opts.appVersion,
        if (opts.deviceName != null) 'device_name': opts.deviceName,
        if (opts.osVersion != null) 'os_version': opts.osVersion,
        if (fcmToken != null) 'fcm_token': fcmToken,
        'bridge_version': kBridgeVersion,
        if (sessionMetadata != null) 'metadata': sessionMetadata,
      },
      requestOptions: _managedOptions(),
    );
    final data = response.data ?? const <String, dynamic>{};
    final rawConnection = data['connection'];
    if (rawConnection is! Map) {
      throw const LaravelException(
          message: 'The server did not return a connection session.');
    }
    final interval = parseBridgeInt(data['heartbeat_interval']);
    if (interval != null && interval > 0) rt.heartbeatInterval = interval;
    return ConnectionSession.fromJson(parseBridgeMap(rawConnection));
  }

  Future<void> _onConnected(_Runtime rt, ConnectionSession session,
      {Duration? latency}) async {
    rt.session = session;
    final profile = _touchLastConnected(rt);
    _emit(_state.copyWith(
      status: ConnectionStatus.connected,
      profile: profile,
      serverInfo: rt.serverInfo,
      session: session,
      latency: latency,
      lastHeartbeatAt: _clock(),
      reconnectAttempt: 0,
      clearError: true,
      clearNextRetryAt: true,
    ));
    _startHeartbeat(rt);
    _flushOfflineQueue(rt);
    await _configureEcho(rt);
    await _restoreSession(rt);
  }

  Future<void> _reopenSession(_Runtime rt, int generation) async {
    rt.session = null;
    _leaveCommandChannel(rt);
    try {
      final session = await _openSession(rt);
      if (!_isCurrent(rt, generation)) return;
      await _onConnected(rt, session, latency: _state.latency);
    } catch (e) {
      if (!_isCurrent(rt, generation)) return;
      await _handleFailure(e);
    }
  }

  Future<void> _restoreSession(_Runtime rt) async {
    if (rt.auth.isAuthenticated) return;
    try {
      final token = await rt.tokenStorage.getAccessToken();
      if (token == null || token.isEmpty) return;
      await rt.auth.initialize();
    } catch (e) {
      debugPrint('LaravelConnectionManager: session restore failed: $e');
    }
  }

  LaravelConnection _touchLastConnected(_Runtime rt) {
    final index = _profiles.indexWhere((p) => p.id == rt.profile.id);
    final updated = rt.profile.copyWith(lastConnectedAt: _clock());
    rt.profile = updated;
    if (index != -1) {
      _profiles[index] = updated;
      _emitConnections();
      unawaited(
          store.saveConnections(List.of(_profiles)).catchError((Object e) {
        debugPrint('LaravelConnectionManager: failed to persist profiles: $e');
      }));
    }
    return updated;
  }

  void _flushOfflineQueue(_Runtime rt) {
    if (!rt.client.offlineQueue.hasPending) return;
    unawaited(rt.client.flushOfflineQueue().then((count) {
      if (count > 0)
        debugPrint(
            'LaravelConnectionManager: replayed $count offline mutation(s)');
    }).catchError((Object e) {
      debugPrint('LaravelConnectionManager: offline queue flush failed: $e');
    }));
  }

  // ---------------------------------------------------------------------------
  // Internals: commands & echo
  // ---------------------------------------------------------------------------

  /// Returns true when the command was new (not a duplicate).
  Future<bool> _dispatchCommand(_Runtime rt, BridgeCommand command) async {
    if (_seenCommandIds.contains(command.id)) return false;
    _seenCommandIds.add(command.id);
    while (_seenCommandIds.length > _maxSeenCommands) {
      _seenCommandIds.remove(_seenCommandIds.first);
    }

    if (!_commandsController.isClosed) _commandsController.add(command);
    try {
      onCommand?.call(command);
    } catch (e) {
      debugPrint('LaravelConnectionManager: onCommand threw: $e');
    }

    if (rt != _runtime) return true;
    switch (command.type) {
      case BridgeCommandType.revoked:
        await _handleRevoked(rt, command.reason);
        break;
      case BridgeCommandType.logout:
        await rt.auth.clearSession();
        break;
      case BridgeCommandType.refreshConfig:
        try {
          await refreshServerInfo();
        } catch (e) {
          debugPrint(
              'LaravelConnectionManager: refresh_config failed: ${_unwrap(e)}');
        }
        break;
      case BridgeCommandType.forceUpdate:
        final payload = command.payload;
        _handleUpgrade(LaravelUpgradeRequiredException(
          message: payload['message']?.toString() ??
              'A newer version of the app is required.',
          statusCode: null,
          minVersion: payload['min_version']?.toString(),
          latestVersion: payload['latest_version']?.toString(),
          updateUrl: payload['update_url']?.toString() ??
              rt.serverInfo?.app?.updateUrl,
          currentVersion: options.appVersion,
        ));
        break;
    }
    return true;
  }

  Future<void> _configureEcho(_Runtime rt) async {
    final info = rt.serverInfo;
    final serverBroadcasting = info?.supportsBroadcasting ?? false;
    final autoConfigure = autoConfigureEcho && rt.profile.autoConfigureEcho;

    final desired = rt.profile.echoOptions ??
        (autoConfigure && serverBroadcasting
            ? info!.broadcasting!.toEchoOptions()
            : null);

    if (desired != null && (rt.echo == null || rt.echoOptions != desired)) {
      rt.commandChannel = null;
      rt.echo?.dispose();
      rt.echoOptions = desired;
      rt.echo = _createEcho(desired, rt.client);
      _runtimeController.add(null);
    }

    if (rt.echo != null && autoConfigure && serverBroadcasting) {
      await rt.echo!.connect();
    }
    _syncCommandChannel(rt);
  }

  String _commandChannelName(_Runtime rt, String connectionId) {
    final config = rt.serverInfo?.broadcasting;
    if (config != null) return config.connectionChannelFor(connectionId);
    return 'private-flutter.connections.$connectionId';
  }

  void _syncCommandChannel(_Runtime rt) {
    final echo = rt.echo;
    final session = rt.session;
    final wanted = (echo != null && session != null && rt.auth.isAuthenticated)
        ? _commandChannelName(rt, session.id)
        : null;
    if (wanted == rt.commandChannel) return;

    _leaveCommandChannel(rt);
    if (wanted == null || echo == null) return;

    rt.commandChannel = wanted;
    echo.private(wanted)
      ..listen('BridgeCommand', (data) => _onBroadcastCommand(rt, data))
      ..listen('ConnectionRevoked', (data) => _onBroadcastRevoked(rt, data));
  }

  void _leaveCommandChannel(_Runtime rt) {
    final name = rt.commandChannel;
    rt.commandChannel = null;
    if (name != null) rt.echo?.leave(name);
  }

  void _onBroadcastCommand(_Runtime rt, dynamic data) {
    if (rt != _runtime) return;
    var map = parseBridgeMap(data);
    if (map['command'] is Map) map = parseBridgeMap(map['command']);
    if (map['id'] == null || map['type'] == null) return;
    unawaited(_dispatchCommand(
      rt,
      BridgeCommand.fromJson(map, source: BridgeCommandSource.broadcast),
    ));
  }

  void _onBroadcastRevoked(_Runtime rt, dynamic data) {
    if (rt != _runtime) return;
    final map = parseBridgeMap(data);
    final connection = parseBridgeMap(map['connection']);
    final id = (connection['id'] ?? map['connection_id'])?.toString();
    if (id != null && id != rt.session?.id) return;
    unawaited(_handleRevoked(rt, map['reason']?.toString()));
  }

  // ---------------------------------------------------------------------------
  // Internals: error handling & timers
  // ---------------------------------------------------------------------------

  void _onClientException(
      _Runtime rt, LaravelException exception, RequestOptions request) {
    if (rt != _runtime || request.extra[managedRequestExtra] == true) return;
    // Defer: we are inside the Dio interceptor chain.
    scheduleMicrotask(() {
      if (rt != _runtime || _disposed) return;
      if (exception is LaravelConnectionRevokedException) {
        unawaited(_handleRevoked(rt, exception.reason, exception));
      } else if (exception is LaravelUpgradeRequiredException) {
        _handleUpgrade(exception);
      } else if (exception is LaravelAppKeyException) {
        _fail(exception);
      } else if (exception is LaravelNetworkException &&
          _state.status == ConnectionStatus.connected) {
        _goOffline(exception);
      }
    });
  }

  Future<void> _handleFailure(Object e) async {
    final rt = _runtime;
    final error = _unwrap(e);
    if (error is LaravelConnectionRevokedException) {
      if (rt != null) await _handleRevoked(rt, error.reason, error);
    } else if (error is LaravelUpgradeRequiredException) {
      _handleUpgrade(error);
    } else if (error is LaravelAppKeyException) {
      _fail(error);
    } else if (error is LaravelRateLimitException) {
      _goOffline(error, minDelay: error.retryAfter);
    } else if (error is LaravelMaintenanceException) {
      _goOffline(error, minDelay: error.retryAfter);
    } else if (error is LaravelNetworkException ||
        error is LaravelServerException ||
        error is LaravelAuthenticationException ||
        error is TimeoutException) {
      _goOffline(error);
    } else {
      _fail(error);
    }
  }

  Future<void> _handleRevoked(_Runtime rt, String? reason,
      [LaravelConnectionRevokedException? error]) async {
    if (rt != _runtime) return;
    final alreadyRevoked =
        _state.status == ConnectionStatus.revoked && rt.session == null;
    _generation++;
    _stopTimers();
    _leaveCommandChannel(rt);
    rt.session = null;
    // Drop credentials before announcing the state so listeners never observe
    // a revoked connection that still looks authenticated.
    await rt.auth.clearSession();
    if (rt != _runtime) return;
    _emit(_state.copyWith(
      status: ConnectionStatus.revoked,
      clearSession: true,
      error: error ?? LaravelConnectionRevokedException(reason: reason),
      reconnectAttempt: 0,
      clearNextRetryAt: true,
    ));
    if (alreadyRevoked) return;
    try {
      onSessionRevoked?.call(reason);
    } catch (e) {
      debugPrint('LaravelConnectionManager: onSessionRevoked threw: $e');
    }
  }

  void _handleUpgrade(LaravelUpgradeRequiredException error) {
    final already = _state.status == ConnectionStatus.upgradeRequired;
    _generation++;
    _stopTimers();
    final exception = error.currentVersion == null && options.appVersion != null
        ? LaravelUpgradeRequiredException(
            message: error.message,
            statusCode: error.statusCode,
            responseData: error.responseData,
            minVersion: error.minVersion,
            latestVersion: error.latestVersion,
            updateUrl: error.updateUrl ?? _runtime?.serverInfo?.app?.updateUrl,
            currentVersion: options.appVersion,
          )
        : error;
    _emit(_state.copyWith(
      status: ConnectionStatus.upgradeRequired,
      error: exception,
      reconnectAttempt: 0,
      clearNextRetryAt: true,
    ));
    if (already) return;
    try {
      onUpgradeRequired?.call(exception);
    } catch (e) {
      debugPrint('LaravelConnectionManager: onUpgradeRequired threw: $e');
    }
  }

  void _fail(Object error) {
    _stopTimers();
    _emit(_state.copyWith(
      status: ConnectionStatus.failed,
      error: error,
      reconnectAttempt: 0,
      clearNextRetryAt: true,
    ));
  }

  void _goOffline(Object error, {Duration? minDelay}) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final attempt = _state.reconnectAttempt;
    var delay = backoffDelay(
      attempt,
      base: reconnectBaseDelay,
      max: reconnectMaxDelay,
      random: _random,
    );
    if (minDelay != null && minDelay > delay) delay = minDelay;

    _emit(_state.copyWith(
      status: ConnectionStatus.offline,
      error: error,
      reconnectAttempt: attempt + 1,
      nextRetryAt: autoReconnect ? _clock().add(delay) : null,
      clearNextRetryAt: !autoReconnect,
    ));

    _cancelReconnect();
    if (autoReconnect && enableTimers) {
      final generation = _generation;
      _reconnectTimer = Timer(delay, () {
        _reconnectTimer = null;
        if (generation != _generation || _disposed) return;
        unawaited(connect());
      });
    }
  }

  /// Exponential backoff delay for reconnect [attempt] (0-based):
  /// `base * 2^attempt`, capped at [max], with ±[jitter] randomisation.
  static Duration backoffDelay(
    int attempt, {
    Duration base = const Duration(seconds: 1),
    Duration max = const Duration(seconds: 60),
    Random? random,
    double jitter = 0.2,
  }) {
    final capMs = max.inMilliseconds.toDouble();
    final exp = base.inMilliseconds * pow(2, attempt.clamp(0, 30));
    final capped = exp.toDouble() > capMs ? capMs : exp.toDouble();
    final factor = 1 - jitter + (random ?? Random()).nextDouble() * jitter * 2;
    final value = capped * factor;
    return Duration(milliseconds: (value > capMs ? capMs : value).round());
  }

  void _startHeartbeat(_Runtime rt) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (!enableTimers) return;
    final seconds = rt.heartbeatInterval > 0 ? rt.heartbeatInterval : 30;
    _heartbeatTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (rt != _runtime || _disposed) return;
      unawaited(heartbeat());
    });
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _stopTimers() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _cancelReconnect();
  }

  bool _isCurrent(_Runtime rt, int generation) =>
      !_disposed && rt == _runtime && generation == _generation;

  _Runtime _requireRuntime() {
    final rt = _runtime;
    if (rt == null) {
      throw StateError(
          'No active connection. Call load() and add() a connection first.');
    }
    return rt;
  }

  static Object _unwrap(Object e) {
    if (e is DioException && e.error is LaravelException) return e.error!;
    return e;
  }

  void _emit(LaravelConnectionState state) {
    _state = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }

  void _emitConnections() {
    if (!_connectionsController.isClosed) {
      _connectionsController.add(List.unmodifiable(_profiles));
    }
  }

  void _ensureNotDisposed() {
    if (_disposed)
      throw StateError('LaravelConnectionManager has been disposed');
  }

  /// Bridge platform name of the running device.
  static String detectPlatform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  /// Stop timers, close the session (best effort) and release every resource.
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await disconnect();
    } catch (_) {
      // Ignore: best effort.
    }
    _disposed = true;
    _teardownRuntime();
    await _stateController.close();
    await _connectionsController.close();
    await _commandsController.close();
    await _runtimeController.close();
  }
}
