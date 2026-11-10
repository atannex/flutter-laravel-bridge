import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adapter answering every request with a programmable handler.
class _ScriptedAdapter implements HttpClientAdapter {
  FutureOr<ResponseBody> Function(RequestOptions options) handler;

  _ScriptedAdapter(this.handler);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
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

const _user = {'id': 7, 'name': 'Ngwa Asong', 'email': 'ngwa@example.com'};

Map<String, dynamic> _loginBody() => {
      'success': true,
      'message': 'Authenticated successfully',
      'data': {
        'user': _user,
        'authorization': {
          'token_type': 'Bearer',
          'access_token': '1|access',
          'refresh_token': 'refresh',
          'expires_in': 3600,
        },
      },
      'meta': {},
    };

Never _offline(RequestOptions options) => throw DioException.connectionError(
      requestOptions: options,
      reason: 'offline',
    );

void main() {
  late InMemoryTokenStorage tokens;
  late InMemoryKeyValueStore store;
  late _ScriptedAdapter adapter;

  AuthManager<Map<String, dynamic>> auth({bool cache = true}) {
    final client = LaravelClient(
      options: const LaravelOptions(
          baseUrl: 'http://api.test', enableLogging: false),
      tokenStorage: tokens,
    );
    client.rawDio.httpClientAdapter = adapter;
    final manager = AuthManager<Map<String, dynamic>>(
      client: client,
      userParser: (json) => json,
      proactiveRefresh: false,
    );
    if (cache) manager.attachUserCache(store, key: 'user:alpha');
    return manager;
  }

  setUp(() {
    tokens = InMemoryTokenStorage();
    store = InMemoryKeyValueStore();
    adapter = _ScriptedAdapter((o) => _json(200, _loginBody()));
  });

  test('a signed-in user stays signed in when the app starts offline',
      () async {
    await auth().login(email: 'ngwa@example.com', password: 'secret');
    expect(store.values['user:alpha'], isNotNull);

    // Next launch: the server is unreachable.
    adapter.handler = _offline;
    final restarted = auth();
    final user = await restarted.initialize();

    expect(user?['email'], 'ngwa@example.com');
    expect(restarted.isAuthenticated, isTrue);
    expect(restarted.currentState, isA<Authenticated<Map<String, dynamic>>>());
    expect(await tokens.getAccessToken(), '1|access');
  });

  test('without a cached user an offline start stays signed out', () async {
    await auth(cache: false).login(email: 'ngwa@example.com', password: 's');

    adapter.handler = _offline;
    final restarted = auth();
    expect(await restarted.initialize(), isNull);
    expect(restarted.isAuthenticated, isFalse);
    // Tokens are kept for when the server is reachable again.
    expect(await tokens.getAccessToken(), '1|access');
  });

  test('a rejected session clears the cached user too', () async {
    await auth().login(email: 'ngwa@example.com', password: 'secret');

    adapter.handler = (o) => _json(401, {
          'success': false,
          'message': 'Unauthenticated.',
          'data': null,
          'errors': null,
          'meta': {'error_code': 'unauthenticated'},
        });
    final restarted = auth();
    expect(await restarted.initialize(), isNull);
    expect(store.values.containsKey('user:alpha'), isFalse);
    expect(await tokens.getAccessToken(), isNull);
  });

  test('signing out forgets the cached user', () async {
    final manager = auth();
    await manager.login(email: 'ngwa@example.com', password: 'secret');
    await manager.clearSession();
    expect(store.values.containsKey('user:alpha'), isFalse);
  });

  test('the profile is refreshed in the cache when fetched', () async {
    final manager = auth();
    await manager.login(email: 'ngwa@example.com', password: 'secret');

    adapter.handler = (o) => _json(200, {
          'success': true,
          'message': '',
          'data': {
            'user': {..._user, 'name': 'Ngwa A.'},
          },
          'meta': {},
        });
    await manager.fetchUserProfile();

    final cached = jsonDecode(store.values['user:alpha']!) as Map;
    expect(cached['name'], 'Ngwa A.');
  });

  test('the connection manager keeps one cached user per profile', () {
    expect(LaravelConnectionManager.userStorageKeyFor('alpha'),
        'flutter_laravel_user:alpha');
  });
}
