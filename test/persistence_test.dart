import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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

MutationRecord _record(String path, {dynamic data}) => MutationRecord(
      id: BridgeIds.uuid(),
      method: 'POST',
      path: path,
      data: data ?? {'path': path},
    );

LaravelException _status(int code) =>
    LaravelException(message: 'HTTP $code', statusCode: code);

void main() {
  group('BridgeKeyValueStore adapters', () {
    test('DelegateKeyValueStore and token/connection adapters share one store',
        () async {
      final backing = InMemoryKeyValueStore();
      final store = DelegateKeyValueStore(
        read: backing.read,
        write: backing.write,
        delete: backing.delete,
      );

      final tokens = DelegateTokenStorage.fromStore(store);
      await tokens.saveAccessToken('a1');
      await tokens.scoped('beta').saveAccessToken('b1');
      expect(await tokens.getAccessToken(), 'a1');
      expect(await tokens.scoped('beta').getAccessToken(), 'b1');

      const viaCallbacks = DelegateTokenStorage.fromKeyValue(
        read: _staticRead,
        write: _staticWrite,
        delete: _staticDelete,
      );
      await viaCallbacks.saveRefreshToken('r1');
      expect(_static[DelegateTokenStorage.refreshTokenKey], 'r1');

      final connections = DelegateConnectionStore.fromStore(store);
      await connections.saveActiveId('beta');
      expect(await connections.loadActiveId(), 'beta');
      expect(
          backing.values.keys, contains(DelegateConnectionStore.activeIdKey));
    });
  });

  group('OfflineQueue persistence', () {
    test('persists every change and restores records in FIFO order', () async {
      final store = InMemoryKeyValueStore();
      final queue = OfflineQueue(store: store, storageKey: 'q:alpha');
      queue
        ..enqueue(_record('api/a'))
        ..enqueue(_record('api/b'))
        ..enqueue(_record('api/c'));
      await queue.whenPersisted();
      expect(queue.pending.every((r) => r.persisted), isTrue);
      expect(jsonDecode(store.values['q:alpha']!), hasLength(3));

      final restored = OfflineQueue(store: store, storageKey: 'q:alpha');
      // Enqueued before restore: must land after the saved (older) records.
      restored.enqueue(_record('api/d'));
      await restored.restore();
      await restored.whenPersisted();
      expect(restored.pending.map((r) => r.path),
          ['api/a', 'api/b', 'api/c', 'api/d']);
      expect(jsonDecode(store.values['q:alpha']!), hasLength(4));

      final executed = <String>[];
      final count = await restored.flush((r) async {
        executed.add(r.path);
        return true;
      });
      expect(count, 4);
      expect(executed, ['api/a', 'api/b', 'api/c', 'api/d']);
      await restored.whenPersisted();
      expect(jsonDecode(store.values['q:alpha']!), isEmpty);

      restored.enqueue(_record('api/e'));
      restored.clear();
      await restored.whenPersisted();
      expect(jsonDecode(store.values['q:alpha']!), isEmpty);
    });

    test('tolerates corrupt data', () async {
      final store = InMemoryKeyValueStore({'q': '{not json'});
      final queue = OfflineQueue(store: store, storageKey: 'q');
      await queue.restore();
      expect(queue.length, 0);
      await queue.whenPersisted();
      expect(store.values['q'], '[]');

      final good = _record('api/ok').toJson();
      await store.write(
          'q',
          jsonEncode([
            good,
            42,
            {'id': 1},
            null
          ]));
      final partial = OfflineQueue(store: store, storageKey: 'q');
      await partial.restore();
      expect(partial.pending.map((r) => r.path), ['api/ok']);
      await partial.whenPersisted();
      expect(jsonDecode(store.values['q']!), hasLength(1));
    });

    test('non-JSON payloads stay in memory and are not persisted', () async {
      final store = InMemoryKeyValueStore();
      final queue = OfflineQueue(store: store, storageKey: 'q');
      final form = _record('api/upload', data: FormData.fromMap({'a': 1}));
      queue
        ..enqueue(_record('api/json'))
        ..enqueue(form);
      await queue.whenPersisted();

      expect(queue.length, 2);
      expect(form.persisted, isFalse);
      expect(queue.pending.first.persisted, isTrue);
      final saved = jsonDecode(store.values['q']!) as List;
      expect(saved.map((e) => (e as Map)['path']), ['api/json']);
    });

    test('drops records after maxRetries and emits them on failures', () async {
      final queue = OfflineQueue(maxRetries: 2);
      final failures = <OfflineMutationFailure>[];
      queue.failures.listen(failures.add);
      queue
        ..enqueue(_record('api/a'))
        ..enqueue(_record('api/b'));

      final calls = <String>[];
      Future<bool> failing(MutationRecord r) async {
        calls.add(r.path);
        throw _status(500);
      }

      expect(await queue.flush(failing), 0);
      // Stopped at the first failure: FIFO is preserved.
      expect(calls, ['api/a']);
      expect(queue.pending.first.retryCount, 1);

      await queue.flush(failing);
      await pumpEventQueue();
      expect(queue.pending.map((r) => r.path), ['api/b']);
      expect(failures.single.record.path, 'api/a');
      expect(failures.single.reason,
          OfflineMutationFailureReason.maxRetriesExceeded);
      expect(failures.single.statusCode, 500);
    });

    test('4xx (except 408/429) is a permanent failure; network keeps record',
        () async {
      final queue = OfflineQueue();
      final failures = <OfflineMutationFailure>[];
      queue.failures.listen(failures.add);
      queue
        ..enqueue(_record('api/invalid'))
        ..enqueue(_record('api/ok'))
        ..enqueue(_record('api/throttled'))
        ..enqueue(_record('api/later'));

      final count = await queue.flush((r) async {
        switch (r.path) {
          case 'api/invalid':
            throw _status(422);
          case 'api/throttled':
            throw _status(429);
          default:
            return true;
        }
      });
      await pumpEventQueue();
      expect(count, 1);
      expect(failures.single.record.path, 'api/invalid');
      expect(failures.single.reason, OfflineMutationFailureReason.rejected);
      expect(queue.pending.map((r) => r.path), ['api/throttled', 'api/later']);

      await queue.flush(
          (r) async => throw const LaravelNetworkException(message: 'offline'));
      expect(queue.length, 2);
      // Being offline, throttled or in maintenance never burns retries.
      expect(queue.pending.first.retryCount, 0);

      expect(OfflineQueue.isPermanentFailure(_status(404)), isTrue);
      expect(OfflineQueue.isPermanentFailure(_status(408)), isFalse);
      expect(OfflineQueue.isPermanentFailure(_status(500)), isFalse);
    });

    test('a device that stays offline never loses queued work', () async {
      final queue = OfflineQueue(maxRetries: 2)..enqueue(_record('api/a'));
      final failures = <OfflineMutationFailure>[];
      queue.failures.listen(failures.add);

      for (final error in <Object>[
        const LaravelNetworkException(message: 'offline'),
        _status(429),
        _status(503),
        _status(408),
        const LaravelNetworkException(message: 'still offline'),
      ]) {
        await queue.flush((r) async => throw error);
      }
      await pumpEventQueue();

      expect(failures, isEmpty);
      expect(queue.pending.single.retryCount, 0);
      expect(OfflineQueue.isConnectivityFailure(_status(500)), isFalse);
    });

    test('does not flush concurrently', () async {
      final queue = OfflineQueue()
        ..enqueue(_record('api/a'))
        ..enqueue(_record('api/b'));
      final gate = Completer<void>();
      var calls = 0;
      Future<bool> executor(MutationRecord r) async {
        calls++;
        await gate.future;
        return true;
      }

      final first = queue.flush(executor);
      final second = queue.flush(executor);
      expect(queue.isFlushing, isTrue);
      await pumpEventQueue();
      expect(calls, 1);
      gate.complete();
      expect(await first, 2);
      expect(await second, 2);
      expect(calls, 2);
      expect(queue.isFlushing, isFalse);
    });
  });

  group('CacheManager persistence', () {
    test('persists, restores and skips expired entries', () async {
      var now = DateTime.utc(2026, 1, 1, 12);
      final store = InMemoryKeyValueStore();
      final cache =
          CacheManager(store: store, storageKey: 'c:alpha', clock: () => now);
      cache
        ..put('api/a:{}', {'v': 1}, const Duration(minutes: 1))
        ..put('api/b:{}', {'v': 2}, const Duration(hours: 1));
      await cache.whenPersisted();

      now = now.add(const Duration(minutes: 5));
      final restored =
          CacheManager(store: store, storageKey: 'c:alpha', clock: () => now);
      await restored.restore();
      expect(restored.get('api/a:{}'), isNull);
      expect(restored.get('api/b:{}'), {'v': 2});
      await restored.whenPersisted();
      final saved = jsonDecode(store.values['c:alpha']!) as Map;
      expect(saved.keys, ['api/b:{}']);

      restored.invalidate('api/b:{}');
      await restored.whenPersisted();
      expect(jsonDecode(store.values['c:alpha']!), isEmpty);
    });

    test('evicts least recently used entries above maxEntries', () async {
      final store = InMemoryKeyValueStore();
      final cache = CacheManager(store: store, storageKey: 'c', maxEntries: 2);
      cache
        ..put('a', 1, const Duration(hours: 1))
        ..put('b', 2, const Duration(hours: 1));
      expect(cache.get('a'), 1); // a is now the most recent
      cache.put('c', 3, const Duration(hours: 1));
      expect(cache.get('b'), isNull);
      expect(cache.keys, ['a', 'c']);
      await cache.whenPersisted();
      expect((jsonDecode(store.values['c']!) as Map).keys, ['a', 'c']);
    });

    test('invalidatePrefix and clear write through; corrupt data is ignored',
        () async {
      final store = InMemoryKeyValueStore({'c': 'garbage'});
      final cache = CacheManager(store: store, storageKey: 'c');
      await cache.restore();
      cache
        ..put('api/posts:{}', 1, const Duration(hours: 1))
        ..put('api/posts/1:{}', 2, const Duration(hours: 1))
        ..put('api/users:{}', 3, const Duration(hours: 1));
      expect(cache.invalidatePrefix('api/posts'), 2);
      expect(cache.keys, ['api/users:{}']);
      await cache.whenPersisted();
      expect((jsonDecode(store.values['c']!) as Map).keys, ['api/users:{}']);

      cache.clear();
      await cache.whenPersisted();
      expect(jsonDecode(store.values['c']!), isEmpty);
    });

    test('LaravelClient restores the persisted cache before reading', () async {
      final store = InMemoryKeyValueStore();
      final seed = CacheManager(store: store, storageKey: 'c');
      seed.put('api/posts:{}', {'success': true, 'data': 'cached'},
          const Duration(hours: 1));
      await seed.whenPersisted();

      final client = LaravelClient(
        options: const LaravelOptions(
            baseUrl: 'http://api.test', enableLogging: false),
        cacheManager: CacheManager(store: store, storageKey: 'c'),
      );
      final response = await client.get<dynamic>('api/posts',
          cachePolicy: CachePolicy.cacheOnly);
      expect(response.data, 'cached');
      client.close();
    });
  });

  group('Laravel.initialize(storage:)', () {
    late Map<String, FakeBridgeServer> servers;

    setUp(() {
      servers = {
        'alpha.test': FakeBridgeServer(name: 'Alpha'),
        'beta.test': FakeBridgeServer(name: 'Beta'),
      };
    });

    tearDown(Laravel.reset);

    Future<void> init(BridgeKeyValueStore storage) => Laravel.initialize<User>(
          options: const LaravelOptions(
              baseUrl: 'https://alpha.test',
              deviceId: 'd1',
              platform: 'ios',
              enableLogging: false),
          userParser: User.fromJson,
          storage: storage,
          httpClientAdapterFactory: (p) => servers[Uri.parse(p.baseUrl).host]!,
          enableTimers: false,
        );

    test(
        'keeps tokens, profiles, queues and caches per profile across restarts',
        () async {
      final storage = InMemoryKeyValueStore();
      await init(storage);
      await Laravel.auth<User>()
          .login(email: 'a@example.com', password: 'secret');
      Laravel.client.cacheManager.put(
          'api/posts:{}',
          {
            'success': true,
            'data': {'from': 'alpha'}
          },
          const Duration(hours: 1));
      await Laravel.connections.add(const LaravelConnection(
          id: 'beta', name: 'Beta', baseUrl: 'https://beta.test'));

      await Laravel.switchConnection('beta');
      expect(Laravel.auth<User>().isAuthenticated, isFalse);
      expect(Laravel.client.cacheManager.get('api/posts:{}'), isNull);
      servers['beta.test']!.offline = true;
      await expectLater(
        Laravel.client
            .post<dynamic>('api/notes', data: {'n': 1}, queueIfOffline: true),
        throwsA(isA<LaravelNetworkException>()),
      );
      await Laravel.client.offlineQueue.whenPersisted();

      expect(
          storage.values.keys,
          containsAll(<String>[
            DelegateTokenStorage.accessTokenKey, // default profile: unscoped
            DelegateConnectionStore.connectionsKey,
            OfflineQueue.storageKeyFor('beta'),
            CacheManager.storageKeyFor('default'),
          ]));
      expect(storage.values.keys,
          isNot(contains('${DelegateTokenStorage.accessTokenKey}:beta')));

      // "Restart" the app with the same store.
      await Laravel.reset();
      servers['beta.test']!.offline = false;
      servers['beta.test']!.routes['POST api/notes'] =
          (req, server) => server.json(201, {'success': true, 'data': null});
      await init(storage);

      // Beta was active: its queue was restored and replayed on connect.
      expect(Laravel.connections.active!.id, 'beta');
      await pumpEventQueue();
      expect(servers['beta.test']!.requestsTo('api/notes', method: 'POST'),
          hasLength(2));
      expect(Laravel.client.offlineQueue.length, 0);
      expect(servers['alpha.test']!.requestsTo('api/notes'), isEmpty);

      await Laravel.switchConnection('default');
      expect(Laravel.auth<User>().currentUser!.email, 'a@example.com');
      final cached = await Laravel.client
          .get<dynamic>('api/posts', cachePolicy: CachePolicy.cacheOnly);
      expect((cached.data as Map)['from'], 'alpha');
      expect(Laravel.client.offlineQueue.length, 0);
    });

    test('specific stores override the shared storage', () async {
      final storage = InMemoryKeyValueStore();
      final queueStore = InMemoryKeyValueStore();
      final tokens = InMemoryTokenStorage();
      await Laravel.initialize<User>(
        options: const LaravelOptions(
            baseUrl: 'https://alpha.test',
            deviceId: 'd1',
            platform: 'ios',
            enableLogging: false),
        userParser: User.fromJson,
        storage: storage,
        offlineQueueStore: queueStore,
        tokenStorage: tokens,
        httpClientAdapterFactory: (p) => servers[Uri.parse(p.baseUrl).host]!,
        enableTimers: false,
      );
      await Laravel.auth<User>()
          .login(email: 'a@example.com', password: 'secret');
      Laravel.client.offlineQueue.enqueue(_record('api/x'));
      await Laravel.client.offlineQueue.whenPersisted();

      expect(await tokens.getAccessToken(), isNotNull);
      expect(storage.values.keys,
          isNot(contains(DelegateTokenStorage.accessTokenKey)));
      expect(queueStore.values.keys,
          contains(OfflineQueue.storageKeyFor('default')));
      expect(storage.values.keys,
          contains(DelegateConnectionStore.connectionsKey));
    });
  });

  test('in-memory token fallback warns once and does not throw', () async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      LaravelConnectionManager.resetInMemoryTokenWarning();
      final a = LaravelConnectionManager(
          options: const LaravelOptions(baseUrl: 'https://a.test'));
      final b = LaravelConnectionManager(
          options: const LaravelOptions(baseUrl: 'https://b.test'));
      final c = LaravelConnectionManager(
        options: const LaravelOptions(baseUrl: 'https://c.test'),
        storage: InMemoryKeyValueStore(),
      );
      final warnings = logs.where((l) => l.contains('InMemoryTokenStorage'));
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('FlutterSecureStorage'));
      await a.dispose();
      await b.dispose();
      await c.dispose();
    } finally {
      debugPrint = original;
    }
  });
}

final Map<String, String> _static = {};
Future<String?> _staticRead(String key) async => _static[key];
Future<void> _staticWrite(String key, String value) async =>
    _static[key] = value;
Future<void> _staticDelete(String key) async => _static.remove(key);
