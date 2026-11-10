import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adapter answering every request with a programmable handler.
class _ScriptedAdapter implements HttpClientAdapter {
  final FutureOr<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  _ScriptedAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    await Future<void>.delayed(Duration.zero);
    return handler(options);
  }
}

ResponseBody _json(int status, Object? body,
        {Map<String, List<String>> headers = const {}}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...headers,
      },
    );

Map<String, dynamic> _envelope(
        {dynamic data, String message = 'x', String? code, dynamic errors}) =>
    {
      'success': code == null,
      'message': message,
      'data': data,
      'errors': errors,
      'meta': {'trace_id': 't', if (code != null) 'error_code': code},
    };

Future<LaravelException> _errorFor(ResponseBody Function() response) async {
  final client = LaravelClient(
    options:
        const LaravelOptions(baseUrl: 'http://api.test', enableLogging: false),
  );
  client.rawDio.httpClientAdapter = _ScriptedAdapter((_) => response());
  try {
    await client.get<dynamic>('api/anything');
  } on LaravelException catch (e) {
    return e;
  }
  fail('Expected a LaravelException');
}

String? _auth(RequestOptions o) => o.headers['Authorization']?.toString();

void main() {
  group('ErrorInterceptor', () {
    test('426 upgrade_required → LaravelUpgradeRequiredException', () async {
      final e = await _errorFor(() => _json(
          426,
          _envelope(code: 'upgrade_required', message: 'Update', errors: {
            'current_version': '1.0.0',
            'min_version': '1.2.0',
            'latest_version': '1.5.0',
            'update_url': 'https://store',
          })));
      expect(e, isA<LaravelUpgradeRequiredException>());
      final upgrade = e as LaravelUpgradeRequiredException;
      expect(upgrade.statusCode, 426);
      expect(upgrade.errorCode, 'upgrade_required');
      expect(upgrade.minVersion, '1.2.0');
      expect(upgrade.latestVersion, '1.5.0');
      expect(upgrade.updateUrl, 'https://store');
      expect(upgrade.currentVersion, '1.0.0');
      expect(upgrade.message, 'Update');
    });

    test('403 connection_revoked / app key errors', () async {
      final revoked = await _errorFor(
          () => _json(403, _envelope(code: 'connection_revoked')));
      expect(revoked, isA<LaravelConnectionRevokedException>());
      expect(revoked, isA<LaravelPermissionException>());
      expect(revoked.errorCode, 'connection_revoked');

      for (final code in [
        'app_key_required',
        'invalid_app_key',
        'app_suspended'
      ]) {
        final e = await _errorFor(() => _json(403, _envelope(code: code)));
        expect(e, isA<LaravelAppKeyException>(), reason: code);
        expect(e.errorCode, code);
      }
      expect(
          (await _errorFor(() => _json(403, _envelope(code: 'app_suspended'))))
              as LaravelAppKeyException,
          predicate<LaravelAppKeyException>((e) => e.isSuspended));

      final plain = await _errorFor(() => _json(403, _envelope()));
      expect(plain.runtimeType, LaravelPermissionException);
    });

    test('404 connection_not_found vs plain 404', () async {
      expect(
          await _errorFor(
              () => _json(404, _envelope(code: 'connection_not_found'))),
          isA<LaravelConnectionNotFoundException>());
      final plain = await _errorFor(() => _json(404, _envelope()));
      expect(plain.runtimeType, LaravelNotFoundException);
    });

    test('401 carries the error code', () async {
      final e = await _errorFor(
          () => _json(401, _envelope(code: 'refresh_token_reused')));
      expect(e, isA<LaravelAuthenticationException>());
      expect(
          (e as LaravelAuthenticationException).isRefreshTokenInvalid, isTrue);
    });

    test('422 validation errors', () async {
      final e = await _errorFor(() => _json(
          422,
          _envelope(code: 'validation_failed', errors: {
            'email': ['required'],
          })));
      expect(e, isA<LaravelValidationError>());
      expect((e as LaravelValidationError).first('email'), 'required');
      expect(e.errorCode, 'validation_failed');
    });

    test('429 reads Retry-After', () async {
      final e = await _errorFor(
          () => _json(429, _envelope(code: 'too_many_requests'), headers: {
                'retry-after': ['17'],
              }));
      expect(e, isA<LaravelRateLimitException>());
      expect((e as LaravelRateLimitException).retryAfter,
          const Duration(seconds: 17));
    });

    test('503 → maintenance, other 5xx keep their status code', () async {
      final maintenance = await _errorFor(
          () => _json(503, _envelope(code: 'maintenance'), headers: {
                'retry-after': ['60'],
              }));
      expect(maintenance, isA<LaravelMaintenanceException>());
      expect(maintenance, isA<LaravelServerException>());
      expect((maintenance as LaravelMaintenanceException).retryAfter,
          const Duration(seconds: 60));

      final bad = await _errorFor(() => _json(502, {'message': 'Bad gateway'}));
      expect(bad, isA<LaravelServerException>());
      expect(bad.statusCode, 502);
      expect(bad.message, 'Bad gateway');
    });

    test('connection errors → LaravelNetworkException', () async {
      final client = LaravelClient(
          options: const LaravelOptions(
              baseUrl: 'http://api.test', enableLogging: false));
      client.rawDio.httpClientAdapter =
          _ScriptedAdapter((o) => throw DioException(
                requestOptions: o,
                type: DioExceptionType.connectionError,
                error: Exception('refused'),
              ));
      await expectLater(
          client.get<dynamic>('x'), throwsA(isA<LaravelNetworkException>()));
    });

    test('queueIfOffline enqueues on network failure', () async {
      final client = LaravelClient(
          options: const LaravelOptions(
              baseUrl: 'http://api.test', enableLogging: false));
      client.rawDio.httpClientAdapter =
          _ScriptedAdapter((o) => throw DioException(
                requestOptions: o,
                type: DioExceptionType.connectionTimeout,
              ));
      await expectLater(
        client.post<dynamic>('api/posts', data: {'a': 1}, queueIfOffline: true),
        throwsA(isA<LaravelNetworkException>()),
      );
      expect(client.offlineQueue.length, 1);
    });

    test('parseRetryAfter supports HTTP dates', () {
      final now = DateTime.utc(2015, 10, 21, 7, 27, 0);
      expect(
        ErrorInterceptor.parseRetryAfter(
            'Wed, 21 Oct 2015 07:28:00 GMT', () => now),
        const Duration(seconds: 60),
      );
      expect(ErrorInterceptor.parseRetryAfter('garbage'), isNull);
    });
  });

  group('ConnectionInterceptor', () {
    test('adds protocol headers and reads the server clock', () async {
      String? connectionId;
      final serverTime = DateTime.utc(2026, 11, 9, 10);
      final localNow = DateTime.utc(2026, 11, 9, 9, 59, 50);
      final client = LaravelClient(
        options: const LaravelOptions(
            baseUrl: 'http://api.test/', appKey: 'fba_k', enableLogging: false),
        connectionIdProvider: () => connectionId,
        clock: () => localNow,
      );
      final adapter =
          _ScriptedAdapter((_) => _json(200, _envelope(data: {}), headers: {
                'x-flutter-server-time': [serverTime.toIso8601String()],
                'x-laravel-flutter-bridge': ['2.0.0'],
              }));
      client.rawDio.httpClientAdapter = adapter;

      await client.get<dynamic>('api/flutter/ping');
      var sent = adapter.requests.last;
      expect(sent.uri.toString(), 'http://api.test/api/flutter/ping');
      expect(sent.headers['X-Flutter-Bridge-Version'], kBridgeVersion);
      expect(sent.headers['X-Flutter-App-Key'], 'fba_k');
      expect(sent.headers.containsKey('X-Flutter-Connection-Id'), isFalse);
      expect(client.serverClockOffset, const Duration(seconds: 10));
      expect(client.serverNow(), serverTime);
      expect(client.connectionInterceptor.serverBridgeVersion, '2.0.0');

      connectionId = 'sess-1';
      await client.get<dynamic>('/api/flutter/ping');
      sent = adapter.requests.last;
      expect(sent.uri.toString(), 'http://api.test/api/flutter/ping');
      expect(sent.headers['X-Flutter-Connection-Id'], 'sess-1');
    });
  });

  group('AuthInterceptor', () {
    test(
        'concurrent 401s trigger a single refresh and every request is retried',
        () async {
      final storage = InMemoryTokenStorage();
      await storage.saveAccessToken('old');
      var refreshCalls = 0;
      late LaravelClient client;
      client = LaravelClient(
        options: const LaravelOptions(
            baseUrl: 'http://api.test', enableLogging: false),
        tokenStorage: storage,
        onRefreshToken: () async {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await storage.saveAccessToken('new');
          return 'new';
        },
      );
      final adapter = _ScriptedAdapter((o) {
        if (_auth(o) == 'Bearer new')
          return _json(200, _envelope(data: {'ok': o.path}));
        return _json(401, _envelope(code: 'unauthenticated'));
      });
      client.rawDio.httpClientAdapter = adapter;

      final results = await Future.wait([
        client.get<Map<String, dynamic>>('a'),
        client.get<Map<String, dynamic>>('b'),
        client.get<Map<String, dynamic>>('c'),
      ]);
      expect(refreshCalls, 1);
      expect(results.map((r) => r.data!['ok']), ['a', 'b', 'c']);
    });

    test('refresh failure does not dead-lock and clears the session locally',
        () async {
      final storage = InMemoryTokenStorage();
      await storage.saveAccessToken('expired');
      await storage.saveRefreshToken('revoked-refresh');
      var expiredCalls = 0;

      late AuthManager<Map<String, dynamic>> auth;
      final client = LaravelClient(
        options: const LaravelOptions(
            baseUrl: 'http://api.test', enableLogging: false),
        tokenStorage: storage,
        onRefreshToken: () => auth.refreshToken(),
        onSessionExpired: () => auth.expireSession(),
      );
      auth = AuthManager<Map<String, dynamic>>(
        client: client,
        tokenStorage: storage,
        userParser: (j) => j,
        onSessionExpired: () => expiredCalls++,
      );

      final adapter = _ScriptedAdapter((o) {
        if (o.path.endsWith('auth/refresh')) {
          return _json(401, _envelope(code: 'invalid_refresh_token'));
        }
        // logout or anything else: always 401
        return _json(401, _envelope(code: 'unauthenticated'));
      });
      client.rawDio.httpClientAdapter = adapter;

      await expectLater(
        client
            .get<dynamic>('api/flutter/auth/me')
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<LaravelAuthenticationException>()),
      );

      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(auth.currentState, isA<Unauthenticated>());
      expect(expiredCalls, 1);
      // No network logout was attempted.
      expect(adapter.requests.where((r) => r.path.contains('logout')), isEmpty);

      final refresh =
          adapter.requests.firstWhere((r) => r.path.endsWith('auth/refresh'));
      expect(refresh.headers.containsKey('Authorization'), isFalse,
          reason: 'refresh is public: no stale bearer');
      expect(refresh.data, containsPair('refresh_token', 'revoked-refresh'));

      // Explicit logout with a 401 must also complete.
      await storage.saveAccessToken('still-bad');
      await auth.logout().timeout(const Duration(seconds: 5));
      expect(await storage.getAccessToken(), isNull);
    });

    test('never refreshes for auth endpoints or no-refresh error codes',
        () async {
      var refreshCalls = 0;
      final client = LaravelClient(
        options: const LaravelOptions(
            baseUrl: 'http://api.test', enableLogging: false),
        onRefreshToken: () async {
          refreshCalls++;
          return 'new';
        },
      );
      client.rawDio.httpClientAdapter = _ScriptedAdapter((o) {
        if (o.path == 'api/x')
          return _json(403, _envelope(code: 'connection_revoked'));
        if (o.path == 'api/y')
          return _json(401, _envelope(code: 'refresh_token_reused'));
        return _json(401, _envelope(code: 'unauthenticated'));
      });

      await expectLater(client.post<dynamic>('api/flutter/auth/login'),
          throwsA(isA<LaravelAuthenticationException>()));
      await expectLater(client.post<dynamic>('api/flutter/auth/2fa/verify'),
          throwsA(isA<LaravelAuthenticationException>()));
      await expectLater(
        client.get<dynamic>('api/z',
            requestOptions: Options(extra: {'skipAuthRefresh': true})),
        throwsA(isA<LaravelAuthenticationException>()),
      );
      await expectLater(client.get<dynamic>('api/x'),
          throwsA(isA<LaravelConnectionRevokedException>()));
      await expectLater(client.get<dynamic>('api/y'),
          throwsA(isA<LaravelAuthenticationException>()));
      expect(refreshCalls, 0);
    });

    test('a retried request that fails again is not refreshed twice', () async {
      var refreshCalls = 0;
      final client = LaravelClient(
        options: const LaravelOptions(
            baseUrl: 'http://api.test', enableLogging: false),
        onRefreshToken: () async {
          refreshCalls++;
          return 'new-$refreshCalls';
        },
      );
      client.rawDio.httpClientAdapter = _ScriptedAdapter(
          (o) => _json(401, _envelope(code: 'unauthenticated')));
      await expectLater(client.get<dynamic>('api/x'),
          throwsA(isA<LaravelAuthenticationException>()));
      expect(refreshCalls, 1);
    });
  });
}
