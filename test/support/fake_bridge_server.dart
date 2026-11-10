import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';

/// Recorded request seen by [FakeBridgeServer].
class RecordedRequest {
  final String method;
  final String path;
  final Map<String, dynamic> headers;
  final dynamic body;

  RecordedRequest(this.method, this.path, this.headers, this.body);

  String? header(String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase())
        return entry.value?.toString();
    }
    return null;
  }

  @override
  String toString() => '$method $path';
}

class FakeSession {
  final String id;
  final String? appKey;
  final String deviceId;
  final String platform;
  String? deviceName;
  String? appVersion;
  Object? userId;
  String status = 'active';
  DateTime connectedAt = DateTime.utc(2026, 11, 9, 10);
  DateTime lastSeenAt = DateTime.utc(2026, 11, 9, 10);
  DateTime? revokedAt;
  final List<Map<String, dynamic>> pending = [];

  FakeSession({
    required this.id,
    required this.appKey,
    required this.deviceId,
    required this.platform,
    this.deviceName,
    this.appVersion,
    this.userId,
  });

  Map<String, dynamic> toJson(String? currentId) => {
        'id': id,
        'app_key': appKey,
        'user_id': userId,
        'device_id': deviceId,
        'platform': platform,
        'device_name': deviceName,
        'app_version': appVersion,
        'os_version': null,
        'ip_address': '10.0.0.5',
        'user_agent': 'test',
        'status': status,
        'is_online': status == 'active',
        'is_current': id == currentId,
        'connected_at': connectedAt.toIso8601String(),
        'last_seen_at': lastSeenAt.toIso8601String(),
        'disconnected_at': null,
        'revoked_at': revokedAt?.toIso8601String(),
        'metadata': <String, dynamic>{},
      };
}

class _RefreshToken {
  final int userId;
  final String accessToken;
  final String? connectionId;
  bool revoked = false;

  _RefreshToken(this.userId, this.accessToken, this.connectionId);
}

typedef FakeRouteHandler = FutureOr<ResponseBody> Function(
    RecordedRequest request, FakeBridgeServer server);

/// In-memory implementation of the bridge wire contract (docs/CONNECTIONS.md),
/// plugged into Dio as an [HttpClientAdapter].
class FakeBridgeServer implements HttpClientAdapter {
  final String name;
  final String prefix;
  final Set<String> validAppKeys;
  bool requireAppKey;
  bool offline = false;
  bool omitEndpoints = false;
  bool broadcasting = false;
  String? minVersion;
  int heartbeatInterval = 30;
  final DateTime serverTime = DateTime.utc(2026, 11, 9, 10);

  final List<RecordedRequest> requests = [];
  final Map<String, FakeSession> sessions = {};
  final Map<String, int> accessTokens = {};
  final Map<String, _RefreshToken> refreshTokens = {};
  final Map<String, FakeRouteHandler> routes = {};
  final Map<String, Map<String, dynamic>> users = {
    'a@example.com': {
      'id': 1,
      'name': 'Alice',
      'email': 'a@example.com',
      'password': 'secret'
    },
    'b@example.com': {
      'id': 2,
      'name': 'Bob',
      'email': 'b@example.com',
      'password': 'secret'
    },
  };

  int _sessionSeq = 0;
  int _tokenSeq = 0;
  int _commandSeq = 0;

  FakeBridgeServer({
    this.name = 'Acme',
    this.prefix = 'api/flutter',
    this.validAppKeys = const {'fba_test'},
    this.requireAppKey = false,
  });

  /// Requests whose path ends with [suffix].
  List<RecordedRequest> requestsTo(String suffix, {String? method}) => requests
      .where((r) =>
          r.path.endsWith(suffix) && (method == null || r.method == method))
      .toList();

  /// Queue a command for [sessionId] and return its id.
  String queueCommand(String sessionId, String type,
      [Map<String, dynamic> payload = const {}]) {
    final id = '${++_commandSeq}';
    sessions[sessionId]!.pending.add({
      'id': id,
      'type': type,
      'payload': payload,
      'created_at': serverTime.toIso8601String(),
    });
    return id;
  }

  /// Create a session for another device of [userId].
  FakeSession addForeignSession(
      {required int userId,
      String deviceId = 'other-device',
      String platform = 'ios'}) {
    final session = FakeSession(
      id: 'sess-${++_sessionSeq}',
      appKey: null,
      deviceId: deviceId,
      platform: platform,
      deviceName: 'iPhone 17',
      appVersion: '1.0.0',
      userId: userId,
    );
    sessions[session.id] = session;
    return session;
  }

  /// Revoke a session the way `DELETE connections/{id}` does.
  void revoke(String sessionId) {
    final session = sessions[sessionId]!;
    session.status = 'revoked';
    session.revokedAt = serverTime;
    for (final entry in refreshTokens.entries.toList()) {
      if (entry.value.connectionId == sessionId) {
        entry.value.revoked = true;
        accessTokens.remove(entry.value.accessToken);
      }
    }
    final id = '${++_commandSeq}';
    session.pending.add({
      'id': id,
      'type': 'revoked',
      'payload': {'reason': 'Signed out remotely'}
    });
  }

  /// Invalidate every access token (simulates expiry).
  void expireAccessTokens() => accessTokens.clear();

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Let the event loop breathe like a real network call.
    await Future<void>.delayed(Duration.zero);

    var path = options.uri.path;
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    final request = RecordedRequest(
        options.method, path, Map.of(options.headers), options.data);
    requests.add(request);

    if (offline) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: Exception('Connection refused'),
      );
    }

    final custom = routes['${options.method} $path'];
    if (custom != null) return custom(request, this);

    if (!path.startsWith('$prefix/')) return _error(404, 'Not found');
    final route = path.substring(prefix.length + 1);
    return _route(request, route, options.method);
  }

  Future<ResponseBody> _route(
      RecordedRequest request, String route, String method) async {
    final appKey = request.header('X-Flutter-App-Key');
    final body = request.body is Map
        ? Map<String, dynamic>.from(request.body as Map)
        : <String, dynamic>{};
    final connectionId = request.header('X-Flutter-Connection-Id');

    // App key middleware.
    if (appKey == null && requireAppKey) {
      return _error(403, 'App key required', code: 'app_key_required');
    }
    if (appKey != null && !validAppKeys.contains(appKey)) {
      return _error(403, 'Invalid app key', code: 'invalid_app_key');
    }

    final exempt = route == 'ping' || route == 'handshake';

    // Version policy.
    final version = request.header('X-Flutter-App-Version');
    if (!exempt &&
        minVersion != null &&
        version != null &&
        compareBridgeVersions(version, minVersion!) < 0) {
      return _error(426, 'Upgrade required', code: 'upgrade_required', errors: {
        'current_version': version,
        'min_version': minVersion,
        'latest_version': '9.9.9',
        'update_url': 'https://store.example.com/app',
      });
    }

    // Revoked session header.
    if (!exempt && route != 'connections/connect' && connectionId != null) {
      final session = sessions[connectionId];
      if (session != null && session.status == 'revoked') {
        return _error(403, 'Connection revoked', code: 'connection_revoked');
      }
    }

    final userId = _userFromBearer(request);

    if (route == 'ping' && method == 'GET') {
      return _ok({'pong': true, 'server_time': serverTime.toIso8601String()});
    }
    if (route == 'handshake' && method == 'GET') return _ok(_handshake(appKey));
    if (route == 'config' && method == 'GET') return _ok({'theme': 'dark'});

    if (route == 'connections/connect' && method == 'POST') {
      if (body['device_id'] == null || body['platform'] == null) {
        return _error(422, 'Invalid', code: 'validation_failed', errors: {
          'device_id': ['required'],
        });
      }
      FakeSession? session;
      for (final s in sessions.values) {
        if (s.appKey == appKey &&
            s.deviceId == body['device_id'] &&
            s.status != 'revoked') {
          session = s;
        }
      }
      final resumed = session != null;
      session ??= FakeSession(
        id: 'sess-${++_sessionSeq}',
        appKey: appKey,
        deviceId: body['device_id'] as String,
        platform: body['platform'] as String,
      );
      session
        ..status = 'active'
        ..deviceName = body['device_name'] as String? ?? session.deviceName
        ..appVersion = body['app_version'] as String? ?? session.appVersion
        ..userId = userId ?? session.userId;
      sessions[session.id] = session;
      return _ok({
        'connection': session.toJson(session.id),
        'heartbeat_interval': heartbeatInterval,
        'timeout': 90,
        'server_time': serverTime.toIso8601String(),
      }, status: resumed ? 200 : 201);
    }

    final heartbeat =
        RegExp(r'^connections/([^/]+)/heartbeat$').firstMatch(route);
    if (heartbeat != null && method == 'POST') {
      final session = sessions[heartbeat.group(1)];
      if (session == null)
        return _error(404, 'Connection not found',
            code: 'connection_not_found');
      if (session.status == 'revoked')
        return _error(403, 'Connection revoked', code: 'connection_revoked');
      session.status = 'active';
      session.userId ??= userId;
      final commands = List<Map<String, dynamic>>.from(session.pending);
      session.pending.clear();
      return _ok({
        'connection': session.toJson(connectionId),
        'commands': commands,
        'server_time': serverTime.toIso8601String(),
        'heartbeat_interval': heartbeatInterval,
      });
    }

    final disconnect =
        RegExp(r'^connections/([^/]+)/disconnect$').firstMatch(route);
    if (disconnect != null && method == 'POST') {
      final session = sessions[disconnect.group(1)];
      if (session == null)
        return _error(404, 'Connection not found',
            code: 'connection_not_found');
      session.status = 'disconnected';
      return _ok({'connection': session.toJson(connectionId)});
    }

    if (route == 'connections' && method == 'GET') {
      if (userId == null)
        return _error(401, 'Unauthenticated', code: 'unauthenticated');
      final list = sessions.values
          .where((s) => s.userId == userId)
          .map((s) => s.toJson(connectionId))
          .toList();
      return _ok({'connections': list});
    }

    final revokeOne = RegExp(r'^connections/([^/]+)$').firstMatch(route);
    if (revokeOne != null && method == 'DELETE') {
      if (userId == null)
        return _error(401, 'Unauthenticated', code: 'unauthenticated');
      final session = sessions[revokeOne.group(1)];
      if (session == null || session.userId != userId)
        return _error(404, 'Not found');
      revoke(session.id);
      return _ok({'connection': session.toJson(connectionId)});
    }

    if (route == 'connections' && method == 'DELETE') {
      if (userId == null)
        return _error(401, 'Unauthenticated', code: 'unauthenticated');
      var count = 0;
      for (final s in sessions.values.toList()) {
        if (s.userId == userId &&
            s.id != connectionId &&
            s.status == 'active') {
          revoke(s.id);
          count++;
        }
      }
      return _ok({'revoked': count});
    }

    if (route == 'auth/login' && method == 'POST') {
      final user = users[body['email']];
      if (user == null || user['password'] != body['password']) {
        return _error(401, 'Invalid credentials', code: 'unauthenticated');
      }
      if (connectionId != null) sessions[connectionId]?.userId = user['id'];
      return _ok({
        'user': _publicUser(user),
        'authorization': _issue(user['id'] as int, connectionId)
      });
    }

    if (route == 'auth/refresh' && method == 'POST') {
      final token = refreshTokens[body['refresh_token']];
      if (token == null)
        return _error(401, 'Invalid refresh token',
            code: 'invalid_refresh_token');
      if (token.revoked)
        return _error(401, 'Refresh token reused',
            code: 'refresh_token_reused');
      token.revoked = true;
      accessTokens.remove(token.accessToken);
      final user = users.values.firstWhere((u) => u['id'] == token.userId);
      return _ok({
        'user': _publicUser(user),
        'authorization':
            _issue(token.userId, connectionId ?? token.connectionId)
      });
    }

    if (route == 'auth/me' && method == 'GET') {
      if (userId == null)
        return _error(401, 'Unauthenticated', code: 'unauthenticated');
      final user = users.values.firstWhere((u) => u['id'] == userId);
      return _ok({'user': _publicUser(user)});
    }

    if (route == 'auth/logout' && method == 'POST') {
      if (userId == null)
        return _error(401, 'Unauthenticated', code: 'unauthenticated');
      final bearer = _bearer(request);
      accessTokens.remove(bearer);
      return _ok(null);
    }

    if (route == 'broadcasting/auth' && method == 'POST') {
      if (userId == null)
        return _error(401, 'Unauthenticated', code: 'unauthenticated');
      return _ok({'auth': 'key:signature'});
    }

    return _error(404, 'Route $method $route not found');
  }

  Map<String, dynamic> _handshake(String? appKey) {
    final endpoints = <String, String>{
      for (final entry in BridgeEndpoints.relativePaths.entries)
        entry.key: '$prefix/${entry.value}',
    };
    return {
      'server': {
        'name': name,
        'environment': 'testing',
        'url': 'https://$name.test',
        'timezone': 'UTC',
        'locale': 'en',
        'time': serverTime.toIso8601String(),
      },
      'bridge': {'version': '2.0.0', 'api_version': 'v1', 'prefix': prefix},
      'app': appKey == null
          ? null
          : {
              'key': appKey,
              'name': '$name App',
              'status': 'active',
              'min_version': minVersion,
              'latest_version': '9.9.9',
              'update_url': 'https://store.example.com/app',
              'platforms': null,
              'settings': <String, dynamic>{},
            },
      'features': {
        'auth': true,
        'registration': true,
        'social_auth': false,
        'two_factor': false,
        'devices': true,
        'broadcasting': broadcasting,
        'connections': true,
        'push': false,
      },
      if (!omitEndpoints) 'endpoints': endpoints,
      'broadcasting': broadcasting
          ? {
              'driver': 'reverb',
              'key': 'reverb-key',
              'host': 'ws.$name.test',
              'port': 443,
              'scheme': 'https',
              'cluster': null,
              'auth_endpoint': '$prefix/broadcasting/auth',
              'connection_channel': 'private-flutter.connections.{connection}',
              'user_channel': 'private-users.{user}',
            }
          : null,
      'connection': {'heartbeat_interval': heartbeatInterval, 'timeout': 90},
      'remote_config': {'theme': 'dark'},
    };
  }

  Map<String, dynamic> _issue(int userId, String? connectionId) {
    final access = '${++_tokenSeq}|access-$name';
    final refresh = 'refresh-$name-$_tokenSeq';
    accessTokens[access] = userId;
    refreshTokens[refresh] = _RefreshToken(userId, access, connectionId);
    return {
      'token_type': 'Bearer',
      'access_token': access,
      'refresh_token': refresh,
      'expires_in': 3600,
      'expires_at': serverTime.add(const Duration(hours: 1)).toIso8601String(),
      'refresh_expires_at':
          serverTime.add(const Duration(days: 30)).toIso8601String(),
    };
  }

  Map<String, dynamic> _publicUser(Map<String, dynamic> user) =>
      {'id': user['id'], 'name': user['name'], 'email': user['email']};

  String? _bearer(RecordedRequest request) {
    final header = request.header('Authorization');
    if (header == null || !header.startsWith('Bearer ')) return null;
    return header.substring(7);
  }

  int? _userFromBearer(RecordedRequest request) {
    final token = _bearer(request);
    return token == null ? null : accessTokens[token];
  }

  ResponseBody _ok(dynamic data, {int status = 200}) => json(status, {
        'success': true,
        'message': 'OK',
        'data': data,
        'errors': null,
        'meta': {
          'timestamp': serverTime.toIso8601String(),
          'api_version': 'v1',
          'trace_id': 't'
        },
      });

  ResponseBody _error(int status, String message,
          {String? code, dynamic errors}) =>
      json(status, {
        'success': false,
        'message': message,
        'data': null,
        'errors': errors,
        'meta': {
          'timestamp': serverTime.toIso8601String(),
          'api_version': 'v1',
          'trace_id': 't',
          if (code != null) 'error_code': code,
        },
      });

  /// Build a JSON response with the bridge headers.
  ResponseBody json(int status, Object? body,
      {Map<String, List<String>> headers = const {}}) {
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        'x-flutter-server-time': [serverTime.toIso8601String()],
        'x-laravel-flutter-bridge': ['2.0.0'],
        ...headers,
      },
    );
  }
}
