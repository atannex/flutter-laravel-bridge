import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class _CustomStorage implements TokenStorage {
  @override
  Future<void> clear() async {}
  @override
  Future<String?> getAccessToken() async => null;
  @override
  Future<String?> getRefreshToken() async => null;
  @override
  Future<void> saveAccessToken(String token) async {}
  @override
  Future<void> saveRefreshToken(String token) async {}
}

void main() {
  const a = LaravelConnection(
      id: 'a', name: 'A', baseUrl: 'http://a.test', appKey: 'fba_a');
  const b = LaravelConnection(
      id: 'b', name: 'B', baseUrl: 'http://b.test', prefix: 'mobile');

  group('InMemoryConnectionStore', () {
    test('saves and loads profiles, active id and device id', () async {
      final store = InMemoryConnectionStore(connections: const [a]);
      expect(await store.loadConnections(), [a]);
      await store.saveConnections(const [a, b]);
      await store.saveActiveId('b');
      await store.saveDeviceId('dev-1');
      expect(await store.loadConnections(), [a, b]);
      expect(await store.loadActiveId(), 'b');
      expect(await store.loadDeviceId(), 'dev-1');
      await store.saveActiveId(null);
      expect(await store.loadActiveId(), isNull);
    });
  });

  group('DelegateConnectionStore', () {
    test('stores JSON under stable keys', () async {
      final map = <String, String>{};
      final store = DelegateConnectionStore(
        onRead: (k) async => map[k],
        onWrite: (k, v) async => map[k] = v,
        onDelete: (k) async => map.remove(k),
      );
      expect(await store.loadConnections(), isEmpty);

      await store.saveConnections(const [a, b]);
      await store.saveActiveId('a');
      await store.saveDeviceId('dev');
      expect(
          map.keys,
          containsAll([
            'flutter_laravel_connections',
            'flutter_laravel_active_connection',
            'flutter_laravel_device_id'
          ]));

      final reloaded = DelegateConnectionStore(
        onRead: (k) async => map[k],
        onWrite: (k, v) async => map[k] = v,
        onDelete: (k) async => map.remove(k),
      );
      expect(await reloaded.loadConnections(), [a, b]);
      expect(await reloaded.loadActiveId(), 'a');
      expect(await reloaded.loadDeviceId(), 'dev');

      await store.saveActiveId(null);
      expect(map.containsKey('flutter_laravel_active_connection'), isFalse);
    });

    test('tolerates corrupted data', () async {
      final store = DelegateConnectionStore(
        onRead: (k) async => '{not json',
        onWrite: (k, v) async {},
        onDelete: (k) async {},
      );
      expect(await store.loadConnections(), isEmpty);
    });
  });

  group('Scoped token storage', () {
    test('DelegateTokenStorage namespaces its keys', () async {
      final map = <String, String>{};
      final root = DelegateTokenStorage(
        onWrite: (k, v) async => map[k] = v,
        onRead: (k) async => map[k],
        onDelete: (k) async => map.remove(k),
      );
      final scoped = root.scoped('staging');
      expect(scoped, isA<DelegateTokenStorage>());

      await root.saveAccessToken('root-access');
      await scoped.saveAccessToken('staging-access');
      await scoped.saveRefreshToken('staging-refresh');

      expect(map['flutter_laravel_access_token'], 'root-access');
      expect(map['flutter_laravel_access_token:staging'], 'staging-access');
      expect(map['flutter_laravel_refresh_token:staging'], 'staging-refresh');

      await scoped.clear();
      expect(map.containsKey('flutter_laravel_access_token:staging'), isFalse);
      expect(map['flutter_laravel_access_token'], 'root-access');
    });

    test('namespace constructor parameter and nested scopes', () async {
      final map = <String, String>{};
      final storage = DelegateTokenStorage(
        onWrite: (k, v) async => map[k] = v,
        onRead: (k) async => map[k],
        onDelete: (k) async => map.remove(k),
        namespace: 'tenant',
      );
      await storage.saveAccessToken('x');
      await storage.scoped('prod').saveAccessToken('y');
      expect(map['flutter_laravel_access_token:tenant'], 'x');
      expect(map['flutter_laravel_access_token:tenant:prod'], 'y');
    });

    test('InMemoryTokenStorage scopes are isolated', () async {
      final root = InMemoryTokenStorage();
      final one = root.scoped('one');
      final two = root.scoped('two');
      await root.saveAccessToken('r');
      await one.saveAccessToken('1');
      await two.saveAccessToken('2');
      await two.saveRefreshToken('2r');

      expect(await root.getAccessToken(), 'r');
      expect(await one.getAccessToken(), '1');
      expect(await two.getAccessToken(), '2');
      expect(await one.getRefreshToken(), isNull);

      await one.clear();
      expect(await one.getAccessToken(), isNull);
      expect(await two.getAccessToken(), '2');
      expect(await root.getAccessToken(), 'r');

      // Re-scoping returns a view over the same data.
      expect(await root.scoped('two').getRefreshToken(), '2r');
    });

    test('custom storages without scoping support throw UnsupportedError', () {
      final TokenStorage storage = _CustomStorage();
      expect(storage.supportsScoping, isFalse);
      expect(() => storage.scoped('x'), throwsUnsupportedError);
      final TokenStorage memory = InMemoryTokenStorage();
      expect(memory.supportsScoping, isTrue);
    });
  });
}
