import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LaravelConnection', () {
    const profile = LaravelConnection(
      id: 'prod',
      name: 'Production',
      baseUrl: 'https://api.acme.com/',
      appKey: 'fba_123',
      headers: {'X-Tenant': 'acme'},
      echoOptions:
          EchoOptions(appKey: 'k', wsHost: 'ws.acme.com', encrypted: true),
      metadata: {
        'color': 'blue',
        'nested': {'a': 1}
      },
    );

    test('is const-constructible with defaults', () {
      const minimal =
          LaravelConnection(id: 'a', name: 'A', baseUrl: 'http://a.test');
      expect(minimal.prefix, 'api/flutter');
      expect(minimal.autoConfigureEcho, isTrue);
      expect(minimal.headers, isEmpty);
      expect(minimal.appKey, isNull);
    });

    test('json roundtrip preserves every field', () {
      final withDate =
          profile.copyWith(lastConnectedAt: DateTime.utc(2026, 11, 9, 10, 30));
      final restored = LaravelConnection.fromJson(withDate.toJson());
      expect(restored, equals(withDate));
      expect(restored.hashCode, equals(withDate.hashCode));
      expect(restored.echoOptions, equals(profile.echoOptions));
      expect(restored.lastConnectedAt, DateTime.utc(2026, 11, 9, 10, 30));
    });

    test('create generates a v4 uuid id', () {
      final a = LaravelConnection.create(name: 'A', baseUrl: 'http://a.test');
      final b = LaravelConnection.create(name: 'A', baseUrl: 'http://a.test');
      expect(
          a.id,
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(a.id, isNot(b.id));
    });

    test('copyWith and clear flags', () {
      final copy = profile.copyWith(
          name: 'Prod 2', clearAppKey: true, clearEchoOptions: true);
      expect(copy.name, 'Prod 2');
      expect(copy.appKey, isNull);
      expect(copy.echoOptions, isNull);
      expect(copy.baseUrl, profile.baseUrl);
      expect(copy == profile, isFalse);
    });

    test('normalisation helpers and transport diff', () {
      expect(profile.normalizedBaseUrl, 'https://api.acme.com');
      expect(profile.host, 'api.acme.com');
      expect(
          profile.copyWith(name: 'x').differsTransportFrom(profile), isFalse);
      expect(profile.copyWith(prefix: 'api/v2').differsTransportFrom(profile),
          isTrue);
      expect(
          profile.copyWith(
              headers: {'X-Tenant': 'other'}).differsTransportFrom(profile),
          isTrue);
    });

    test('validateBaseUrl', () {
      expect(LaravelConnection.validateBaseUrl(''), isNotNull);
      expect(LaravelConnection.validateBaseUrl('ftp://x.com'), isNotNull);
      expect(LaravelConnection.validateBaseUrl('not a url'), isNotNull);
      expect(LaravelConnection.validateBaseUrl('https://'), isNotNull);
      expect(LaravelConnection.validateBaseUrl('http://10.0.2.2:8000'), isNull);
    });
  });

  group('ConnectionSession & BridgeCommand', () {
    test('parses the §4.5 connection object', () {
      final session = ConnectionSession.fromJson({
        'id': '9b1d',
        'app_key': 'fba_1',
        'user_id': 1,
        'device_id': 'abc',
        'platform': 'android',
        'device_name': 'Pixel 9',
        'app_version': '1.4.2',
        'os_version': '15',
        'ip_address': '10.0.0.5',
        'user_agent': 'ua',
        'status': 'active',
        'is_online': true,
        'is_current': true,
        'connected_at': '2026-11-09T10:00:00+00:00',
        'last_seen_at': '2026-11-09T10:05:00+00:00',
        'disconnected_at': null,
        'revoked_at': null,
        'metadata': {'k': 'v'},
      });
      expect(session.id, '9b1d');
      expect(session.status, ConnectionSessionStatus.active);
      expect(session.isOnline, isTrue);
      expect(session.isCurrent, isTrue);
      expect(session.lastSeenAt, DateTime.utc(2026, 11, 9, 10, 5));
      expect(ConnectionSession.fromJson(session.toJson()).toJson(),
          session.toJson());
      expect(ConnectionSessionStatus.parse('weird'),
          ConnectionSessionStatus.unknown);
    });

    test('BridgeCommand accepts numeric ids and exposes reason', () {
      final command = BridgeCommand.fromJson({
        'id': 12,
        'type': 'revoked',
        'payload': {'reason': 'admin'},
        'created_at': '2026-11-09T10:00:00Z',
      });
      expect(command.id, '12');
      expect(command.reason, 'admin');
      expect(command.isBuiltIn, isTrue);
      expect(BridgeCommand.fromJson({'id': '1', 'type': 'message'}).isBuiltIn,
          isFalse);
    });

    test('LaravelConnectionState copyWith clears fields', () {
      const state = LaravelConnectionState(
          status: ConnectionStatus.offline, error: 'x', reconnectAttempt: 2);
      final next = state.copyWith(
          status: ConnectionStatus.connected,
          clearError: true,
          reconnectAttempt: 0);
      expect(next.status, ConnectionStatus.connected);
      expect(next.error, isNull);
      expect(next.reconnectAttempt, 0);
      expect(ConnectionStatus.offline.isProblem, isTrue);
      expect(ConnectionStatus.connected.isUsable, isTrue);
    });
  });

  test('compareBridgeVersions', () {
    expect(compareBridgeVersions('1.2.10', '1.2.9'), greaterThan(0));
    expect(compareBridgeVersions('1.2', '1.2.0'), 0);
    expect(compareBridgeVersions('1.0.0-beta', '1.0.1'), lessThan(0));
  });
}
