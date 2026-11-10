import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../client/laravel_client.dart';
import '../exceptions/laravel_exception.dart';
import 'channel.dart';
import 'echo_options.dart';
import 'presence_channel.dart';
import 'private_channel.dart';

enum EchoConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

/// Error reported by the Pusher protocol (`pusher:error`, `pusher:subscription_error`)
/// or by channel authorization.
class EchoError {
  /// Pusher error code (4000–4299), or `null` for authorization/subscription errors.
  final int? code;
  final String message;

  /// Channel concerned, for subscription / authorization errors.
  final String? channel;

  const EchoError({this.code, required this.message, this.channel});

  /// 4000–4099: the connection must not be retried (e.g. wrong app key, SSL only).
  bool get isFatal => code != null && code! >= 4000 && code! < 4100;

  /// 4200–4299: reconnect immediately.
  bool get reconnectImmediately =>
      code != null && code! >= 4200 && code! < 4300;

  @override
  String toString() =>
      'EchoError(${code ?? '-'}${channel != null ? ', $channel' : ''}): $message';
}

/// Enterprise-grade real-time WebSocket client compatible with Laravel Reverb & Pusher.
class LaravelEcho {
  final EchoOptions options;
  final LaravelClient client;

  /// Factory used to open the socket (override in tests).
  final WebSocketChannel Function(Uri uri) channelFactory;

  /// First reconnect delay; doubles on every failed attempt.
  final Duration reconnectBaseDelay;

  /// Upper bound of the reconnect delay.
  final Duration reconnectMaxDelay;

  /// Automatically reconnect after unexpected socket closure.
  final bool autoReconnect;

  final Random _random;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  String? _socketId;
  bool _manuallyClosed = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;

  final Map<String, Channel> _channels = {};
  final _connectionStateController =
      StreamController<EchoConnectionState>.broadcast();
  final _errorController = StreamController<EchoError>.broadcast();
  EchoConnectionState _connectionState = EchoConnectionState.disconnected;

  /// Current assigned socket ID.
  String? get socketId => _socketId;

  /// Current WebSocket connection state.
  EchoConnectionState get connectionState => _connectionState;

  /// Stream of connection state changes.
  Stream<EchoConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// Stream of protocol / authorization errors.
  Stream<EchoError> get errors => _errorController.stream;

  /// Number of consecutive reconnect attempts since the last successful connection.
  int get reconnectAttempt => _reconnectAttempt;

  /// Names of the channels currently registered.
  Iterable<String> get channelNames => _channels.keys;

  LaravelEcho({
    required this.options,
    required this.client,
    WebSocketChannel Function(Uri uri)? channelFactory,
    this.reconnectBaseDelay = const Duration(seconds: 1),
    this.reconnectMaxDelay = const Duration(seconds: 60),
    this.autoReconnect = true,
    Random? random,
  })  : channelFactory = channelFactory ?? WebSocketChannel.connect,
        _random = random ?? Random();

  /// Connect to the Reverb or Pusher WebSocket server.
  Future<void> connect() async {
    if (_disposed) return;
    _manuallyClosed = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    if (_connectionState == EchoConnectionState.connected ||
        _connectionState == EchoConnectionState.connecting) {
      return;
    }

    _setConnectionState(EchoConnectionState.connecting);

    try {
      final uri = options.buildUri();
      debugPrint('LaravelEcho: Connecting to $uri');

      final socket = channelFactory(uri);
      _channel = socket;

      _subscription = socket.stream.listen(
        _onMessageReceived,
        onError: _onError,
        onDone: _onDisconnected,
        cancelOnError: false,
      );

      _startHeartbeat();
    } catch (e) {
      debugPrint('LaravelEcho: Connection error: $e');
      _handleDisconnect();
    }
  }

  /// Subscribe to a public broadcast channel.
  Channel channel(String channelName) {
    if (_channels.containsKey(channelName)) {
      return _channels[channelName]!;
    }

    final ch = Channel(channelName, _sendWhisper);
    _channels[channelName] = ch;

    if (_connectionState == EchoConnectionState.connected) {
      _sendSubscribe(channelName);
    }

    return ch;
  }

  /// Subscribe to a private authenticated broadcast channel.
  PrivateChannel private(String channelName) {
    final fullName = channelName.startsWith('private-')
        ? channelName
        : 'private-$channelName';

    if (_channels.containsKey(fullName)) {
      return _channels[fullName]! as PrivateChannel;
    }

    final ch = PrivateChannel(fullName, _sendWhisper);
    _channels[fullName] = ch;

    if (_connectionState == EchoConnectionState.connected &&
        _socketId != null) {
      _authenticateAndSubscribe(fullName);
    }

    return ch;
  }

  /// Subscribe to an authenticated presence broadcast channel.
  PresenceChannel join(String channelName) {
    final fullName = channelName.startsWith('presence-')
        ? channelName
        : 'presence-$channelName';

    if (_channels.containsKey(fullName)) {
      return _channels[fullName]! as PresenceChannel;
    }

    final ch = PresenceChannel(fullName, _sendWhisper);
    _channels[fullName] = ch;

    if (_connectionState == EchoConnectionState.connected &&
        _socketId != null) {
      _authenticateAndSubscribe(fullName);
    }

    return ch;
  }

  /// Convenience helper to listen for Laravel broadcast notifications for the authenticated user.
  Channel listenNotifications(
      int userId, void Function(dynamic notification) callback) {
    return private('App.Models.User.$userId').listen(
        '.Illuminate\\Notifications\\Events\\BroadcastNotificationCreated',
        callback);
  }

  /// Unsubscribe from a channel.
  void leave(String channelName) {
    final ch = _channels.remove(channelName);
    ch?.dispose();

    if (_connectionState == EchoConnectionState.connected) {
      _sendJson({
        'event': 'pusher:unsubscribe',
        'data': {'channel': channelName},
      });
    }
  }

  /// Re-authorize and re-subscribe every private/presence channel (e.g. after login).
  void reauthorize() {
    if (_connectionState != EchoConnectionState.connected || _socketId == null)
      return;
    for (final entry in _channels.entries) {
      if (entry.value is PrivateChannel) {
        _authenticateAndSubscribe(entry.key);
      }
    }
  }

  /// Disconnect WebSocket and cleanup. No automatic reconnect follows.
  Future<void> disconnect() async {
    _manuallyClosed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final subscription = _subscription;
    final socket = _channel;
    _subscription = null;
    _channel = null;
    _socketId = null;
    _reconnectAttempt = 0;
    _setConnectionState(EchoConnectionState.disconnected);
    try {
      await subscription?.cancel();
      await socket?.sink.close();
    } catch (e) {
      debugPrint('LaravelEcho: Error while closing socket: $e');
    }
  }

  void _onMessageReceived(dynamic raw) {
    try {
      final json = jsonDecode(raw.toString()) as Map<String, dynamic>;
      final event = json['event'] as String?;
      final channelName = json['channel'] as String?;
      var data = json['data'];

      // Pusher/Reverb sometimes JSON-encodes inner payload
      if (data is String && (data.startsWith('{') || data.startsWith('['))) {
        try {
          data = jsonDecode(data);
        } catch (_) {}
      }

      switch (event) {
        case 'pusher:connection_established':
          _socketId = (data as Map<String, dynamic>?)?['socket_id'] as String?;
          debugPrint('LaravelEcho: Connected! Assigned socket_id: $_socketId');
          _reconnectAttempt = 0;
          _setConnectionState(EchoConnectionState.connected);
          _resubscribeAll();
          break;

        case 'pusher:ping':
          _sendJson({'event': 'pusher:pong', 'data': {}});
          break;

        case 'pusher:error':
          _handlePusherError(data);
          break;

        case 'pusher:subscription_error':
          final message = data is Map
              ? (data['error'] ?? data['message'] ?? data).toString()
              : '$data';
          _emitError(EchoError(
            code: data is Map ? (data['status'] as num?)?.toInt() : null,
            message: message,
            channel: channelName,
          ));
          break;

        case 'pusher_internal:subscription_succeeded':
          if (channelName != null &&
              _channels[channelName] is PresenceChannel) {
            (_channels[channelName]! as PresenceChannel)
                .handleSubscriptionSucceeded(data);
          }
          break;

        case 'pusher_internal:member_added':
          if (channelName != null &&
              _channels[channelName] is PresenceChannel) {
            (_channels[channelName]! as PresenceChannel)
                .handleMemberAdded(data);
          }
          break;

        case 'pusher_internal:member_removed':
          if (channelName != null &&
              _channels[channelName] is PresenceChannel) {
            (_channels[channelName]! as PresenceChannel)
                .handleMemberRemoved(data);
          }
          break;

        default:
          if (channelName != null &&
              event != null &&
              _channels.containsKey(channelName)) {
            _channels[channelName]!.dispatch(event, data);
          }
          break;
      }
    } catch (e) {
      debugPrint('LaravelEcho: Message parsing failed: $e');
    }
  }

  void _handlePusherError(dynamic data) {
    final code = data is Map ? (data['code'] as num?)?.toInt() : null;
    final message = data is Map
        ? (data['message']?.toString() ?? 'Unknown error')
        : '$data';
    final error = EchoError(code: code, message: message);
    debugPrint('LaravelEcho: $error');
    _emitError(error);

    if (error.isFatal) {
      // The server told us not to retry with the same parameters.
      disconnect();
    } else if (error.reconnectImmediately) {
      _reconnectAttempt = 0;
    }
  }

  /// Extract the `auth` signature (and `channel_data`) from a broadcasting auth
  /// response, accepting both the bridge envelope (`data.auth`) and the raw
  /// Laravel/Pusher payload (top-level `auth`).
  @visibleForTesting
  static Map<String, dynamic>? extractAuthPayload(dynamic body) {
    if (body is! Map) return null;
    final data = body['data'];
    if (data is Map && data['auth'] is String) {
      return Map<String, dynamic>.from(data);
    }
    if (body['auth'] is String) {
      return Map<String, dynamic>.from(body);
    }
    return null;
  }

  Future<void> _authenticateAndSubscribe(String channelName) async {
    final socketId = _socketId;
    if (socketId == null) return;

    try {
      final response = await client.rawDio.post<dynamic>(
        options.authEndpoint,
        data: {
          'socket_id': socketId,
          'channel_name': channelName,
        },
        options: Options(headers: {'X-Socket-ID': socketId}),
      );

      // The socket may have been replaced while the request was in flight.
      if (_socketId != socketId || !_channels.containsKey(channelName)) return;

      final authData = extractAuthPayload(response.data);
      final authSignature = authData?['auth'] as String?;
      var channelData = authData?['channel_data'];
      if (channelData != null && channelData is! String) {
        channelData = jsonEncode(channelData);
      }

      if (authSignature != null) {
        _sendJson({
          'event': 'pusher:subscribe',
          'data': {
            'channel': channelName,
            'auth': authSignature,
            if (channelData != null) 'channel_data': channelData,
          },
        });
      } else {
        _emitError(EchoError(
            message: 'Authorization response had no signature',
            channel: channelName));
      }
    } catch (e) {
      final error =
          e is DioException && e.error is LaravelException ? e.error : e;
      debugPrint(
          'LaravelEcho: Channel authorization failed for $channelName: $error');
      _emitError(EchoError(
          message: 'Authorization failed: $error', channel: channelName));
    }
  }

  void _sendSubscribe(String channelName) {
    _sendJson({
      'event': 'pusher:subscribe',
      'data': {'channel': channelName},
    });
  }

  void _resubscribeAll() {
    for (final entry in _channels.entries.toList()) {
      final name = entry.key;
      final ch = entry.value;

      if (ch is PrivateChannel) {
        _authenticateAndSubscribe(name);
      } else {
        _sendSubscribe(name);
      }
    }
  }

  void _sendWhisper(String channelName, String event, dynamic data) {
    if (_connectionState == EchoConnectionState.connected) {
      _sendJson({
        'event': event,
        'channel': channelName,
        'data': data,
      });
    }
  }

  void _sendJson(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('LaravelEcho: Failed to send frame: $e');
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(options.activityTimeout, (_) {
      if (_connectionState == EchoConnectionState.connected) {
        _sendJson({'event': 'pusher:ping', 'data': {}});
      }
    });
  }

  void _onError(dynamic error) {
    debugPrint('LaravelEcho WebSocket error: $error');
    _handleDisconnect();
  }

  void _onDisconnected() {
    debugPrint('LaravelEcho: WebSocket closed');
    _handleDisconnect();
  }

  void _handleDisconnect() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    _socketId = null;

    if (_manuallyClosed || _disposed) {
      _setConnectionState(EchoConnectionState.disconnected);
      return;
    }

    _setConnectionState(EchoConnectionState.disconnected);
    _scheduleReconnect();
  }

  /// Delay before the reconnect attempt number [attempt] (0-based): exponential
  /// from [reconnectBaseDelay], capped at [reconnectMaxDelay], with ±20% jitter.
  Duration reconnectDelay(int attempt) {
    final baseMs = reconnectBaseDelay.inMilliseconds;
    final capMs = reconnectMaxDelay.inMilliseconds;
    final exp = baseMs * pow(2, attempt.clamp(0, 30));
    final capped = min(exp.toDouble(), capMs.toDouble());
    final jitter = capped * (0.8 + _random.nextDouble() * 0.4);
    return Duration(milliseconds: min(jitter, capMs.toDouble()).round());
  }

  void _scheduleReconnect() {
    if (!autoReconnect || _manuallyClosed || _disposed) return;
    if (_reconnectTimer?.isActive ?? false) return;

    final delay = reconnectDelay(_reconnectAttempt);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_manuallyClosed || _disposed) return;
      if (_connectionState == EchoConnectionState.disconnected) {
        _setConnectionState(EchoConnectionState.reconnecting);
        connect();
      }
    });
  }

  void _emitError(EchoError error) {
    if (!_errorController.isClosed) _errorController.add(error);
  }

  void _setConnectionState(EchoConnectionState state) {
    _connectionState = state;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(state);
    }
  }

  void dispose() {
    disconnect();
    _disposed = true;
    _connectionStateController.close();
    _errorController.close();
    for (final ch in _channels.values) {
      ch.dispose();
    }
    _channels.clear();
  }
}
