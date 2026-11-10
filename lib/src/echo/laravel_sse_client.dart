import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../client/laravel_client.dart';
import 'channel.dart';

/// Server-Sent Events (SSE) client providing an HTTP-streaming fallback
/// when WebSockets are restricted by corporate proxies or firewalls.
class LaravelSseClient {
  final String streamUrl;
  final LaravelClient client;
  final Map<String, Channel> _channels = {};

  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  bool _isConnected = false;
  bool _manuallyDisconnected = false;
  bool _disposed = false;

  /// Delay before reconnecting after the stream drops.
  final Duration reconnectDelay;
  final _connectionStateController = StreamController<bool>.broadcast();

  bool get isConnected => _isConnected;
  Stream<bool> get connectionStream => _connectionStateController.stream;

  LaravelSseClient({
    required this.streamUrl,
    required this.client,
    this.reconnectDelay = const Duration(seconds: 5),
  });

  /// Subscribe to a channel over SSE.
  Channel channel(String channelName) {
    return _channels.putIfAbsent(channelName, () => Channel(channelName));
  }

  /// Start listening to the SSE HTTP stream.
  Future<void> connect() async {
    if (_isConnected || _disposed) return;
    _manuallyDisconnected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    try {
      final response = await client.rawDio.get<ResponseBody>(
        streamUrl,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Accept': 'text/event-stream',
            'Cache-Control': 'no-cache',
          },
        ),
      );

      if (_manuallyDisconnected || _disposed) return;

      _isConnected = true;
      _emit(true);

      String buffer = '';
      _subscription = response.data!.stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen(
        (chunk) {
          buffer += chunk;
          while (buffer.contains('\n\n')) {
            final eventBlockIndex = buffer.indexOf('\n\n');
            final eventBlock = buffer.substring(0, eventBlockIndex);
            buffer = buffer.substring(eventBlockIndex + 2);
            _parseSseBlock(eventBlock);
          }
        },
        onError: (err) {
          debugPrint('LaravelSseClient error: $err');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('LaravelSseClient stream closed');
          _handleDisconnect();
        },
      );
    } catch (e) {
      debugPrint('LaravelSseClient connect failed: $e');
      _handleDisconnect();
    }
  }

  void _parseSseBlock(String block) {
    String? eventName;
    String? channelName;
    dynamic data;

    final lines = block.split('\n');
    for (final line in lines) {
      if (line.startsWith('event:')) {
        eventName = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        final rawData = line.substring(5).trim();
        try {
          data = jsonDecode(rawData);
          if (data is Map && data['channel'] != null) {
            channelName = data['channel'];
          }
        } catch (_) {
          data = rawData;
        }
      }
    }

    if (eventName != null &&
        channelName != null &&
        _channels.containsKey(channelName)) {
      _channels[channelName]!.dispatch(eventName, data);
    }
  }

  void _handleDisconnect() {
    _isConnected = false;
    _emit(false);
    _subscription?.cancel();
    _subscription = null;

    if (_manuallyDisconnected || _disposed) return;

    // Retry after delay, unless the stream was closed on purpose meanwhile.
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      _reconnectTimer = null;
      if (!_isConnected && !_manuallyDisconnected && !_disposed) connect();
    });
  }

  void _emit(bool connected) {
    if (!_connectionStateController.isClosed)
      _connectionStateController.add(connected);
  }

  /// Disconnect stream. No automatic reconnect follows.
  void disconnect() {
    _manuallyDisconnected = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _isConnected = false;
    _subscription?.cancel();
    _subscription = null;
    _emit(false);
  }

  void dispose() {
    disconnect();
    _disposed = true;
    _connectionStateController.close();
    for (final ch in _channels.values) {
      ch.dispose();
    }
    _channels.clear();
  }
}
