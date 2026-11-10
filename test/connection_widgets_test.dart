import 'package:flutter/material.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_bridge_server.dart';

const _alpha = LaravelConnection(
    id: 'alpha', name: 'Alpha', baseUrl: 'https://alpha.test');
const _beta =
    LaravelConnection(id: 'beta', name: 'Beta', baseUrl: 'https://beta.test');

Future<(LaravelConnectionManager, Map<String, FakeBridgeServer>)> _manager(
    WidgetTester tester) async {
  final servers = {
    'alpha.test': FakeBridgeServer(name: 'AlphaServer'),
    'beta.test': FakeBridgeServer(name: 'BetaServer'),
  };
  final manager = LaravelConnectionManager(
    options: const LaravelOptions(
        baseUrl: 'https://alpha.test',
        deviceId: 'dev',
        platform: 'android',
        appVersion: '1.0.0',
        enableLogging: false),
    store: InMemoryConnectionStore(connections: const [_alpha, _beta]),
    httpClientAdapterFactory: (p) => servers[Uri.parse(p.baseUrl).host]!,
    enableTimers: false,
  );
  await tester.runAsync(() async {
    await manager.load();
    await manager.connect();
  });
  return (manager, servers);
}

/// Drive fake-async network work (the fake adapter yields through zero-delay timers).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

Widget _app(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: child,
    );

void main() {
  testWidgets(
      'LaravelConnectionManagerView lists profiles with status and active marker',
      (tester) async {
    final (manager, _) = await _manager(tester);
    await tester
        .pumpWidget(_app(LaravelConnectionManagerView(manager: manager)));
    await tester.pump();

    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Inactive'), findsOneWidget);
    expect(find.byIcon(Icons.devices_other_outlined), findsOneWidget);

    // Add dialog validates the base URL.
    await tester.tap(find.text('Add connection'));
    await tester.pumpAndSettle();
    expect(find.text('Test connection'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('laravel-connection-url')), 'not a url');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a full http:// or https:// URL'), findsOneWidget);

    await tester.runAsync(() => manager.dispose());
  });

  testWidgets('switching from the list connects the tapped profile',
      (tester) async {
    final (manager, _) = await _manager(tester);
    await tester
        .pumpWidget(_app(LaravelConnectionManagerView(manager: manager)));
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.text('Beta'));
      // Let the switch (network on the fake adapter) complete.
      for (var i = 0;
          i < 50 &&
              (manager.active?.id != 'beta' ||
                  manager.state.status != ConnectionStatus.connected);
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(manager.active!.id, 'beta');
    expect(manager.state.status, ConnectionStatus.connected);
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() => manager.dispose());
  });

  testWidgets('delete asks for confirmation', (tester) async {
    final (manager, _) = await _manager(tester);
    await tester
        .pumpWidget(_app(LaravelConnectionManagerView(manager: manager)));
    await tester.pump();

    await tester.tap(find.byTooltip('More').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Beta?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(manager.connections, hasLength(2));
    await tester.runAsync(() => manager.dispose());
  });

  testWidgets(
      'LaravelSessionsView lists sessions with "This device" and revokes',
      (tester) async {
    final (manager, servers) = await _manager(tester);
    final alpha = servers['alpha.test']!;
    await tester.runAsync(
        () => manager.auth!.login(email: 'a@example.com', password: 'secret'));
    final other = alpha.addForeignSession(userId: 1);

    await tester.pumpWidget(_app(LaravelSessionsView(manager: manager)));
    await _settle(tester);

    expect(find.text('Active sessions'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('iPhone 17'), findsOneWidget);
    expect(find.byIcon(Icons.phone_iphone), findsOneWidget);
    expect(find.text('Sign out all other devices'), findsOneWidget);

    await tester.tap(find.byTooltip('Sign out device'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out iPhone 17?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await _settle(tester);
    expect(find.text('iPhone 17 signed out'), findsOneWidget);
    expect(alpha.sessions[other.id]!.status, 'revoked');
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() => manager.dispose());
  });

  testWidgets('LaravelConnectionBanner shows offline and update banners',
      (tester) async {
    final (manager, servers) = await _manager(tester);
    LaravelUpgradeRequiredException? updated;
    await tester.pumpWidget(_app(LaravelConnectionBanner(
      manager: manager,
      onUpdate: (e) => updated = e,
      child: const Scaffold(body: Text('Home')),
    )));
    await tester.pump();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('You are offline'), findsNothing);

    servers['alpha.test']!.offline = true;
    await tester.runAsync(() => manager.heartbeat());
    await tester.pumpAndSettle();
    expect(find.text('You are offline'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    servers['alpha.test']!
      ..offline = false
      ..minVersion = '2.0.0';
    await tester.runAsync(() => manager.connect());
    await tester.pumpAndSettle();
    expect(find.text('Update required'), findsOneWidget);
    await tester.tap(find.text('Update'));
    expect(updated!.minVersion, '2.0.0');

    servers['alpha.test']!.minVersion = null;
    await tester.runAsync(() => manager.connect());
    await tester.pumpAndSettle();
    expect(find.text('Update required'), findsNothing);
    await tester.runAsync(() => manager.dispose());
  });

  testWidgets('LaravelConnectionIndicator and builder follow the manager',
      (tester) async {
    final (manager, _) = await _manager(tester);
    await tester.pumpWidget(_app(Scaffold(
      body: Column(children: [
        LaravelConnectionIndicator(manager: manager),
        LaravelConnectionBuilder(
            manager: manager,
            builder: (context, state) => Text('status:${state.status.name}')),
      ]),
    )));
    await tester.pump();
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('status:connected'), findsOneWidget);

    await tester.runAsync(() => manager.disconnect());
    await tester.pump();
    expect(find.text('status:idle'), findsOneWidget);
    await tester.runAsync(() => manager.dispose());
  });
}
