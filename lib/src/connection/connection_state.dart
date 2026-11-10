import '../exceptions/laravel_exception.dart';
import 'connection_session.dart';
import 'laravel_connection.dart';
import 'server_info.dart';

/// Lifecycle status of the active backend connection.
enum ConnectionStatus {
  /// No connection attempt has been made (or it was closed on purpose).
  idle,

  /// Handshake / session establishment in progress.
  connecting,

  /// Session established and heartbeats succeeding.
  connected,

  /// Waiting to retry after a failure (see [LaravelConnectionState.reconnectAttempt]).
  reconnecting,

  /// The server is unreachable; a reconnect is scheduled.
  offline,

  /// A non-recoverable error (bad app key, suspended app, invalid response…).
  failed,

  /// The session was revoked remotely; tokens were cleared.
  revoked,

  /// The app version is below the server's minimum version.
  upgradeRequired;

  /// Whether requests to the backend are expected to succeed.
  bool get isUsable => this == ConnectionStatus.connected;

  /// Whether the manager is actively trying to (re)establish a session.
  bool get isBusy =>
      this == ConnectionStatus.connecting ||
      this == ConnectionStatus.reconnecting;

  /// Whether the status needs user attention (banner-worthy).
  bool get isProblem =>
      this == ConnectionStatus.offline ||
      this == ConnectionStatus.reconnecting ||
      this == ConnectionStatus.failed ||
      this == ConnectionStatus.revoked ||
      this == ConnectionStatus.upgradeRequired;
}

/// Outcome of probing a connection profile with [LaravelConnectionManager.test].
class ConnectionProbeResult {
  /// Whether the server answered the handshake and ping.
  final bool ok;

  /// Round-trip time of the ping request.
  final Duration? latency;

  /// Parsed handshake, when it succeeded.
  final ServerInfo? serverInfo;

  /// The failure, when [ok] is false.
  final Object? error;

  const ConnectionProbeResult({
    required this.ok,
    this.latency,
    this.serverInfo,
    this.error,
  });

  /// Human readable error message.
  String? get errorMessage {
    final e = error;
    if (e == null) return null;
    if (e is LaravelException) return e.message;
    return e.toString();
  }

  @override
  String toString() => ok
      ? 'ConnectionProbeResult(ok, ${latency?.inMilliseconds}ms)'
      : 'ConnectionProbeResult(failed: $errorMessage)';
}

/// Immutable snapshot of the [LaravelConnectionManager] state.
///
/// Named `LaravelConnectionState` (rather than `ConnectionState`) so it does not
/// clash with Flutter's `ConnectionState` used by `AsyncSnapshot`.
class LaravelConnectionState {
  final ConnectionStatus status;

  /// The active profile.
  final LaravelConnection? profile;

  /// Latest handshake of the active profile.
  final ServerInfo? serverInfo;

  /// Current server-side session.
  final ConnectionSession? session;

  /// Last measured round-trip latency.
  final Duration? latency;

  /// Last error that caused the current status (if any).
  final Object? error;

  /// Time of the last successful heartbeat.
  final DateTime? lastHeartbeatAt;

  /// Number of consecutive reconnect attempts (0 when connected).
  final int reconnectAttempt;

  /// When the next automatic reconnect will be attempted.
  final DateTime? nextRetryAt;

  const LaravelConnectionState({
    this.status = ConnectionStatus.idle,
    this.profile,
    this.serverInfo,
    this.session,
    this.latency,
    this.error,
    this.lastHeartbeatAt,
    this.reconnectAttempt = 0,
    this.nextRetryAt,
  });

  bool get isConnected => status == ConnectionStatus.connected;

  /// Create a copy with updated values. Use the `clear*` flags to reset nullable fields.
  LaravelConnectionState copyWith({
    ConnectionStatus? status,
    LaravelConnection? profile,
    bool clearProfile = false,
    ServerInfo? serverInfo,
    bool clearServerInfo = false,
    ConnectionSession? session,
    bool clearSession = false,
    Duration? latency,
    bool clearLatency = false,
    Object? error,
    bool clearError = false,
    DateTime? lastHeartbeatAt,
    bool clearLastHeartbeatAt = false,
    int? reconnectAttempt,
    DateTime? nextRetryAt,
    bool clearNextRetryAt = false,
  }) {
    return LaravelConnectionState(
      status: status ?? this.status,
      profile: clearProfile ? null : (profile ?? this.profile),
      serverInfo: clearServerInfo ? null : (serverInfo ?? this.serverInfo),
      session: clearSession ? null : (session ?? this.session),
      latency: clearLatency ? null : (latency ?? this.latency),
      error: clearError ? null : (error ?? this.error),
      lastHeartbeatAt: clearLastHeartbeatAt
          ? null
          : (lastHeartbeatAt ?? this.lastHeartbeatAt),
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      nextRetryAt: clearNextRetryAt ? null : (nextRetryAt ?? this.nextRetryAt),
    );
  }

  @override
  String toString() =>
      'LaravelConnectionState(${status.name}, profile: ${profile?.id}, session: ${session?.id}, '
      'attempt: $reconnectAttempt, error: $error)';
}
