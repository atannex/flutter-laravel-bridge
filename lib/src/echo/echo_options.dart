import '../connection/bridge_version.dart';
import '../connection/server_info.dart';

/// Configuration parameters for connecting to Laravel Reverb or Pusher WebSockets.
class EchoOptions {
  /// The Pusher / Reverb App Key.
  final String appKey;

  /// WebSocket server hostname.
  final String wsHost;

  /// WebSocket unencrypted port (default 8080 for Reverb, 80 for Pusher).
  final int wsPort;

  /// WebSocket encrypted port (default 8080 / 443).
  final int wssPort;

  /// Whether to use WSS (TLS/SSL).
  final bool encrypted;

  /// Pusher cluster (if using hosted Pusher, e.g. 'mt1'). Not required for self-hosted Reverb.
  final String? cluster;

  /// API endpoint URL on Laravel backend for channel authorization.
  final String authEndpoint;

  /// Interval between ping/pong heartbeats.
  final Duration activityTimeout;

  const EchoOptions({
    required this.appKey,
    required this.wsHost,
    this.wsPort = 8080,
    this.wssPort = 443,
    this.encrypted = false,
    this.cluster,
    this.authEndpoint = 'api/flutter/broadcasting/auth',
    this.activityTimeout = const Duration(seconds: 30),
  });

  /// Build options from the `broadcasting` block advertised by the server handshake.
  factory EchoOptions.fromServer(
    BroadcastingConfig config, {
    Duration activityTimeout = const Duration(seconds: 30),
  }) {
    return config.toEchoOptions(activityTimeout: activityTimeout);
  }

  /// Restore options persisted with [toJson].
  factory EchoOptions.fromJson(Map<String, dynamic> json) {
    return EchoOptions(
      appKey: json['app_key']?.toString() ?? '',
      wsHost: json['ws_host']?.toString() ?? '',
      wsPort: (json['ws_port'] as num?)?.toInt() ?? 8080,
      wssPort: (json['wss_port'] as num?)?.toInt() ?? 443,
      encrypted: json['encrypted'] as bool? ?? false,
      cluster: json['cluster'] as String?,
      authEndpoint:
          json['auth_endpoint'] as String? ?? 'api/flutter/broadcasting/auth',
      activityTimeout: Duration(
        milliseconds: (json['activity_timeout_ms'] as num?)?.toInt() ?? 30000,
      ),
    );
  }

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'app_key': appKey,
        'ws_host': wsHost,
        'ws_port': wsPort,
        'wss_port': wssPort,
        'encrypted': encrypted,
        'cluster': cluster,
        'auth_endpoint': authEndpoint,
        'activity_timeout_ms': activityTimeout.inMilliseconds,
      };

  /// Create a copy with updated values.
  EchoOptions copyWith({
    String? appKey,
    String? wsHost,
    int? wsPort,
    int? wssPort,
    bool? encrypted,
    String? cluster,
    String? authEndpoint,
    Duration? activityTimeout,
  }) {
    return EchoOptions(
      appKey: appKey ?? this.appKey,
      wsHost: wsHost ?? this.wsHost,
      wsPort: wsPort ?? this.wsPort,
      wssPort: wssPort ?? this.wssPort,
      encrypted: encrypted ?? this.encrypted,
      cluster: cluster ?? this.cluster,
      authEndpoint: authEndpoint ?? this.authEndpoint,
      activityTimeout: activityTimeout ?? this.activityTimeout,
    );
  }

  /// Build the complete WebSocket connection URI.
  Uri buildUri() {
    final scheme = encrypted ? 'wss' : 'ws';
    final port = encrypted ? wssPort : wsPort;
    final host = cluster != null ? 'ws-$cluster.pusher.com' : wsHost;

    return Uri(
      scheme: scheme,
      host: host,
      port: port,
      path: '/app/$appKey',
      queryParameters: {
        'protocol': '7',
        'client': 'flutter-laravel-bridge',
        'version': kBridgeVersion,
        'flash': 'false',
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EchoOptions &&
          other.appKey == appKey &&
          other.wsHost == wsHost &&
          other.wsPort == wsPort &&
          other.wssPort == wssPort &&
          other.encrypted == encrypted &&
          other.cluster == cluster &&
          other.authEndpoint == authEndpoint &&
          other.activityTimeout == activityTimeout;

  @override
  int get hashCode => Object.hash(
        appKey,
        wsHost,
        wsPort,
        wssPort,
        encrypted,
        cluster,
        authEndpoint,
        activityTimeout,
      );

  @override
  String toString() => 'EchoOptions(${buildUri()}, auth: $authEndpoint)';
}
