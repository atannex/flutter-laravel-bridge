import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> handshake(
        {Map<String, dynamic>? endpoints,
        Map<String, dynamic>? broadcasting,
        String? prefix}) =>
    {
      'server': {
        'name': 'Acme',
        'environment': 'production',
        'url': 'https://api.acme.com',
        'timezone': 'UTC',
        'locale': 'en',
        'time': '2026-11-09T10:00:00+00:00'
      },
      'bridge': {
        'version': '2.0.0',
        'api_version': 'v1',
        if (prefix != null) 'prefix': prefix
      },
      'app': {
        'key': 'fba_x',
        'name': 'Acme iOS',
        'status': 'active',
        'min_version': '1.2.0',
        'latest_version': '1.5.0',
        'update_url': 'https://store',
        'platforms': ['ios', 'android'],
        'settings': {'a': 1},
      },
      'features': {
        'auth': true,
        'registration': false,
        'social_auth': true,
        'two_factor': true,
        'devices': true,
        'broadcasting': true,
        'connections': true,
        'push': true,
        'beta_chat': true
      },
      'endpoints': endpoints ??
          {
            'ping': 'api/flutter/ping',
            'connections.heartbeat':
                'api/flutter/connections/{connection}/heartbeat'
          },
      'broadcasting': broadcasting,
      'connection': {'heartbeat_interval': 15, 'timeout': 45},
      'remote_config': {
        'chat': {'enabled': true},
      },
    };

void main() {
  group('ServerInfo', () {
    test('parses the full handshake', () {
      final info = ServerInfo.fromJson(handshake());
      expect(info.server.name, 'Acme');
      expect(info.server.time, DateTime.utc(2026, 11, 9, 10));
      expect(info.bridge.version, '2.0.0');
      expect(info.prefix, 'api/flutter');
      expect(info.app!.minVersion, '1.2.0');
      expect(info.app!.requiresUpdate('1.1.9'), isTrue);
      expect(info.app!.requiresUpdate('1.2.0'), isFalse);
      expect(info.app!.hasUpdate('1.4.0'), isTrue);
      expect(info.app!.platforms, ['ios', 'android']);
      expect(info.features.registration, isFalse);
      expect(info.features.twoFactor, isTrue);
      expect(info.features.has('beta_chat'), isTrue);
      expect(info.heartbeatInterval, 15);
      expect(info.timeout, 45);
      expect(info.broadcasting, isNull);
      expect(info.supportsBroadcasting, isFalse);
      expect(info.config<bool>('chat.enabled'), isTrue);
      expect(info.config<String>('missing.key', 'fallback'), 'fallback');
    });

    test('app and broadcasting may be null', () {
      final json = handshake()..['app'] = null;
      final info = ServerInfo.fromJson(json);
      expect(info.app, isNull);
    });

    test('resolves endpoints with placeholders', () {
      final info = ServerInfo.fromJson(handshake());
      expect(info.endpoint('ping'), 'api/flutter/ping');
      expect(
        info.endpoint('connections.heartbeat',
            params: {'connection': '9b1d-uuid'}),
        'api/flutter/connections/9b1d-uuid/heartbeat',
      );
      expect(
        () => info.endpoint('connections.heartbeat'),
        throwsArgumentError,
      );
    });

    test('placeholder values are URL encoded', () {
      final info = ServerInfo.fromJson(handshake());
      expect(info.endpoint('devices.unregister', params: {'device': 'a b/c'}),
          'api/flutter/devices/a%20b%2Fc');
    });

    test('falls back to built-in defaults when the server omits a key', () {
      final info = ServerInfo.fromJson(
          handshake(endpoints: {}, prefix: 'mobile/bridge'));
      expect(info.endpoint('auth.login'), 'mobile/bridge/auth/login');
      expect(info.endpoint('connections.revoke', params: {'connection': 7}),
          'mobile/bridge/connections/7');
      expect(info.endpoint('auth.2fa.send'), 'mobile/bridge/auth/2fa/send-otp');
      expect(() => info.endpoint('nope'), throwsArgumentError);
    });

    test('uses the fallback prefix when bridge.prefix is missing', () {
      final info = ServerInfo.fromJson(handshake(endpoints: {}),
          fallbackPrefix: '/custom/');
      expect(info.endpoint('ping'), 'custom/ping');
    });

    test('default constructor resolves every built-in key', () {
      const info = ServerInfo();
      for (final key in BridgeEndpoints.relativePaths.keys) {
        expect(
          info.endpoint(key, params: {'connection': 'c', 'device': 'd'}),
          startsWith('api/flutter/'),
        );
      }
    });
  });

  group('BroadcastingConfig → EchoOptions', () {
    test('https reverb on 443 is encrypted', () {
      final info = ServerInfo.fromJson(handshake(broadcasting: {
        'driver': 'reverb',
        'key': 'app-key',
        'host': 'ws.acme.com',
        'port': 443,
        'scheme': 'https',
        'cluster': null,
        'auth_endpoint': 'api/flutter/broadcasting/auth',
        'connection_channel': 'private-flutter.connections.{connection}',
        'user_channel': 'private-users.{user}',
      }));
      expect(info.supportsBroadcasting, isTrue);
      final config = info.broadcasting!;
      expect(config.connectionChannelFor('abc'),
          'private-flutter.connections.abc');
      expect(config.userChannelFor(5), 'private-users.5');

      final echo = config.toEchoOptions();
      expect(echo.appKey, 'app-key');
      expect(echo.wsHost, 'ws.acme.com');
      expect(echo.encrypted, isTrue);
      expect(echo.wssPort, 443);
      expect(echo.wsPort, 443);
      expect(echo.cluster, isNull);
      expect(echo.authEndpoint, 'api/flutter/broadcasting/auth');
      expect(echo.buildUri().toString(),
          startsWith('wss://ws.acme.com:443/app/app-key'));
      expect(EchoOptions.fromServer(config), equals(echo));
    });

    test('http reverb on 8080 is not encrypted', () {
      final config = BroadcastingConfig.fromJson({
        'driver': 'reverb',
        'key': 'k',
        'host': 'localhost',
        'port': 8080,
        'scheme': 'http',
      }, prefix: 'api/flutter');
      final echo = config.toEchoOptions();
      expect(echo.encrypted, isFalse);
      expect(echo.wsPort, 8080);
      expect(echo.authEndpoint, 'api/flutter/broadcasting/auth');
      expect(echo.buildUri().scheme, 'ws');
    });

    test('hosted pusher uses the cluster', () {
      final config = BroadcastingConfig.fromJson(
          {'driver': 'pusher', 'key': 'k', 'scheme': 'https', 'cluster': 'eu'});
      final echo = config.toEchoOptions();
      expect(echo.cluster, 'eu');
      expect(echo.buildUri().host, 'ws-eu.pusher.com');
    });

    test('EchoOptions json roundtrip', () {
      const options = EchoOptions(
          appKey: 'k',
          wsHost: 'h',
          wsPort: 6001,
          encrypted: true,
          cluster: 'mt1');
      expect(EchoOptions.fromJson(options.toJson()), equals(options));
    });
  });

  group('LaravelOptions', () {
    test('derives legacy prefixes from prefix', () {
      const options = LaravelOptions(baseUrl: 'http://x', prefix: 'mobile');
      expect(options.authPrefix, 'mobile/auth');
      expect(options.devicePrefix, 'mobile/devices');
      expect(options.broadcastAuthPath, 'mobile/broadcasting/auth');
      expect(
          options.defaultEndpoint('connections.heartbeat',
              params: {'connection': 'c'}),
          'mobile/connections/c/heartbeat');
    });

    test('explicit legacy prefixes still win', () {
      const options = LaravelOptions(
          baseUrl: 'http://x',
          authPrefix: 'api/auth',
          devicePrefix: 'api/devices');
      expect(options.authPrefix, 'api/auth');
      expect(options.defaultEndpoint('auth.login'), 'api/auth/login');
      expect(
          options
              .defaultEndpoint('devices.unregister', params: {'device': 'd1'}),
          'api/devices/d1');
      expect(options.copyWith(prefix: 'other').authPrefix, 'api/auth');
      expect(options.copyWith(prefix: 'other').broadcastAuthPath,
          'other/broadcasting/auth');
    });
  });
}
