import 'dart:math';

import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_bridge_server.dart';

const _alpha = LaravelConnection(
  id: 'alpha',
  name: 'Alpha',
  baseUrl: 'https://alpha.test',
  appKey: 'fba_test',
);
const _beta =
    LaravelConnection(id: 'beta', name: 'Beta', baseUrl: 'https://beta.test');

class _Harness {
  final Map<String, FakeBridgeServer> servers;
  final InMemoryConnectionStore store;
  final InMemoryTokenStorage tokens;
  final LaravelConnectionManager manager;
  final List<String?> revokedReasons;
  final List<LaravelUpgradeRequiredException> upgrades;
  final List<BridgeCommand> commandCallbacks;

  _Harness._(this.servers, this.store, this.tokens, this.manager,
      this.revokedReasons, this.upgrades, this.commandCallbacks);

  static Future<_Harness> create({
    List<LaravelConnection> profiles = const [_alpha, _beta],
    String appVersion = '1.0.0',
    bool load = true,
  }) async {
    final servers = {
      'alpha.test': FakeBridgeServer(name: 'Alpha'),
      'beta.test': FakeBridgeServer(name: 'Beta'),
    };
    final store = InMemoryConnectionStore(connections: profiles);
    final tokens = InMemoryTokenStorage();
    final revoked = <String?>[];
    final upgrades = <LaravelUpgradeRequiredException>[];
    final commands = <BridgeCommand>[];
    final manager = LaravelConnectionManager(
      options: LaravelOptions(
        baseUrl: 'https://unused.test',
        appVersion: appVersion,
        platform: 'android',
        deviceId: 'device-1',
        deviceName: 'Pixel 9',
        enableLogging: false,
      ),
      store: store,
      tokenStorage: tokens,
      httpClientAdapterFactory: (profile) =>
          servers[Uri.parse(profile.baseUrl).host]!,
      enableTimers: false,
      random: Random(1),
      onSessionRevoked: revoked.add,
      onUpgradeRequired: upgrades.add,
      onCommand: commands.add,
    );
    final harness = _Harness._(
        servers, store, tokens, manager, revoked, upgrades, commands);
    if (load) await manager.load();
    return harness;
  }

  FakeBridgeServer get alpha => servers['alpha.test']!;
  FakeBridgeServer get beta => servers['beta.test']!;

  Future<void> login([String email = 'a@example.com']) async {
    await manager.auth!.login(email: email, password: 'secret');
  }
}

void main() {
  group('LaravelConnectionManager', () {
    test(
        'load picks the first profile and prepares a client without network access',
        () async {
      final h = await _Harness.create();
      expect(h.manager.connections, [_alpha, _beta]);
      expect(h.manager.active, _alpha);
      expect(h.manager.client, isNotNull);
      expect(h.manager.state.status, ConnectionStatus.idle);
      expect(h.alpha.requests, isEmpty);
      expect(await h.store.loadActiveId(), 'alpha');
    });

    test('generates and persists a device id when none is configured',
        () async {
      final store = InMemoryConnectionStore(connections: const [_alpha]);
      final manager = LaravelConnectionManager(
        options: const LaravelOptions(
            baseUrl: 'https://alpha.test', enableLogging: false),
        store: store,
        enableTimers: false,
        httpClientAdapterFactory: (_) => FakeBridgeServer(),
      );
      await manager.load();
      final id = manager.deviceId;
      expect(id, isNotNull);
      expect(await store.loadDeviceId(), id);
      await manager.dispose();
    });

    test('handshake → connect → connected with protocol headers', () async {
      final h = await _Harness.create();
      final states = <ConnectionStatus>[];
      h.manager.stateStream.listen((s) => states.add(s.status));

      await h.manager.connect();

      expect(h.manager.state.status, ConnectionStatus.connected);
      expect(
          states,
          containsAllInOrder(
              [ConnectionStatus.connecting, ConnectionStatus.connected]));
      expect(h.manager.serverInfo!.server.name, 'Alpha');
      expect(h.manager.session!.id, 'sess-1');
      expect(h.manager.state.latency, isNotNull);
      expect(h.manager.client!.serverInfo, same(h.manager.serverInfo));

      final handshake = h.alpha.requestsTo('handshake').single;
      expect(handshake.header('X-Flutter-App-Key'), 'fba_test');
      expect(handshake.header('X-Flutter-Bridge-Version'), '2.0.0');

      final connect = h.alpha.requestsTo('connections/connect').single;
      expect(connect.body, containsPair('device_id', 'device-1'));
      expect(connect.body, containsPair('platform', 'android'));
      expect(connect.body, containsPair('app_version', '1.0.0'));
      expect(connect.body, containsPair('device_name', 'Pixel 9'));
      expect(connect.body, containsPair('bridge_version', '2.0.0'));

      await h.manager.heartbeat();
      final beat = h.alpha.requestsTo('heartbeat').single;
      expect(beat.path, 'api/flutter/connections/sess-1/heartbeat');
      expect(beat.header('X-Flutter-Connection-Id'), 'sess-1');

      // lastConnectedAt persisted.
      final saved =
          (await h.store.loadConnections()).firstWhere((c) => c.id == 'alpha');
      expect(saved.lastConnectedAt, isNotNull);
      expect(h.manager.active!.lastConnectedAt, isNotNull);
    });

    test('works against a server that omits the endpoint table', () async {
      final h = await _Harness.create();
      h.alpha.omitEndpoints = true;
      await h.manager.connect();
      expect(h.manager.state.status, ConnectionStatus.connected);
      await h.manager.heartbeat();
      expect(h.alpha.requestsTo('connections/sess-1/heartbeat'), hasLength(1));
    });

    test('heartbeat delivers commands once, de-duplicated by id', () async {
      final h = await _Harness.create();
      await h.manager.connect();
      final streamed = <BridgeCommand>[];
      h.manager.commands.listen(streamed.add);

      final id = h.alpha
          .queueCommand('sess-1', 'message', {'title': 'Hi', 'body': 'There'});
      final first = await h.manager.heartbeat();
      expect(first.single.id, id);
      expect(first.single.payload['title'], 'Hi');

      // The server re-delivers the same command (e.g. lost ack): ignored.
      h.alpha.sessions['sess-1']!.pending.add({
        'id': id,
        'type': 'message',
        'payload': {'title': 'Hi'}
      });
      final second = await h.manager.heartbeat();
      expect(second, isEmpty);

      await pumpEventQueue();
      expect(streamed.map((c) => c.id), [id]);
      expect(h.commandCallbacks.map((c) => c.id), [id]);
      expect(h.manager.state.lastHeartbeatAt, isNotNull);
    });

    test('revoked via heartbeat 403 clears tokens and reports revoked',
        () async {
      final h = await _Harness.create();
      await h.manager.connect();
      await h.login();
      expect(await h.manager.auth!.tokenStorage.getAccessToken(), isNotNull);

      h.alpha.sessions['sess-1']!.status = 'revoked';
      await h.manager.heartbeat();

      expect(h.manager.state.status, ConnectionStatus.revoked);
      expect(h.manager.state.error, isA<LaravelConnectionRevokedException>());
      expect(h.manager.session, isNull);
      expect(await h.manager.auth!.tokenStorage.getAccessToken(), isNull);
      expect(await h.manager.auth!.tokenStorage.getRefreshToken(), isNull);
      expect(h.manager.auth!.isAuthenticated, isFalse);
      expect(h.revokedReasons, hasLength(1));
    });

    test('credentials are already cleared when the revoked state is emitted',
        () async {
      final h = await _Harness.create();
      await h.manager.connect();
      await h.login();

      bool? authenticatedAtEmit;
      final sub = h.manager.stateStream.listen((state) {
        if (state.status == ConnectionStatus.revoked) {
          authenticatedAtEmit ??= h.manager.auth!.isAuthenticated;
        }
      });

      h.alpha.sessions['sess-1']!.status = 'revoked';
      await h.manager.heartbeat();
      await pumpEventQueue();
      await sub.cancel();

      expect(authenticatedAtEmit, isFalse);
    });

    test('revoked command (another device signed us out) is handled once',
        () async {
      final h = await _Harness.create();
      await h.manager.connect();
      await h.login();

      h.alpha.queueCommand(
          'sess-1', 'revoked', {'reason': 'Signed out from the web'});
      await h.manager.heartbeat();
      await pumpEventQueue();

      expect(h.manager.state.status, ConnectionStatus.revoked);
      expect(h.revokedReasons, ['Signed out from the web']);
      expect(h.manager.auth!.isAuthenticated, isFalse);
    });

    test('a revoked session on a regular API request is detected too',
        () async {
      final h = await _Harness.create();
      await h.manager.connect();
      await h.login();
      h.alpha.sessions['sess-1']!.status = 'revoked';

      await expectLater(h.manager.client!.get<dynamic>('api/flutter/auth/me'),
          throwsA(isA<LaravelConnectionRevokedException>()));
      await pumpEventQueue();
      expect(h.manager.state.status, ConnectionStatus.revoked);
      expect(h.revokedReasons, hasLength(1));
    });

    test('signing in again after revocation opens a fresh session', () async {
      final h = await _Harness.create();
      await h.manager.connect();
      await h.login();
      h.alpha.revoke('sess-1');
      await h.manager.heartbeat();
      expect(h.manager.state.status, ConnectionStatus.revoked);

      await h.login();
      await pumpEventQueue();
      await h.manager.connect();
      expect(h.manager.state.status, ConnectionStatus.connected);
      expect(h.manager.session!.id, isNot('sess-1'));
    });

    test('426 on connect → upgradeRequired with update details', () async {
      final h = await _Harness.create();
      h.alpha.minVersion = '2.0.0';

      await h.manager.connect();

      expect(h.manager.state.status, ConnectionStatus.upgradeRequired);
      final error = h.manager.state.error as LaravelUpgradeRequiredException;
      expect(error.minVersion, '2.0.0');
      expect(error.currentVersion, '1.0.0');
      expect(error.updateUrl, 'https://store.example.com/app');
      expect(h.upgrades, hasLength(1));
      // The handshake (exempt) still succeeded, so the app info is known.
      expect(h.manager.serverInfo!.app!.minVersion, '2.0.0');
    });

    test('force_update command → upgradeRequired', () async {
      final h = await _Harness.create();
      await h.manager.connect();
      h.alpha.queueCommand('sess-1', 'force_update',
          {'min_version': '3.0.0', 'update_url': 'https://u'});
      await h.manager.heartbeat();
      expect(h.manager.state.status, ConnectionStatus.upgradeRequired);
      expect(h.upgrades.single.minVersion, '3.0.0');
      expect(h.upgrades.single.updateUrl, 'https://u');
      expect(h.upgrades.single.currentVersion, '1.0.0');
    });

    test('logout and refresh_config commands', () async {
      final h = await _Harness.create();
      await h.manager.connect();
      await h.login();

      h.alpha.queueCommand('sess-1', 'refresh_config');
      final handshakesBefore = h.alpha.requestsTo('handshake').length;
      await h.manager.heartbeat();
      expect(h.alpha.requestsTo('handshake').length, handshakesBefore + 1);

      h.alpha.queueCommand('sess-1', 'logout', {'reason': 'admin'});
      await h.manager.heartbeat();
      expect(h.manager.auth!.isAuthenticated, isFalse);
      expect(await h.manager.auth!.tokenStorage.getAccessToken(), isNull);
      expect(h.manager.state.status, ConnectionStatus.connected);
    });

    test('404 connection_not_found on heartbeat silently opens a new session',
        () async {
      final h = await _Harness.create();
      await h.manager.connect();
      final statuses = <ConnectionStatus>[];
      h.manager.stateStream.listen((s) => statuses.add(s.status));

      h.alpha.sessions.clear(); // server lost the session (pruned)
      await h.manager.heartbeat();

      expect(h.manager.state.status, ConnectionStatus.connected);
      expect(h.manager.session!.id, 'sess-2');
      expect(statuses, isNot(contains(ConnectionStatus.offline)));
      expect(statuses, isNot(contains(ConnectionStatus.connecting)));
    });

    test(
        'network failure → offline with backoff, recovers and flushes the offline queue',
        () async {
      final h = await _Harness.create();
      h.alpha.offline = true;

      await h.manager.connect();
      expect(h.manager.state.status, ConnectionStatus.offline);
      expect(h.manager.state.reconnectAttempt, 1);
      expect(h.manager.state.nextRetryAt, isNotNull);
      expect(h.manager.state.error, isA<LaravelNetworkException>());

      await h.manager.connect();
      expect(h.manager.state.reconnectAttempt, 2);

      // Queue a mutation while offline.
      await expectLater(
        h.manager.client!.post<dynamic>('api/flutter/config',
            data: {'x': 1}, queueIfOffline: true),
        throwsA(isA<LaravelNetworkException>()),
      );
      expect(h.manager.client!.offlineQueue.length, 1);

      h.alpha.offline = false;
      h.alpha.routes['POST api/flutter/config'] =
          (req, server) => server.json(200, {'success': true, 'data': null});
      final statuses = <ConnectionStatus>[];
      h.manager.stateStream.listen((s) => statuses.add(s.status));
      await h.manager.connect();
      await pumpEventQueue();

      expect(statuses.first, ConnectionStatus.reconnecting);
      expect(h.manager.state.status, ConnectionStatus.connected);
      expect(h.manager.state.reconnectAttempt, 0);
      expect(h.manager.client!.offlineQueue.length, 0);
      expect(
          h.alpha.requestsTo('api/flutter/config', method: 'POST').length, 2);
    });

    test('heartbeat network failure while connected goes offline', () async {
      final h = await _Harness.create();
      await h.manager.connect();
      h.alpha.offline = true;
      await h.manager.heartbeat();
      expect(h.manager.state.status, ConnectionStatus.offline);
      h.alpha.offline = false;
      await h.manager.heartbeat();
      expect(h.manager.state.status, ConnectionStatus.connected);
    });

    test('invalid app key → failed', () async {
      final h = await _Harness.create(
          profiles: [_alpha.copyWith(appKey: 'fba_wrong')]);
      await h.manager.connect();
      expect(h.manager.state.status, ConnectionStatus.failed);
      expect(h.manager.state.error, isA<LaravelAppKeyException>());
      expect((h.manager.state.error as LaravelAppKeyException).errorCode,
          'invalid_app_key');
    });

    test('a non-bridge server fails with a helpful error', () async {
      final h = await _Harness.create();
      h.alpha.routes['GET api/flutter/handshake'] =
          (req, server) => server.json(200, {'hello': 'world'});
      await h.manager.connect();
      expect(h.manager.state.status, ConnectionStatus.failed);
      expect((h.manager.state.error as LaravelException).message,
          contains('handshake'));
    });

    test('test() probes without touching state or tokens', () async {
      final h = await _Harness.create();
      final before = h.manager.state;
      final ok = await h.manager.test(_beta);
      expect(ok.ok, isTrue);
      expect(ok.latency, isNotNull);
      expect(ok.serverInfo!.server.name, 'Beta');
      expect(h.beta.requestsTo('ping'), hasLength(1));
      expect(h.beta.requestsTo('connections/connect'), isEmpty);

      h.beta.offline = true;
      final failed = await h.manager.test(_beta);
      expect(failed.ok, isFalse);
      expect(failed.error, isA<LaravelNetworkException>());
      expect(failed.errorMessage, isNotEmpty);
      expect(identical(h.manager.state, before), isTrue);
    });

    test('switching profiles keeps tokens separated', () async {
      final h = await _Harness.create();
      final runtimeChanges = <void>[];
      h.manager.runtimeChanges.listen(runtimeChanges.add);

      await h.manager.connect();
      await h.login('a@example.com');
      final alphaToken = await h.manager.auth!.tokenStorage.getAccessToken();
      expect(alphaToken, contains('Alpha'));

      await h.manager.switchTo('beta');
      expect(h.manager.active!.id, 'beta');
      expect(h.manager.state.status, ConnectionStatus.connected);
      expect(h.manager.serverInfo!.server.name, 'Beta');
      expect(h.manager.auth!.isAuthenticated, isFalse);
      expect(await h.manager.auth!.tokenStorage.getAccessToken(), isNull);
      expect(await h.store.loadActiveId(), 'beta');
      // The alpha session was closed on the server.
      expect(h.alpha.sessions['sess-1']!.status, 'disconnected');

      await h.login('b@example.com');
      final betaToken = await h.manager.auth!.tokenStorage.getAccessToken();
      expect(betaToken, contains('Beta'));

      await h.manager.switchTo('alpha');
      await pumpEventQueue();
      // Alpha's session is restored from its own (scoped) tokens.
      expect(h.manager.auth!.isAuthenticated, isTrue);
      expect((h.manager.auth!.currentUser as Map)['email'], 'a@example.com');
      expect(await h.manager.auth!.tokenStorage.getAccessToken(), alphaToken);
      expect(
          await h.manager.tokenStorageOf('beta').getAccessToken(), betaToken);
      expect(runtimeChanges.length, greaterThanOrEqualTo(2));

      // Login on alpha bound the tokens to the alpha session id header.
      final login = h.alpha.requestsTo('auth/login').single;
      expect(login.header('X-Flutter-Connection-Id'), 'sess-1');
    });

    test('sessions(), revokeSession() and revokeOtherSessions()', () async {
      final h = await _Harness.create();
      await h.manager.connect();
      await h.login();
      final other = h.alpha.addForeignSession(userId: 1);
      h.alpha.addForeignSession(
          userId: 1, deviceId: 'tablet', platform: 'android');
      h.alpha.addForeignSession(userId: 2, deviceId: 'bob');

      final sessions = await h.manager.sessions();
      expect(sessions, hasLength(3));
      expect(sessions.where((s) => s.isCurrent).single.id, 'sess-1');

      final revoked = await h.manager.revokeSession(other.id);
      expect(revoked!.status, ConnectionSessionStatus.revoked);
      expect(h.alpha.sessions[other.id]!.status, 'revoked');
      expect(h.manager.state.status, ConnectionStatus.connected);

      final count = await h.manager.revokeOtherSessions();
      expect(count, 1);
      expect(h.alpha.sessions['sess-1']!.status, 'active');
    });

    test('revoking the current session signs this device out', () async {
      final h = await _Harness.create();
      await h.manager.connect();
      await h.login();
      await h.manager.revokeSession('sess-1');
      await pumpEventQueue();
      expect(h.manager.state.status, ConnectionStatus.revoked);
      expect(h.manager.auth!.isAuthenticated, isFalse);
    });

    test('add / update / remove profiles', () async {
      final h = await _Harness.create(profiles: const [_alpha]);
      final emitted = <List<LaravelConnection>>[];
      h.manager.connectionsStream.listen(emitted.add);

      await h.manager.add(_beta);
      expect(h.manager.active!.id, 'alpha');
      expect(() => h.manager.add(_beta), throwsStateError);

      await h.manager.connect();
      await h.login();
      expect(
          await h.manager.tokenStorageOf('alpha').getAccessToken(), isNotNull);

      await h.manager.update(_alpha.copyWith(name: 'Alpha renamed'));
      expect(h.manager.active!.name, 'Alpha renamed');
      expect(h.manager.state.status, ConnectionStatus.connected);

      final alphaStorage = h.manager.tokenStorageOf('alpha');
      await h.manager.remove('alpha');
      expect(await alphaStorage.getAccessToken(), isNull);
      expect(h.manager.connections.map((c) => c.id), ['beta']);
      expect(h.manager.active!.id, 'beta');
      expect(h.manager.state.status, ConnectionStatus.connected);
      expect(h.alpha.sessions['sess-1']!.status, 'disconnected');
      await pumpEventQueue();
      expect(emitted, isNotEmpty);

      await h.manager.remove('beta');
      expect(h.manager.active, isNull);
      expect(h.manager.client, isNull);
      expect(await h.store.loadActiveId(), isNull);
    });

    test('updating the active transport rebuilds the client and reconnects',
        () async {
      final h = await _Harness.create();
      await h.manager.connect();
      final oldClient = h.manager.client;
      await h.manager.update(_alpha.copyWith(
          appKey: 'fba_test',
          prefix: 'api/flutter',
          headers: {'X-Tenant': 't'}));
      expect(h.manager.client, isNot(same(oldClient)));
      expect(h.manager.state.status, ConnectionStatus.connected);
      expect(h.alpha.requests.last.header('X-Tenant'), 't');
    });

    test('ping measures latency', () async {
      final h = await _Harness.create();
      await h.manager.connect();
      final latency = await h.manager.ping();
      expect(latency, h.manager.state.latency);
    });

    test('disconnect closes the session and stops reporting', () async {
      final h = await _Harness.create();
      await h.manager.connect();
      await h.manager.disconnect();
      expect(h.manager.state.status, ConnectionStatus.idle);
      expect(h.manager.session, isNull);
      expect(h.alpha.sessions['sess-1']!.status, 'disconnected');
      expect(await h.manager.heartbeat(), isEmpty);
    });

    test('broadcast BridgeCommand events share the de-duplication pipeline',
        () async {
      final h = await _Harness.create();
      h.alpha.broadcasting = true;
      final sockets = <_FakeEcho>[];
      final manager = LaravelConnectionManager(
        options: const LaravelOptions(
            baseUrl: 'https://alpha.test',
            deviceId: 'd',
            platform: 'ios',
            enableLogging: false),
        store: InMemoryConnectionStore(connections: const [_alpha]),
        httpClientAdapterFactory: (_) => h.alpha,
        echoFactory: (options, client) {
          final echo = _FakeEcho(options, client);
          sockets.add(echo);
          return echo;
        },
        enableTimers: false,
      );
      await manager.load();
      await manager.connect();
      expect(manager.echo, isNotNull);
      expect(sockets.single.connected, isTrue);
      expect(sockets.single.options.wsHost, 'ws.Alpha.test');

      // Not authenticated yet: no command channel.
      expect(sockets.single.channelNames, isEmpty);
      await manager.auth!.login(email: 'a@example.com', password: 'secret');
      await pumpEventQueue();
      final channelName = 'private-flutter.connections.${manager.session!.id}';
      expect(sockets.single.channelNames, contains(channelName));

      final received = <BridgeCommand>[];
      manager.commands.listen(received.add);
      final command = {
        'id': '99',
        'type': 'message',
        'payload': {'title': 'Live'}
      };
      sockets.single.private(channelName).dispatch('BridgeCommand', command);
      await pumpEventQueue();
      expect(received.single.source, BridgeCommandSource.broadcast);

      // Same command later in a heartbeat: ignored.
      h.alpha.sessions[manager.session!.id]!.pending.add(command);
      expect(await manager.heartbeat(), isEmpty);
      await pumpEventQueue();
      expect(received, hasLength(1));

      // ConnectionRevoked broadcast.
      sockets.single
          .private(channelName)
          .dispatch('ConnectionRevoked', {'reason': 'admin'});
      await pumpEventQueue();
      expect(manager.state.status, ConnectionStatus.revoked);
      await manager.dispose();
    });

    test('backoffDelay grows exponentially with jitter and is capped', () {
      final random = Random(42);
      for (var attempt = 0; attempt < 12; attempt++) {
        final delay =
            LaravelConnectionManager.backoffDelay(attempt, random: random);
        final expected = min(1000 * pow(2, attempt), 60000).toDouble();
        expect(
            delay.inMilliseconds,
            inInclusiveRange(
                (expected * 0.8).floor(), min(expected * 1.2, 60000).ceil()));
      }
      expect(LaravelConnectionManager.backoffDelay(50).inMilliseconds,
          lessThanOrEqualTo(60000));
    });
  });
}

/// Echo double that never opens a socket.
class _FakeEcho extends LaravelEcho {
  bool connected = false;

  _FakeEcho(EchoOptions options, LaravelClient client)
      : super(options: options, client: client);

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<void> disconnect() async => connected = false;
}
