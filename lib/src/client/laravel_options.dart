import '../connection/bridge_endpoints.dart';

/// Configuration settings for the Laravel client instance.
class LaravelOptions {
  /// Base API URL (e.g. 'https://api.example.com' or 'http://10.0.2.2:8000').
  final String baseUrl;

  /// Network connection timeout.
  final Duration connectTimeout;

  /// Response receive timeout.
  final Duration receiveTimeout;

  /// Request send timeout.
  final Duration sendTimeout;

  /// Default headers to attach to every outgoing request.
  final Map<String, dynamic> headers;

  /// Whether to print network logs in debug mode.
  final bool enableLogging;

  /// Unique client device identifier for mobile push registration.
  final String? deviceId;

  /// Current application version (e.g. '1.0.0').
  final String? appVersion;

  /// Operating system platform identifier ('android', 'ios', 'web', 'macos', 'windows', 'linux').
  final String? platform;

  /// Human readable device name sent when opening a connection session (e.g. 'Pixel 9').
  final String? deviceName;

  /// Operating system version sent when opening a connection session.
  final String? osVersion;

  /// App key (`fba_…`) sent as `X-Flutter-App-Key` on every request.
  final String? appKey;

  /// Bridge route prefix (`flutter-bridge.prefix` on the server).
  final String prefix;

  final String? _authPrefix;
  final String? _devicePrefix;
  final String? _broadcastAuthPath;

  /// Maximum automatic retry attempts on idempotent network failures.
  final int maxRetries;

  /// Base delay for retry exponential backoff.
  final Duration retryBaseDelay;

  const LaravelOptions({
    required this.baseUrl,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 15),
    this.sendTimeout = const Duration(seconds: 15),
    this.headers = const {},
    this.enableLogging = true,
    this.deviceId,
    this.appVersion,
    this.platform,
    this.deviceName,
    this.osVersion,
    this.appKey,
    this.prefix = BridgeEndpoints.defaultPrefix,
    String? authPrefix,
    String? devicePrefix,
    String? broadcastAuthPath,
    this.maxRetries = 2,
    this.retryBaseDelay = const Duration(milliseconds: 800),
  })  : _authPrefix = authPrefix,
        _devicePrefix = devicePrefix,
        _broadcastAuthPath = broadcastAuthPath;

  /// [prefix] without leading/trailing slashes.
  String get normalizedPrefix => BridgeEndpoints.normalizePrefix(prefix);

  /// URL prefix for built-in bridge auth endpoints (defaults to `<prefix>/auth`).
  String get authPrefix => _authPrefix ?? '$normalizedPrefix/auth';

  /// URL prefix for device registration endpoints (defaults to `<prefix>/devices`).
  String get devicePrefix => _devicePrefix ?? '$normalizedPrefix/devices';

  /// URL path for WebSocket broadcast authorization (defaults to `<prefix>/broadcasting/auth`).
  String get broadcastAuthPath =>
      _broadcastAuthPath ?? '$normalizedPrefix/broadcasting/auth';

  /// Default path for a protocol endpoint [key] when the server has not
  /// advertised its endpoint table yet. Honours the legacy [authPrefix],
  /// [devicePrefix] and [broadcastAuthPath] overrides.
  String defaultEndpoint(String key, {Map<String, Object> params = const {}}) {
    final relative = BridgeEndpoints.relativePaths[key];
    if (relative == null) {
      throw ArgumentError.value(key, 'key', 'Unknown bridge endpoint');
    }
    final String template;
    if (key.startsWith('auth.')) {
      template = BridgeEndpoints.joinPath(
          authPrefix, relative.substring('auth/'.length));
    } else if (key.startsWith('devices.')) {
      template = BridgeEndpoints.joinPath(
          devicePrefix, relative.substring('devices/'.length));
    } else if (key == BridgeEndpoints.broadcastingAuth) {
      template = broadcastAuthPath;
    } else {
      template = BridgeEndpoints.joinPath(normalizedPrefix, relative);
    }
    return BridgeEndpoints.resolve(template, params);
  }

  /// Create a copy of options with updated values.
  ///
  /// Derived prefixes ([authPrefix], [devicePrefix], [broadcastAuthPath]) follow
  /// a changed [prefix] unless they were set explicitly.
  LaravelOptions copyWith({
    String? baseUrl,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, dynamic>? headers,
    bool? enableLogging,
    String? deviceId,
    String? appVersion,
    String? platform,
    String? deviceName,
    String? osVersion,
    String? appKey,
    bool clearAppKey = false,
    String? prefix,
    String? authPrefix,
    String? devicePrefix,
    String? broadcastAuthPath,
    int? maxRetries,
    Duration? retryBaseDelay,
  }) {
    return LaravelOptions(
      baseUrl: baseUrl ?? this.baseUrl,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      sendTimeout: sendTimeout ?? this.sendTimeout,
      headers: headers ?? this.headers,
      enableLogging: enableLogging ?? this.enableLogging,
      deviceId: deviceId ?? this.deviceId,
      appVersion: appVersion ?? this.appVersion,
      platform: platform ?? this.platform,
      deviceName: deviceName ?? this.deviceName,
      osVersion: osVersion ?? this.osVersion,
      appKey: clearAppKey ? null : (appKey ?? this.appKey),
      prefix: prefix ?? this.prefix,
      authPrefix: authPrefix ?? _authPrefix,
      devicePrefix: devicePrefix ?? _devicePrefix,
      broadcastAuthPath: broadcastAuthPath ?? _broadcastAuthPath,
      maxRetries: maxRetries ?? this.maxRetries,
      retryBaseDelay: retryBaseDelay ?? this.retryBaseDelay,
    );
  }
}
