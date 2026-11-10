import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class TestTask {
  final int id;
  final String title;

  TestTask({required this.id, required this.title});

  factory TestTask.fromJson(dynamic json) {
    final map = json as Map<String, dynamic>;
    return TestTask(
      id: map['id'] as int,
      title: map['title'] as String,
    );
  }
}

void main() {
  group('Channel Whispering', () {
    test('sends client-prefixed whisper events', () {
      String? sentChannel;
      String? sentEvent;
      dynamic sentData;

      final channel = Channel('private-chat.1', (ch, event, data) {
        sentChannel = ch;
        sentEvent = event;
        sentData = data;
      });

      channel.whisper('typing', {'user': 'Alice'});

      expect(sentChannel, equals('private-chat.1'));
      expect(sentEvent, equals('client-typing'));
      expect(sentData, equals({'user': 'Alice'}));
    });

    test('listens for client whisper events', () {
      final channel = Channel('presence-room');
      dynamic received;

      channel.listenForWhisper('cursor', (data) {
        received = data;
      });

      channel.dispatch('client-cursor', {'x': 100, 'y': 200});
      expect(received, equals({'x': 100, 'y': 200}));
    });
  });

  group('LaravelRealtimeStore', () {
    test('handles created, updated, and deleted stream events', () async {
      final channel = Channel('tasks');
      final store = LaravelRealtimeStore<TestTask>(
        channel: channel,
        itemParser: TestTask.fromJson,
        idOf: (item) => item.id,
        createdEvent: 'TaskCreated',
        updatedEvent: 'TaskUpdated',
        deletedEvent: 'TaskDeleted',
        initialItems: [
          TestTask(id: 1, title: 'Initial Task'),
        ],
      );

      expect(store.items.length, equals(1));

      // 1. Dispatch TaskCreated
      channel.dispatch('TaskCreated', {'id': 2, 'title': 'Second Task'});
      expect(store.items.length, equals(2));
      expect(store.items.first.title, equals('Second Task'));

      // 2. Dispatch TaskUpdated
      channel
          .dispatch('TaskUpdated', {'id': 1, 'title': 'Updated Initial Task'});
      expect(store.items.firstWhere((t) => t.id == 1).title,
          equals('Updated Initial Task'));

      // 3. Dispatch TaskDeleted
      channel.dispatch('TaskDeleted', {'id': 1});
      expect(store.items.length, equals(1));
      expect(store.items.any((t) => t.id == 1), isFalse);

      store.dispose();
    });
  });
}
