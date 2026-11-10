import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_bridge_server.dart';

class User {
  final int id;
  final String email;
  User(this.id, this.email);
  factory User.fromJson(Map<String, dynamic> json) =>
      User(json['id'] as int, json['email'] as String);
}

void main() {
  late Map<String, FakeBridgeServer> servers;

  setUp(() {
    servers = {
      'alpha.test': FakeBridgeServer(name: 'Alpha'),
      'beta.test': FakeBridgeServer(name: 'Beta'),
    };
  });

  tearDown(Laravel.reset);

  test('legacy initialize seeds a default profile and connects', () async {
    final tokens = InMemoryTokenStorage();
    await tokens.saveAccessToken('stale');

    expect(Laravel.isInitialized, isFalse);
    await Laravel.initialize<User>(
      options: const LaravelOptions(
          baseUrl: 'https://alpha.test',
          appKey: 'fba_test',
          deviceId: 'd1',
          platform: 'ios',
          enableLogging: false),
      userParser: User.fromJson,
      tokenStorage: tokens,
      httpClientAdapterFactory: (p) => servers[Uri.parse(p.baseUrl).host]!,
      enableTimers: false,
    );

    expect(Laravel.isInitialized, isTrue);
    expect(Laravel.connections.connections.single.id, 'default');
    expect(Laravel.connections.active!.appKey, 'fba_test');
    expect(Laravel.connections.state.status, ConnectionStatus.connected);
    expect(Laravel.server!.server.name, 'Alpha');
    expect(Laravel.client.options.appKey, 'fba_test');
    expect(Laravel.devices.client, same(Laravel.client));
    expect(Laravel.hasEcho, isFalse);
    expect(() => Laravel.echo, throwsStateError);

    // The stale token was rejected by /auth/me and cleared from the legacy (unscoped) storage.
    expect(Laravel.auth<User>().isAuthenticated, isFalse);
    expect(await tokens.getAccessToken(), isNull);

    final user = await Laravel.auth<User>()
        .login(email: 'a@example.com', password: 'secret');
    expect(user.email, 'a@example.com');
    // Default profile keeps using the un-namespaced keys for backwards compatibility.
    expect(await tokens.getAccessToken(), isNotNull);
  });

  test(
      'switchConnection rebuilds subsystems, fires changes and isolates sessions',
      () async {
    final tokens = InMemoryTokenStorage();
    await Laravel.initialize<User>(
      options: const LaravelOptions(
          baseUrl: 'https://alpha.test',
          deviceId: 'd1',
          platform: 'ios',
          enableLogging: false),
      userParser: User.fromJson,
      tokenStorage: tokens,
      httpClientAdapterFactory: (p) => servers[Uri.parse(p.baseUrl).host]!,
      enableTimers: false,
    );
    await Laravel.auth<User>()
        .login(email: 'a@example.com', password: 'secret');
    await Laravel.connections.add(const LaravelConnection(
        id: 'beta', name: 'Beta', baseUrl: 'https://beta.test'));

    var changes = 0;
    final sub = Laravel.changes.listen((_) => changes++);
    final oldClient = Laravel.client;

    await Laravel.switchConnection('beta');
    await pumpEventQueue();
    expect(changes, greaterThanOrEqualTo(1));
    expect(Laravel.client, isNot(same(oldClient)));
    expect(Laravel.server!.server.name, 'Beta');
    expect(Laravel.auth<User>().isAuthenticated, isFalse);

    await Laravel.switchConnection('default');
    await pumpEventQueue();
    expect(Laravel.auth<User>().currentUser!.email, 'a@example.com');
    await sub.cancel();
  });

  test('autoConnect false restores auth without connecting; store is honoured',
      () async {
    final map = <String, String>{};
    final store = DelegateConnectionStore(
      onRead: (k) async => map[k],
      onWrite: (k, v) async => map[k] = v,
      onDelete: (k) async => map.remove(k),
    );
    await store.saveConnections(const [
      LaravelConnection(id: 'beta', name: 'Beta', baseUrl: 'https://beta.test')
    ]);

    final commands = <BridgeCommand>[];
    await Laravel.initialize<User>(
      options: const LaravelOptions(
          baseUrl: 'https://alpha.test',
          deviceId: 'd1',
          platform: 'ios',
          enableLogging: false),
      userParser: User.fromJson,
      connectionStore: store,
      autoConnect: false,
      onCommand: commands.add,
      httpClientAdapterFactory: (p) => servers[Uri.parse(p.baseUrl).host]!,
      enableTimers: false,
    );
    expect(Laravel.connections.active!.id, 'beta');
    expect(Laravel.connections.state.status, ConnectionStatus.idle);
    expect(servers['beta.test']!.requestsTo('connections/connect'), isEmpty);

    await Laravel.reset();
    expect(Laravel.isInitialized, isFalse);
    expect(() => Laravel.client, throwsStateError);
  });
}
