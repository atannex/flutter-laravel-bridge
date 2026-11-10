import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeSink implements WebSocketSink {
  final _FakeSocket socket;
  _FakeSink(this.socket);

  @override
  void add(dynamic data) =>
      socket.sent.add(jsonDecode(data as String) as Map<String, dynamic>);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!socket.incoming.isClosed) await socket.incoming.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSocket implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  late final _FakeSink _sink = _FakeSink(this);

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  void receive(Map<String, dynamic> frame) => incoming.add(jsonEncode(frame));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AuthAdapter implements HttpClientAdapter {
  final Object body;
  final requests = <RequestOptions>[];
  _AuthAdapter(this.body);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }
}

({LaravelEcho echo, List<_FakeSocket> sockets, _AuthAdapter adapter}) _echo(
    Object authBody) {
  final client = LaravelClient(
      options: const LaravelOptions(
          baseUrl: 'http://api.test', enableLogging: false));
  final adapter = _AuthAdapter(authBody);
  client.rawDio.httpClientAdapter = adapter;
  final sockets = <_FakeSocket>[];
  final echo = LaravelEcho(
    options: const EchoOptions(appKey: 'k', wsHost: 'ws.test'),
    client: client,
    reconnectBaseDelay: const Duration(milliseconds: 5),
    reconnectMaxDelay: const Duration(milliseconds: 20),
    channelFactory: (uri) {
      final socket = _FakeSocket();
      sockets.add(socket);
      return socket;
    },
  );
  return (echo: echo, sockets: sockets, adapter: adapter);
}

Future<void> _establish(_FakeSocket socket) async {
  socket.receive({
    'event': 'pusher:connection_established',
    'data': jsonEncode({'socket_id': '123.456', 'activity_timeout': 30}),
  });
  await pumpEventQueue();
}

void main() {
  test('extractAuthPayload accepts enveloped and raw payloads', () {
    expect(
        LaravelEcho.extractAuthPayload({
          'success': true,
          'data': {'auth': 'a:b', 'channel_data': '{}'}
        })!['auth'],
        'a:b');
    expect(LaravelEcho.extractAuthPayload({'auth': 'c:d'})!['auth'], 'c:d');
    expect(LaravelEcho.extractAuthPayload({'data': null}), isNull);
    expect(LaravelEcho.extractAuthPayload('nope'), isNull);
  });

  test(
      'private channels authenticate with X-Socket-ID and the enveloped signature',
      () async {
    final h = _echo({
      'success': true,
      'data': {
        'auth': 'key:sig',
        'channel_data': {'user_id': 1}
      }
    });
    await h.echo.connect();
    await _establish(h.sockets.single);
    expect(h.echo.connectionState, EchoConnectionState.connected);

    h.echo.join('room.1');
    await pumpEventQueue();

    final request = h.adapter.requests.single;
    expect(request.headers['X-Socket-ID'], '123.456');
    expect(request.data,
        {'socket_id': '123.456', 'channel_name': 'presence-room.1'});

    final subscribe = h.sockets.single.sent
        .firstWhere((f) => f['event'] == 'pusher:subscribe');
    expect(subscribe['data']['auth'], 'key:sig');
    expect(subscribe['data']['channel_data'], '{"user_id":1}');
    h.echo.dispose();
  });

  test('raw (non-enveloped) auth responses are accepted too', () async {
    final h = _echo({'auth': 'raw:sig'});
    await h.echo.connect();
    await _establish(h.sockets.single);
    h.echo.private('orders');
    await pumpEventQueue();
    final subscribe = h.sockets.single.sent
        .firstWhere((f) => f['event'] == 'pusher:subscribe');
    expect(subscribe['data']['channel'], 'private-orders');
    expect(subscribe['data']['auth'], 'raw:sig');
    h.echo.dispose();
  });

  test(
      'manual disconnect never reconnects; unexpected close reconnects with backoff',
      () async {
    final h = _echo({'auth': 'x'});
    await h.echo.connect();
    await _establish(h.sockets.single);

    await h.echo.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(h.sockets, hasLength(1));
    expect(h.echo.connectionState, EchoConnectionState.disconnected);

    await h.echo.connect();
    expect(h.sockets, hasLength(2));
    await _establish(h.sockets.last);
    await h.sockets.last.incoming.close(); // server dropped us
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(h.sockets.length, greaterThanOrEqualTo(3));
    h.echo.dispose();
  });

  test('reconnect delay grows and is capped', () {
    final h = _echo({'auth': 'x'});
    final delays = List.generate(6, h.echo.reconnectDelay);
    expect(delays.first.inMilliseconds, inInclusiveRange(4, 6));
    expect(delays.last.inMilliseconds, lessThanOrEqualTo(20));
    h.echo.dispose();
  });

  test('fatal pusher:error stops reconnecting and is reported', () async {
    final h = _echo({'auth': 'x'});
    final errors = <EchoError>[];
    h.echo.errors.listen(errors.add);
    await h.echo.connect();
    h.sockets.single.receive({
      'event': 'pusher:error',
      'data': {'code': 4001, 'message': 'App key not found'}
    });
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(errors.single.code, 4001);
    expect(errors.single.isFatal, isTrue);
    expect(h.sockets, hasLength(1));
    expect(h.echo.connectionState, EchoConnectionState.disconnected);
    h.echo.dispose();
  });

  group('PresenceChannel', () {
    test('tracks members by presence id and removes them on user_id', () {
      final channel = PresenceChannel('presence-room');
      final left = <dynamic>[];
      channel.leaving(left.add);

      channel.handleSubscriptionSucceeded({
        'presence': {
          'ids': ['1', '2'],
          'hash': {
            '1': {'name': 'Alice'}, // no id inside user info
            '2': {'id': 2, 'name': 'Bob'},
          },
        },
      });
      expect(channel.members, hasLength(2));

      channel.handleMemberAdded({
        'user_id': 3,
        'user_info': {'name': 'Carol'}
      });
      expect(channel.memberIds, containsAll(['1', '2', '3']));

      channel.handleMemberRemoved({'user_id': '1'});
      expect(left.single, {'name': 'Alice'});
      channel.handleMemberRemoved({'user_id': 3});
      expect(channel.memberIds, ['2']);
    });
  });

  test('SSE client does not reconnect after manual disconnect', () async {
    final client = LaravelClient(
        options: const LaravelOptions(
            baseUrl: 'http://api.test', enableLogging: false));
    var calls = 0;
    client.rawDio.httpClientAdapter = _CountingAdapter(() => calls++);
    final sse = LaravelSseClient(
        streamUrl: 'stream',
        client: client,
        reconnectDelay: const Duration(milliseconds: 10));
    await sse.connect();
    sse.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(calls, 1);
    sse.dispose();
  });
}

class _CountingAdapter implements HttpClientAdapter {
  final void Function() onCall;
  _CountingAdapter(this.onCall);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    onCall();
    throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: Exception('down'));
  }
}
