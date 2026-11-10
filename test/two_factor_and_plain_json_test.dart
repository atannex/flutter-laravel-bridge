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

ResponseBody _json(int status, Object? body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

Map<String, dynamic> _challenge(String code, String message) => {
      'success': false,
      'message': message,
      'data': {'two_factor': true},
      'errors': {
        'code': [message]
      },
      'meta': {'trace_id': 't', 'error_code': code},
    };

Map<String, dynamic> _loginOk() => {
      'success': true,
      'message': 'Logged in',
      'data': {
        'user': {'id': 7, 'email': 'a@b.test', 'team': 'core'},
        'authorization': {
          'access_token': 'access-1',
          'refresh_token': 'refresh-1',
          'expires_in': 3600,
        },
      },
      'errors': null,
      'meta': {'trace_id': 't'},
    };

LaravelClient _client(_ScriptedAdapter adapter, {TokenStorage? storage}) {
  final client = LaravelClient(
    options:
        const LaravelOptions(baseUrl: 'http://api.test', enableLogging: false),
    tokenStorage: storage,
  );
  client.rawDio.httpClientAdapter = adapter;
  return client;
}

void main() {
  group('Two-step sign-in', () {
    late InMemoryTokenStorage storage;
    late _ScriptedAdapter adapter;
    late AuthManager<Map<String, dynamic>> auth;

    setUp(() {
      storage = InMemoryTokenStorage();
      adapter = _ScriptedAdapter((o) {
        final body = o.data as Map;
        final code = body['code'] ?? body['recovery_code'];
        if (code == null) {
          return _json(422,
              _challenge('two_factor_required', 'Two-factor code required.'));
        }
        if (code != '123456' && code != 'recovery-abc') {
          return _json(
              422, _challenge('two_factor_invalid', 'The code is invalid.'));
        }
        return _json(200, _loginOk());
      });
      auth = AuthManager<Map<String, dynamic>>(
        client: _client(adapter, storage: storage),
        tokenStorage: storage,
        userParser: (j) => j,
        proactiveRefresh: false,
      );
    });

    tearDown(() => auth.dispose());

    test('two_factor_required → exception, Unauthenticated, no tokens',
        () async {
      final states = <AuthState>[];
      final sub = auth.stateStream.listen(states.add);

      LaravelTwoFactorRequiredException? error;
      try {
        await auth.login(email: 'a@b.test', password: 'secret');
      } on LaravelTwoFactorRequiredException catch (e) {
        error = e;
      }
      await sub.cancel();

      expect(error, isNotNull);
      expect(error, isA<LaravelValidationError>());
      expect(error!.invalid, isFalse);
      expect(error.errorCode, LaravelErrorCode.twoFactorRequired);
      expect(error.statusCode, 422);
      expect(error.message, 'Two-factor code required.');
      expect(error.first('code'), 'Two-factor code required.');

      expect(auth.currentState, isA<Unauthenticated>());
      expect(states.whereType<AuthError>(), isEmpty);
      expect(auth.currentUser, isNull);
      expect(auth.isAuthenticated, isFalse);
      expect(await storage.getAccessToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);

      final sent = adapter.requests.single.data as Map;
      expect(sent.containsKey('code'), isFalse);
      expect(sent.containsKey('recovery_code'), isFalse);
    });

    test('two_factor_invalid → exception with invalid: true', () async {
      await expectLater(
        auth.login(email: 'a@b.test', password: 'secret', code: '000000'),
        throwsA(isA<LaravelTwoFactorRequiredException>()
            .having((e) => e.invalid, 'invalid', isTrue)
            .having((e) => e.errorCode, 'errorCode',
                LaravelErrorCode.twoFactorInvalid)),
      );
      expect(auth.currentState, isA<Unauthenticated>());
      expect(await storage.getAccessToken(), isNull);
    });

    test('second attempt with code authenticates and sends extra fields',
        () async {
      await expectLater(
        auth.login(email: 'a@b.test', password: 'secret'),
        throwsA(isA<LaravelTwoFactorRequiredException>()),
      );

      final user = await auth.login(
        email: 'a@b.test',
        password: 'secret',
        code: '123456',
        extra: {'remember': true, 'email': 'ignored@b.test'},
      );

      expect(user['team'], 'core');
      expect(auth.currentState, isA<Authenticated<Map<String, dynamic>>>());
      expect(await storage.getAccessToken(), 'access-1');
      expect(await storage.getRefreshToken(), 'refresh-1');

      final sent = adapter.requests.last.data as Map;
      expect(sent['code'], '123456');
      expect(sent['remember'], isTrue);
      expect(sent['email'], 'a@b.test', reason: 'explicit fields win');
      expect(sent.containsKey('recovery_code'), isFalse);
    });

    test('recovery code is sent as recovery_code', () async {
      await auth.login(
          email: 'a@b.test', password: 'secret', recoveryCode: 'recovery-abc');
      final sent = adapter.requests.single.data as Map;
      expect(sent['recovery_code'], 'recovery-abc');
      expect(sent.containsKey('code'), isFalse);
      expect(auth.currentState, isA<Authenticated<Map<String, dynamic>>>());
    });

    test('loginWithSocial forwards code / recovery_code', () async {
      await auth.loginWithSocial(
          provider: 'google', token: 'tok', code: '123456');
      final sent = adapter.requests.single.data as Map;
      expect(sent['provider'], 'google');
      expect(sent['code'], '123456');
    });

    test('ordinary 422 stays a plain validation error and AuthError', () async {
      adapter = _ScriptedAdapter((_) => _json(422, {
            'success': false,
            'message': 'The email field is required.',
            'data': null,
            'errors': {
              'email': ['The email field is required.']
            },
            'meta': {'error_code': 'validation_failed'},
          }));
      auth.client.rawDio.httpClientAdapter = adapter;

      Object? error;
      try {
        await auth.login(email: '', password: 'secret');
      } catch (e) {
        error = e;
      }
      expect(error, isA<LaravelValidationError>());
      expect(error, isNot(isA<LaravelTwoFactorRequiredException>()));
      expect(auth.currentState, isA<AuthError>());
    });
  });

  group('Plain JSON responses', () {
    test('ApiResponse.fromJson treats a non-envelope map as data', () {
      final response = ApiResponse<Map<String, dynamic>>.fromJson(
          {'id': 1, 'name': 'Raw', 'message': 'not an envelope'});
      expect(response.success, isTrue);
      expect(response.message, '');
      expect(response.data,
          {'id': 1, 'name': 'Raw', 'message': 'not an envelope'});
      expect(response.meta, isNull);
    });

    test('envelope detection', () {
      expect(ApiResponse.isEnvelope({'success': true}), isTrue);
      expect(ApiResponse.isEnvelope({'data': 1, 'message': ''}), isTrue);
      expect(ApiResponse.isEnvelope({'data': 1, 'meta': {}}), isTrue);
      expect(ApiResponse.isEnvelope({'data': 1}), isTrue);
      expect(ApiResponse.isEnvelope({'message': 'x', 'meta': {}}), isFalse);

      // A Laravel API resource keeps 2.0.0 behaviour: data is the inner value.
      final resource = ApiResponse<Map<String, dynamic>>.fromJson({
        'data': {'id': 3},
        'links': {'next': null},
      });
      expect(resource.data, {'id': 3});

      // Empty bodies keep their old meaning: no data.
      expect(ApiResponse<dynamic>.fromJson({}).data, isNull);
    });

    test('client parses raw map and list bodies as data', () async {
      final adapter = _ScriptedAdapter((o) {
        if (o.path.endsWith('list')) {
          return _json(200, [
            {'id': 1},
            {'id': 2}
          ]);
        }
        return _json(200, {'id': 9, 'title': 'Raw'});
      });
      final client = _client(adapter);

      final map = await client.get<Map<String, dynamic>>('api/raw');
      expect(map.success, isTrue);
      expect(map.data?['title'], 'Raw');

      final list = await client.get<List<dynamic>>('api/list');
      expect(list.success, isTrue);
      expect(list.data, hasLength(2));

      final parsed = await client.post<List<int>>('api/list',
          fromJson: (j) => (j as List).map((e) => e['id'] as int).toList());
      expect(parsed.data, [1, 2]);

      final put = await client.put<List<dynamic>>('api/list');
      expect(put.data, hasLength(2));
      final del = await client.delete<Map<String, dynamic>>('api/raw');
      expect(del.data?['id'], 9);
    });

    test('client keeps parsing enveloped bodies', () async {
      final client = _client(_ScriptedAdapter((_) => _json(200, {
            'success': true,
            'message': 'ok',
            'data': {'id': 1},
            'errors': null,
            'meta': {'trace_id': 't'},
          })));
      final response = await client.get<Map<String, dynamic>>('api/x');
      expect(response.message, 'ok');
      expect(response.data, {'id': 1});
      expect(response.metaValue('trace_id'), 't');
    });

    test('getJson returns the raw body and honours cacheFirst', () async {
      var hits = 0;
      final adapter = _ScriptedAdapter((o) {
        hits++;
        if (o.path.endsWith('array')) return _json(200, [1, 2]);
        return _json(200, {'hits': hits, 'success': 'yes'});
      });
      final client = _client(adapter);

      final first = await client.getJson('api/stats',
          queryParameters: {'day': 1}, cachePolicy: CachePolicy.cacheFirst);
      final second = await client.getJson('api/stats',
          queryParameters: {'day': 1}, cachePolicy: CachePolicy.cacheFirst);
      expect(first, {'hits': 1, 'success': 'yes'});
      expect(second, first);
      expect(hits, 1, reason: 'second call served from cache');

      final fresh = await client.getJson('api/stats',
          queryParameters: {'day': 1}, cachePolicy: CachePolicy.networkOnly);
      expect(fresh['hits'], 2);

      await expectLater(
          client.getJson('api/array'), throwsA(isA<LaravelException>()));
    });
  });
}
