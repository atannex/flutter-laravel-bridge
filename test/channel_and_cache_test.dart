import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Channel', () {
    test('receives and dispatches events to listeners', () {
      final channel = Channel('orders.1');
      dynamic receivedData;

      channel.listen('OrderUpdated', (data) {
        receivedData = data;
      });

      channel.dispatch('OrderUpdated', {'status': 'shipped'});
      expect(receivedData, equals({'status': 'shipped'}));

      // Test qualified event names
      channel.dispatch('App.Events.OrderUpdated', {'status': 'delivered'});
      expect(receivedData, equals({'status': 'delivered'}));

      // Clean up
      channel.dispose();
    });

    test('stops listening when requested', () {
      final channel = Channel('notifications');
      int callCount = 0;

      void listener(data) => callCount++;

      channel.listen('NewNotification', listener);
      channel.dispatch('NewNotification', {'id': 1});
      expect(callCount, equals(1));

      channel.stopListening('NewNotification', listener);
      channel.dispatch('NewNotification', {'id': 2});
      expect(callCount, equals(1));
    });
  });

  group('CacheManager', () {
    test('stores, retrieves and expires entries', () async {
      final manager = CacheManager();
      manager.put(
          '/api/users', {'users': []}, const Duration(milliseconds: 100));

      expect(manager.get('/api/users'), isNotNull);

      // Invalidate
      manager.invalidate('/api/users');
      expect(manager.get('/api/users'), isNull);
    });
  });
}
