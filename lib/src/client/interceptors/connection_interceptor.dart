import 'package:dio/dio.dart';

import '../../connection/bridge_version.dart';

/// Attaches the bridge protocol headers (CONNECTIONS.md §2) and reads the
/// server clock from `X-Flutter-Server-Time`.
///
/// * `X-Flutter-Bridge-Version` — always ([kBridgeVersion]).
/// * `X-Flutter-App-Key` — when an app key is configured.
/// * `X-Flutter-Connection-Id` — once a connection session is established.
class ConnectionInterceptor extends Interceptor {
  /// Request `extra` flag that suppresses the `X-Flutter-Connection-Id` header.
  static const String skipConnectionIdExtra = 'skipConnectionId';

  final String? appKey;
  final String? Function()? connectionIdProvider;
  final DateTime Function() _clock;

  Duration? _serverClockOffset;
  DateTime? _lastServerTime;
  String? _serverBridgeVersion;

  ConnectionInterceptor({
    this.appKey,
    this.connectionIdProvider,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Difference between the server clock and the local clock
  /// (`serverTime - localTime`), measured on the last response.
  Duration? get serverClockOffset => _serverClockOffset;

  /// Last `X-Flutter-Server-Time` received.
  DateTime? get lastServerTime => _lastServerTime;

  /// Server package version from the `X-Laravel-Flutter-Bridge` header.
  String? get serverBridgeVersion => _serverBridgeVersion;

  /// Current time on the server, estimated from [serverClockOffset].
  DateTime serverNow() => _clock().add(_serverClockOffset ?? Duration.zero);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers['X-Flutter-Bridge-Version'] = kBridgeVersion;

    final key = appKey;
    if (key != null &&
        key.isNotEmpty &&
        !options.headers.containsKey('X-Flutter-App-Key')) {
      options.headers['X-Flutter-App-Key'] = key;
    }

    if (options.extra[skipConnectionIdExtra] != true &&
        !options.headers.containsKey('X-Flutter-Connection-Id')) {
      final connectionId = connectionIdProvider?.call();
      if (connectionId != null && connectionId.isNotEmpty) {
        options.headers['X-Flutter-Connection-Id'] = connectionId;
      }
    }

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _readServerHeaders(response.headers);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final response = err.response;
    if (response != null) {
      _readServerHeaders(response.headers);
    }
    handler.next(err);
  }

  void _readServerHeaders(Headers headers) {
    final rawTime = headers.value('x-flutter-server-time');
    if (rawTime != null) {
      final serverTime = DateTime.tryParse(rawTime);
      if (serverTime != null) {
        _lastServerTime = serverTime;
        _serverClockOffset = serverTime.difference(_clock());
      }
    }
    final version = headers.value('x-laravel-flutter-bridge');
    if (version != null) _serverBridgeVersion = version;
  }
}
