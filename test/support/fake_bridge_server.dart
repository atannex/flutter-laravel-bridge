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

/// An email sent by [FakeBridgeServer] (password reset / verification code).
class FakeMail {
  final String to;

  /// `reset` or `verify`.
  final String purpose;
  final String code;

  FakeMail(this.to, this.purpose, this.code);

  @override
  String toString() => 'FakeMail($purpose → $to: $code)';
}

class _FakeCode {
  final String code;
  final DateTime expiresAt;
  int attempts = 0;

  _FakeCode(this.code, this.expiresAt);
}

class _FakeResetToken {
  final String email;
  final DateTime expiresAt;

  _FakeResetToken(this.email, this.expiresAt);
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
      'password': 'secret',
      'email_verified_at': '2026-01-01T00:00:00.000Z',
      'passkeys': <Map<String, dynamic>>[
        {
          'id': 'pk-1',
          'name': 'MacBook',
          'created_at': '2026-05-01T08:00:00.000Z',
          'last_used_at': '2026-11-01T08:00:00.000Z',
        },
        {
          'id': 'pk-2',
          'name': 'iPhone',
          'created_at': '2026-06-01T08:00:00.000Z',
          'last_used_at': null,
        },
      ],
    },
    'b@example.com': {
      'id': 2,
      'name': 'Bob',
      'email': 'b@example.com',
      'password': 'secret',
      'email_verified_at': null,
      'passkeys': <Map<String, dynamic>>[],
    },
  };

  // --- Fortify over the bridge (docs/FORTIFY.md) ---------------------------

  /// `features.fortify` published by the handshake and `GET config`; every
  /// endpoint of a feature switched off here answers 404 `feature_disabled`.
  final Map<String, dynamic> fortify = {
    'installed': true,
    'enabled': true,
    'registration': true,
    'reset_passwords': true,
    'email_verification': true,
    'update_profile_information': true,
    'update_passwords': true,
    'two_factor_authentication': true,
    'two_factor_confirm': true,
    'two_factor_confirm_password': true,
    'passkeys': true,
    'passkeys_confirm_password': true,
    'username': 'email',
    'lowercase_usernames': false,
    'reset_channel': 'code',
    'password_min': 8,
    'password_timeout': 10800,
    'codes': {'length': 6, 'ttl': 600},
  };

  /// Whether `features.fortify` is published at all (a 2.1 server: no).
  bool advertiseFortify = true;

  /// Emails "sent" by the server.
  final List<FakeMail> outbox = [];

  /// The code an authenticator app shows right now.
  String totpCode = '123456';
  int maxCodeAttempts = 5;
  int resetTokenTtl = 600;

  /// Forgot-password requests allowed per email before 429.
  int forgotPasswordLimit = 5;

  /// Fortify broker tokens (from the reset link) → email.
  final Map<String, String> brokerTokens = {};

  Duration _elapsed = Duration.zero;
  final Map<String, _FakeCode> _codes = {};
  final Map<String, _FakeResetToken> _resetTokens = {};
  final Map<String, DateTime> _passwordConfirmedAt = {};
  final Map<String, int> _forgotCounts = {};
  int _codeSeq = 0;

  /// Server clock (moves with [advance]).
  DateTime get now => serverTime.add(_elapsed);

  /// Let server time pass (code TTLs, password confirmation window).
  void advance(Duration duration) => _elapsed += duration;

  /// Last code emailed to [email] for [purpose] (`reset` / `verify`).
  String? lastCode(String email, [String purpose = 'reset']) {
    for (final mail in outbox.reversed) {
      if (mail.to == email && mail.purpose == purpose) return mail.code;
    }
    return null;
  }

  int get _codeTtl => ((fortify['codes'] as Map?)?['ttl'] as int?) ?? 600;
  int get _passwordTimeout => (fortify['password_timeout'] as int?) ?? 10800;

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
    if (route == 'config' && method == 'GET') {
      return _ok({
        'theme': 'dark',
        if (advertiseFortify) 'features': {'fortify': fortify},
      });
    }

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
      if (_twoFactorEnabled(user)) {
        final code = body['code'];
        final recovery = body['recovery_code'];
        if (code == null && recovery == null) {
          return _challenge('two_factor_required', 'Two-factor code required.');
        }
        final codes = user['two_factor_recovery_codes'] as List<String>;
        if (code != null && code != totpCode) {
          return _challenge('two_factor_invalid', 'The code is invalid.');
        }
        if (code == null && !codes.remove(recovery)) {
          return _challenge(
              'two_factor_invalid', 'The recovery code is invalid.');
        }
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

    final fortifyResponse = _fortifyRoute(request, route, method, body, userId);
    if (fortifyResponse != null) return fortifyResponse;

    return _error(404, 'Route $method $route not found');
  }

  ResponseBody _challenge(String code, String message) => json(422, {
        'success': false,
        'message': message,
        'data': {'two_factor': true},
        'errors': {
          'code': [message]
        },
        'meta': {'trace_id': 't', 'error_code': code},
      });

  bool _twoFactorEnabled(Map<String, dynamic> user) =>
      user['two_factor_secret'] != null &&
      (fortify['two_factor_confirm'] != true ||
          user['two_factor_confirmed_at'] != null);

  bool _on(String feature) => fortify[feature] == true;

  ResponseBody _disabled(String feature) =>
      _error(404, 'This feature is not available.',
          code: 'feature_disabled', errors: {'feature': feature});

  String _issueCode(String purpose, String email) {
    final length = ((fortify['codes'] as Map?)?['length'] as int?) ?? 6;
    final code = '${++_codeSeq}'.padLeft(length, '0');
    _codes['$purpose:$email'] =
        _FakeCode(code, now.add(Duration(seconds: _codeTtl)));
    outbox.add(FakeMail(email, purpose, code));
    return code;
  }

  /// Check [given] against the pending [purpose] code of [email]; `null` when
  /// it matches (and is consumed), otherwise the error response.
  ResponseBody? _checkCode(String purpose, String email, Object? given) {
    final key = '$purpose:$email';
    final pending = _codes[key];
    if (pending == null) {
      return _error(422, 'The code is invalid.', code: 'code_invalid', errors: {
        'code': ['The code is invalid.']
      });
    }
    if (pending.attempts >= maxCodeAttempts) {
      return _error(423, 'Too many attempts. Request a new code.',
          code: 'code_locked',
          errors: {
            'code': ['Too many attempts. Request a new code.']
          });
    }
    if (!now.isBefore(pending.expiresAt)) {
      _codes.remove(key);
      return _error(422, 'The code has expired.',
          code: 'code_expired',
          errors: {
            'code': ['The code has expired.']
          });
    }
    if (pending.code != given?.toString()) {
      pending.attempts++;
      return _error(422, 'The code is invalid.', code: 'code_invalid', errors: {
        'code': ['The code is invalid.']
      });
    }
    _codes.remove(key);
    return null;
  }

  ResponseBody? _validatePassword(Map<String, dynamic> body) {
    final password = body['password']?.toString() ?? '';
    final min = (fortify['password_min'] as int?) ?? 8;
    if (password.length < min) {
      return _error(422, 'The password is too short.',
          code: 'validation_failed',
          errors: {
            'password': ['The password must be at least $min characters.']
          });
    }
    if (password != body['password_confirmation']) {
      return _error(422, 'The password confirmation does not match.',
          code: 'validation_failed',
          errors: {
            'password': ['The password field confirmation does not match.']
          });
    }
    return null;
  }

  bool _passwordRecentlyConfirmed(String? bearer) {
    final at = bearer == null ? null : _passwordConfirmedAt[bearer];
    return at != null &&
        now.isBefore(at.add(Duration(seconds: _passwordTimeout)));
  }

  /// Fortify `password.confirm`: 423 unless the token confirmed recently.
  ResponseBody? _requireConfirmedPassword(RecordedRequest request,
      [String option = 'two_factor_confirm_password']) {
    if (!_on(option)) return null;
    if (_passwordRecentlyConfirmed(_bearer(request))) return null;
    return _error(423, 'Password confirmation required.',
        code: 'password_confirmation_required');
  }

  /// Revoke every bridge token and connection of [userId], but [keepToken].
  void _revokeUser(int userId, {String? keepToken}) {
    accessTokens.removeWhere((token, id) => id == userId && token != keepToken);
    String? keepConnection;
    for (final entry in refreshTokens.entries) {
      if (entry.value.userId != userId) continue;
      if (entry.value.accessToken == keepToken) {
        keepConnection = entry.value.connectionId;
        continue;
      }
      entry.value.revoked = true;
    }
    for (final session in sessions.values.toList()) {
      if (session.userId == userId &&
          session.status != 'revoked' &&
          session.id != keepConnection) {
        revoke(session.id);
      }
    }
  }

  Map<String, dynamic> _userById(int id) =>
      users.values.firstWhere((u) => u['id'] == id);

  ResponseBody? _fortifyRoute(RecordedRequest request, String route,
      String method, Map<String, dynamic> body, int? userId) {
    // ---- guest ----
    if (route == 'auth/register' && method == 'POST') {
      if (!_on('registration')) return _disabled('registration');
      final email = body['email']?.toString() ?? '';
      if (users.containsKey(email)) {
        return _error(422, 'The email has already been taken.',
            code: 'validation_failed',
            errors: {
              'email': ['The email has already been taken.']
            });
      }
      final user = <String, dynamic>{
        'id': users.length + 100,
        'name': body['name'],
        'email': email,
        'password': body['password'],
        'email_verified_at': null,
        'passkeys': <Map<String, dynamic>>[],
      };
      users[email] = user;
      final verify = _on('email_verification');
      if (verify) _issueCode('verify', email);
      final connectionId = request.header('X-Flutter-Connection-Id');
      return _ok({
        'user': _publicUser(user),
        'authorization': _issue(user['id'] as int, connectionId),
        'email_verification_required': verify,
      });
    }

    if (route == 'auth/forgot-password' && method == 'POST') {
      if (!_on('reset_passwords')) return _disabled('reset_passwords');
      final email = body['email']?.toString() ?? '';
      final count = _forgotCounts[email] = (_forgotCounts[email] ?? 0) + 1;
      if (count > forgotPasswordLimit) {
        return _error(429, 'Too many requests.', code: 'too_many_requests');
      }
      if (users.containsKey(email)) _issueCode('reset', email);
      return _ok({'sent': true, 'channel': 'code', 'expires_in': _codeTtl});
    }

    if (route == 'auth/reset-password/verify-code' && method == 'POST') {
      if (!_on('reset_passwords')) return _disabled('reset_passwords');
      final email = body['email']?.toString() ?? '';
      final failure = _checkCode('reset', email, body['code']);
      if (failure != null) return failure;
      final token = 'reset-${++_codeSeq}-$email';
      _resetTokens[token] =
          _FakeResetToken(email, now.add(Duration(seconds: resetTokenTtl)));
      return _ok({'reset_token': token, 'expires_in': resetTokenTtl});
    }

    if (route == 'auth/reset-password' && method == 'POST') {
      if (!_on('reset_passwords')) return _disabled('reset_passwords');
      final email = body['email']?.toString() ?? '';
      final resetToken = body['reset_token']?.toString();
      final brokerToken = body['token']?.toString();
      var valid = false;
      if (resetToken != null) {
        final pending = _resetTokens[resetToken];
        valid = pending != null &&
            pending.email == email &&
            now.isBefore(pending.expiresAt);
      } else if (brokerToken != null) {
        valid = brokerTokens[brokerToken] == email;
      }
      if (!valid || !users.containsKey(email)) {
        return _error(422, 'This password reset token is invalid.',
            code: 'reset_token_invalid',
            errors: {
              'email': ['This password reset token is invalid.']
            });
      }
      final failure = _validatePassword(body);
      if (failure != null) return failure;
      if (resetToken != null) _resetTokens.remove(resetToken);
      if (brokerToken != null) brokerTokens.remove(brokerToken);
      final user = users[email]!;
      user['password'] = body['password'];
      _revokeUser(user['id'] as int);
      return _ok({'reset': true});
    }

    // ---- signed in ----
    const authenticated = {
      'auth/email/verification-notification',
      'auth/email/verify',
      'auth/user/profile-information',
      'auth/user/password',
      'auth/user/confirm-password',
      'auth/user/confirmed-password-status',
      'auth/user/two-factor-authentication',
      'auth/user/two-factor-qr-code',
      'auth/user/two-factor-secret-key',
      'auth/user/confirmed-two-factor-authentication',
      'auth/user/two-factor-recovery-codes',
      'auth/user/passkeys',
    };
    final passkeyMatch =
        RegExp(r'^auth/user/passkeys/([^/]+)$').firstMatch(route);
    if (!authenticated.contains(route) && passkeyMatch == null) return null;
    if (userId == null) {
      return _error(401, 'Unauthenticated', code: 'unauthenticated');
    }
    final user = _userById(userId);
    final email = user['email'] as String;
    final bearer = _bearer(request);

    if (route == 'auth/email/verification-notification' && method == 'POST') {
      if (!_on('email_verification')) return _disabled('email_verification');
      if (user['email_verified_at'] != null) {
        return _error(409, 'Your email address is already verified.',
            code: 'already_verified');
      }
      _issueCode('verify', email);
      return _ok({'sent': true, 'expires_in': _codeTtl});
    }

    if (route == 'auth/email/verify' && method == 'POST') {
      if (!_on('email_verification')) return _disabled('email_verification');
      if (user['email_verified_at'] != null) {
        return _error(409, 'Your email address is already verified.',
            code: 'already_verified');
      }
      final failure = _checkCode('verify', email, body['code']);
      if (failure != null) return failure;
      user['email_verified_at'] = now.toIso8601String();
      return _ok({'user': _publicUser(user)});
    }

    if (route == 'auth/user/profile-information' && method == 'PUT') {
      if (!_on('update_profile_information')) {
        return _disabled('update_profile_information');
      }
      final name = body['name']?.toString() ?? '';
      final newEmail = body['email']?.toString() ?? '';
      final errors = <String, List<String>>{
        if (name.isEmpty) 'name': ['The name field is required.'],
        if (!newEmail.contains('@'))
          'email': ['The email field must be a valid email address.']
        else if (newEmail != email && users.containsKey(newEmail))
          'email': ['The email has already been taken.'],
      };
      if (errors.isNotEmpty) {
        return _error(422, errors.values.first.first,
            code: 'validation_failed', errors: errors);
      }
      final emailChanged = newEmail != email;
      user['name'] = name;
      if (emailChanged) {
        users.remove(email);
        user['email'] = newEmail;
        user['email_verified_at'] = null;
        users[newEmail] = user;
      }
      return _ok({
        'user': _publicUser(user),
        'email_verification_required':
            emailChanged && _on('email_verification'),
      });
    }

    if (route == 'auth/user/password' && method == 'PUT') {
      if (!_on('update_passwords')) return _disabled('update_passwords');
      if (body['current_password'] != user['password']) {
        return _error(422, 'The provided password is incorrect.',
            code: 'validation_failed',
            errors: {
              'current_password': ['The provided password is incorrect.']
            });
      }
      final failure = _validatePassword(body);
      if (failure != null) return failure;
      user['password'] = body['password'];
      if (body['revoke_other_sessions'] == true) {
        _revokeUser(userId, keepToken: bearer);
      }
      return _ok({'updated': true});
    }

    if (route == 'auth/user/confirm-password' && method == 'POST') {
      if (body['password'] != user['password']) {
        return _error(422, 'The provided password was incorrect.',
            code: 'password_invalid',
            errors: {
              'password': ['The provided password was incorrect.']
            });
      }
      _passwordConfirmedAt[bearer!] = now;
      return _ok({'confirmed': true, 'expires_in': _passwordTimeout});
    }

    if (route == 'auth/user/confirmed-password-status' && method == 'GET') {
      final at = _passwordConfirmedAt[bearer];
      final confirmed = _passwordRecentlyConfirmed(bearer);
      return _ok({
        'confirmed': confirmed,
        'expires_in': confirmed
            ? at!
                .add(Duration(seconds: _passwordTimeout))
                .difference(now)
                .inSeconds
            : 0,
      });
    }

    if (route.startsWith('auth/user/two-factor') ||
        route == 'auth/user/confirmed-two-factor-authentication') {
      if (!_on('two_factor_authentication')) {
        return _disabled('two_factor_authentication');
      }
      final requiresConfirmation = _on('two_factor_confirm');

      if (route == 'auth/user/two-factor-authentication' && method == 'POST') {
        final locked = _requireConfirmedPassword(request);
        if (locked != null) return locked;
        if (user['two_factor_secret'] == null) {
          user['two_factor_secret'] = 'JBSWY3DPEHPK3PXP';
          user['two_factor_recovery_codes'] = _recoveryCodes();
          user['two_factor_confirmed_at'] =
              requiresConfirmation ? null : now.toIso8601String();
        }
        final confirmed = user['two_factor_confirmed_at'] != null;
        return _ok({
          'enabled': true,
          'confirmed': confirmed,
          'requires_confirmation': requiresConfirmation,
        });
      }

      if (route == 'auth/user/two-factor-authentication' &&
          method == 'DELETE') {
        final locked = _requireConfirmedPassword(request);
        if (locked != null) return locked;
        user
          ..['two_factor_secret'] = null
          ..['two_factor_recovery_codes'] = null
          ..['two_factor_confirmed_at'] = null;
        return _ok({'enabled': false});
      }

      final secret = user['two_factor_secret'] as String?;
      ResponseBody notEnabled() =>
          _error(404, 'Two-factor authentication is not enabled.',
              code: 'two_factor_not_enabled');

      if (route == 'auth/user/two-factor-qr-code' && method == 'GET') {
        if (secret == null) return notEnabled();
        return _ok({
          'svg': '<svg xmlns="http://www.w3.org/2000/svg"><rect/></svg>',
          'url': 'otpauth://totp/$name:${Uri.encodeComponent(email)}'
              '?secret=$secret&issuer=$name',
        });
      }

      if (route == 'auth/user/two-factor-secret-key' && method == 'GET') {
        if (secret == null) return notEnabled();
        return _ok({'secret_key': secret});
      }

      if (route == 'auth/user/confirmed-two-factor-authentication' &&
          method == 'POST') {
        if (secret == null) return notEnabled();
        if (body['code'] != totpCode) {
          return _error(
              422,
              'The provided two factor authentication code '
              'was invalid.',
              code: 'two_factor_invalid',
              errors: {
                'code': [
                  'The provided two factor authentication code was invalid.'
                ]
              });
        }
        user['two_factor_confirmed_at'] = now.toIso8601String();
        return _ok({'confirmed': true, 'user': _publicUser(user)});
      }

      if (route == 'auth/user/two-factor-recovery-codes') {
        final locked = _requireConfirmedPassword(request);
        if (locked != null) return locked;
        if (secret == null) return notEnabled();
        if (method == 'POST') {
          user['two_factor_recovery_codes'] = _recoveryCodes();
        } else if (method != 'GET') {
          return null;
        }
        return _ok({'recovery_codes': user['two_factor_recovery_codes']});
      }
      return null;
    }

    if (route == 'auth/user/passkeys' || passkeyMatch != null) {
      if (!_on('passkeys')) return _disabled('passkeys');
      final passkeys = user['passkeys'] as List<Map<String, dynamic>>;
      if (passkeyMatch == null) {
        return method == 'GET' ? _ok(passkeys) : null;
      }
      final id = Uri.decodeComponent(passkeyMatch.group(1)!);
      final index = passkeys.indexWhere((p) => p['id'] == id);
      if (index < 0) return _error(404, 'Passkey not found.');
      if (method == 'PATCH') {
        final newName = body['name']?.toString() ?? '';
        if (newName.isEmpty) {
          return _error(422, 'The name field is required.',
              code: 'validation_failed',
              errors: {
                'name': ['The name field is required.']
              });
        }
        passkeys[index]['name'] = newName;
        return _ok(passkeys[index]);
      }
      if (method == 'DELETE') {
        final locked =
            _requireConfirmedPassword(request, 'passkeys_confirm_password');
        if (locked != null) return locked;
        passkeys.removeAt(index);
        return _ok({'deleted': true});
      }
    }
    return null;
  }

  List<String> _recoveryCodes() =>
      List.generate(8, (i) => 'rc-${++_codeSeq}-$i');

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
        if (advertiseFortify) 'fortify': fortify,
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

  Map<String, dynamic> _publicUser(Map<String, dynamic> user) => {
        'id': user['id'],
        'name': user['name'],
        'email': user['email'],
        'email_verified': user['email_verified_at'] != null,
        'email_verified_at': user['email_verified_at'],
        'two_factor_enabled': _twoFactorEnabled(user),
        'two_factor_pending_confirmation': user['two_factor_secret'] != null &&
            user['two_factor_confirmed_at'] == null &&
            fortify['two_factor_confirm'] == true,
        'passkeys_count': (user['passkeys'] as List?)?.length ?? 0,
      };

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
