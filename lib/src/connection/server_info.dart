import '../echo/echo_options.dart';
import 'bridge_endpoints.dart';
import 'bridge_ids.dart';

/// `server` block of the handshake: identity of the Laravel installation.
class ServerDetails {
  final String? name;
  final String? environment;
  final String? url;
  final String? timezone;
  final String? locale;
  final DateTime? time;

  const ServerDetails({
    this.name,
    this.environment,
    this.url,
    this.timezone,
    this.locale,
    this.time,
  });

  factory ServerDetails.fromJson(Map<String, dynamic> json) => ServerDetails(
        name: json['name'] as String?,
        environment: json['environment'] as String?,
        url: json['url'] as String?,
        timezone: json['timezone'] as String?,
        locale: json['locale'] as String?,
        time: parseBridgeDate(json['time']),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'environment': environment,
        'url': url,
        'timezone': timezone,
        'locale': locale,
        'time': time?.toIso8601String(),
      };
}

/// `bridge` block of the handshake: server package & protocol versions.
class BridgeDetails {
  /// Server bridge package version (e.g. `2.0.0`).
  final String? version;

  /// API version advertised in response metadata (e.g. `v1`).
  final String? apiVersion;

  /// Route prefix the bridge is mounted under (e.g. `api/flutter`).
  final String prefix;

  const BridgeDetails({
    this.version,
    this.apiVersion,
    this.prefix = BridgeEndpoints.defaultPrefix,
  });

  factory BridgeDetails.fromJson(
    Map<String, dynamic> json, {
    String fallbackPrefix = BridgeEndpoints.defaultPrefix,
  }) =>
      BridgeDetails(
        version: json['version']?.toString(),
        apiVersion: json['api_version']?.toString(),
        prefix: BridgeEndpoints.normalizePrefix(
            json['prefix'] as String? ?? fallbackPrefix),
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'api_version': apiVersion,
        'prefix': prefix,
      };
}

/// `app` block of the handshake: the registered client application and its version policy.
class AppInfo {
  final String? key;
  final String? name;

  /// `active` or `suspended`.
  final String status;
  final String? minVersion;
  final String? latestVersion;
  final String? updateUrl;

  /// Allowed platforms; `null` means every platform is allowed.
  final List<String>? platforms;
  final Map<String, dynamic> settings;

  const AppInfo({
    this.key,
    this.name,
    this.status = 'active',
    this.minVersion,
    this.latestVersion,
    this.updateUrl,
    this.platforms,
    this.settings = const {},
  });

  /// Whether the app is currently allowed to use the API.
  bool get isActive => status == 'active';

  /// Whether [currentVersion] is below the advertised minimum version.
  bool requiresUpdate(String? currentVersion) {
    if (currentVersion == null || minVersion == null) return false;
    return compareBridgeVersions(currentVersion, minVersion!) < 0;
  }

  /// Whether a newer (optional) version than [currentVersion] is available.
  bool hasUpdate(String? currentVersion) {
    if (currentVersion == null || latestVersion == null) return false;
    return compareBridgeVersions(currentVersion, latestVersion!) < 0;
  }

  factory AppInfo.fromJson(Map<String, dynamic> json) => AppInfo(
        key: json['key'] as String?,
        name: json['name'] as String?,
        status: json['status'] as String? ?? 'active',
        minVersion: json['min_version']?.toString(),
        latestVersion: json['latest_version']?.toString(),
        updateUrl: json['update_url'] as String?,
        platforms:
            (json['platforms'] as List?)?.map((e) => e.toString()).toList(),
        settings: parseBridgeMap(json['settings']),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'status': status,
        'min_version': minVersion,
        'latest_version': latestVersion,
        'update_url': updateUrl,
        'platforms': platforms,
        'settings': settings,
      };
}

/// `features` block of the handshake: which bridge subsystems are enabled on the server.
class ServerFeatures {
  final bool auth;
  final bool registration;
  final bool socialAuth;
  final bool twoFactor;
  final bool devices;
  final bool broadcasting;
  final bool connections;
  final bool push;

  /// Raw map, including any feature flags unknown to this client version.
  final Map<String, dynamic> raw;

  const ServerFeatures({
    this.auth = true,
    this.registration = true,
    this.socialAuth = false,
    this.twoFactor = false,
    this.devices = true,
    this.broadcasting = false,
    this.connections = true,
    this.push = false,
    this.raw = const {},
  });

  /// Check an arbitrary feature flag by its server name.
  bool has(String feature) => parseBridgeBool(raw[feature]) ?? false;

  factory ServerFeatures.fromJson(Map<String, dynamic> json) => ServerFeatures(
        auth: parseBridgeBool(json['auth']) ?? true,
        registration: parseBridgeBool(json['registration']) ?? true,
        socialAuth: parseBridgeBool(json['social_auth']) ?? false,
        twoFactor: parseBridgeBool(json['two_factor']) ?? false,
        devices: parseBridgeBool(json['devices']) ?? true,
        broadcasting: parseBridgeBool(json['broadcasting']) ?? false,
        connections: parseBridgeBool(json['connections']) ?? true,
        push: parseBridgeBool(json['push']) ?? false,
        raw: Map<String, dynamic>.unmodifiable(json),
      );

  Map<String, dynamic> toJson() => {
        ...raw,
        'auth': auth,
        'registration': registration,
        'social_auth': socialAuth,
        'two_factor': twoFactor,
        'devices': devices,
        'broadcasting': broadcasting,
        'connections': connections,
        'push': push,
      };
}

/// `broadcasting` block of the handshake: Reverb / Pusher connection parameters.
class BroadcastingConfig {
  /// `reverb` or `pusher`.
  final String driver;
  final String key;
  final String? host;
  final int? port;

  /// `http`/`https` (or `ws`/`wss`).
  final String scheme;
  final String? cluster;
  final String authEndpoint;

  /// Template of the per-session command channel, e.g. `private-flutter.connections.{connection}`.
  final String connectionChannel;

  /// Template of the per-user channel, e.g. `private-users.{user}`.
  final String? userChannel;

  const BroadcastingConfig({
    required this.driver,
    required this.key,
    this.host,
    this.port,
    this.scheme = 'https',
    this.cluster,
    this.authEndpoint = 'api/flutter/broadcasting/auth',
    this.connectionChannel = 'private-flutter.connections.{connection}',
    this.userChannel,
  });

  /// Whether the socket should use TLS.
  bool get encrypted => scheme == 'https' || scheme == 'wss';

  /// Resolve [connectionChannel] for a connection session id.
  String connectionChannelFor(String connectionId) =>
      BridgeEndpoints.resolve(connectionChannel, {'connection': connectionId});

  /// Resolve [userChannel] for a user id (null when the server advertises none).
  String? userChannelFor(Object userId) => userChannel == null
      ? null
      : BridgeEndpoints.resolve(userChannel!, {'user': userId});

  /// Build [EchoOptions] for [LaravelEcho] from this server configuration.
  ///
  /// `scheme` maps to `encrypted`; `port` is used for both `wsPort` and `wssPort`
  /// (falling back to 8080 / 443); hosted Pusher without a host uses the cluster host.
  EchoOptions toEchoOptions(
      {Duration activityTimeout = const Duration(seconds: 30)}) {
    final hasHost = host != null && host!.isNotEmpty;
    return EchoOptions(
      appKey: key,
      wsHost: hasHost
          ? host!
          : (cluster != null ? 'ws-$cluster.pusher.com' : 'localhost'),
      wsPort: port ?? (encrypted ? 443 : 8080),
      wssPort: port ?? 443,
      encrypted: encrypted,
      cluster: hasHost ? null : cluster,
      authEndpoint: authEndpoint,
      activityTimeout: activityTimeout,
    );
  }

  factory BroadcastingConfig.fromJson(Map<String, dynamic> json,
      {String? prefix}) {
    return BroadcastingConfig(
      driver: json['driver']?.toString() ?? 'reverb',
      key: json['key']?.toString() ?? '',
      host: json['host'] as String?,
      port: parseBridgeInt(json['port']),
      scheme: json['scheme'] as String? ?? 'https',
      cluster: json['cluster'] as String?,
      authEndpoint: json['auth_endpoint'] as String? ??
          BridgeEndpoints.path(
            BridgeEndpoints.broadcastingAuth,
            prefix: prefix ?? BridgeEndpoints.defaultPrefix,
          ),
      connectionChannel: json['connection_channel'] as String? ??
          'private-flutter.connections.{connection}',
      userChannel: json['user_channel'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'driver': driver,
        'key': key,
        'host': host,
        'port': port,
        'scheme': scheme,
        'cluster': cluster,
        'auth_endpoint': authEndpoint,
        'connection_channel': connectionChannel,
        'user_channel': userChannel,
      };
}

/// Parsed `GET handshake` payload (CONNECTIONS.md §4.1).
class ServerInfo {
  final ServerDetails server;
  final BridgeDetails bridge;

  /// Registered app; `null` when no app key was sent.
  final AppInfo? app;
  final ServerFeatures features;

  /// Endpoint table as advertised by the server (key → path template).
  final Map<String, String> endpoints;

  /// Broadcasting parameters; `null` when broadcasting is disabled.
  final BroadcastingConfig? broadcasting;

  /// Recommended seconds between heartbeats.
  final int heartbeatInterval;

  /// Seconds without heartbeat after which the server considers the session offline.
  final int timeout;

  /// Remote configuration (server config merged with app settings).
  final Map<String, dynamic> remoteConfig;

  /// The full raw handshake payload.
  final Map<String, dynamic> raw;

  const ServerInfo({
    this.server = const ServerDetails(),
    this.bridge = const BridgeDetails(),
    this.app,
    this.features = const ServerFeatures(),
    this.endpoints = const {},
    this.broadcasting,
    this.heartbeatInterval = 30,
    this.timeout = 90,
    this.remoteConfig = const {},
    this.raw = const {},
  });

  /// Bridge route prefix of this server.
  String get prefix => bridge.prefix;

  /// Whether the server advertises usable broadcasting configuration.
  bool get supportsBroadcasting =>
      broadcasting != null && broadcasting!.key.isNotEmpty;

  /// Resolve an endpoint by its protocol key, substituting `{placeholders}` with [params].
  ///
  /// Falls back to the built-in table (under this server's prefix) when the
  /// server did not advertise [key]. Throws [ArgumentError] for unknown keys or
  /// missing placeholder values.
  String endpoint(String key, {Map<String, Object> params = const {}}) {
    final advertised = endpoints[key];
    final template = (advertised != null && advertised.isNotEmpty)
        ? advertised
        : BridgeEndpoints.template(key, prefix: prefix);
    return BridgeEndpoints.resolve(template, params);
  }

  /// Read a remote config value by dotted path (`features.chat.enabled`).
  T? config<T>(String path, [T? fallback]) {
    dynamic current = remoteConfig;
    for (final segment in path.split('.')) {
      if (current is Map && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return fallback;
      }
    }
    return current is T ? current : fallback;
  }

  /// Parse the handshake `data` object.
  ///
  /// [fallbackPrefix] is used when the server does not advertise `bridge.prefix`.
  factory ServerInfo.fromJson(
    Map<String, dynamic> json, {
    String fallbackPrefix = BridgeEndpoints.defaultPrefix,
  }) {
    final bridge = BridgeDetails.fromJson(
      parseBridgeMap(json['bridge']),
      fallbackPrefix: fallbackPrefix,
    );
    final connection = parseBridgeMap(json['connection']);
    final rawEndpoints = parseBridgeMap(json['endpoints']);
    final rawApp = json['app'];
    final rawBroadcasting = json['broadcasting'];

    return ServerInfo(
      server: ServerDetails.fromJson(parseBridgeMap(json['server'])),
      bridge: bridge,
      app: rawApp is Map ? AppInfo.fromJson(parseBridgeMap(rawApp)) : null,
      features: ServerFeatures.fromJson(parseBridgeMap(json['features'])),
      endpoints: Map<String, String>.unmodifiable(
        rawEndpoints.map((key, value) => MapEntry(key, value.toString())),
      ),
      broadcasting: rawBroadcasting is Map
          ? BroadcastingConfig.fromJson(parseBridgeMap(rawBroadcasting),
              prefix: bridge.prefix)
          : null,
      heartbeatInterval: parseBridgeInt(connection['heartbeat_interval']) ?? 30,
      timeout: parseBridgeInt(connection['timeout']) ?? 90,
      remoteConfig: parseBridgeMap(json['remote_config']),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => {
        'server': server.toJson(),
        'bridge': bridge.toJson(),
        'app': app?.toJson(),
        'features': features.toJson(),
        'endpoints': endpoints,
        'broadcasting': broadcasting?.toJson(),
        'connection': {
          'heartbeat_interval': heartbeatInterval,
          'timeout': timeout
        },
        'remote_config': remoteConfig,
      };
}
