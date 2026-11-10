# Real-Time WebSockets & Laravel Reverb

This guide explains how to build real-time reactive experiences in Flutter using Laravel Reverb or Pusher via `flutter_laravel_bridge`.

---

## 1. Overview

Laravel Reverb is a high-speed, first-party WebSocket server built for Laravel. The `flutter_laravel_bridge` includes a native Dart implementation of the Pusher/Reverb WebSocket protocol, eliminating the need for JavaScript bridge packages or complex external SDKs.

---

## 2. Connection Setup

To connect to Reverb, provide `EchoOptions` in `Laravel.initialize()`:

```dart
await Laravel.initialize<User>(
  options: const LaravelOptions(
    baseUrl: 'http://10.0.2.2:8000',
  ),
  echoOptions: const EchoOptions(
    appKey: 'my_reverb_app_key',
    wsHost: '10.0.2.2',
    wsPort: 8080,
    encrypted: false, // Set to true in production with SSL
  ),
  userParser: (json) => User.fromJson(json),
);

// Connect WebSocket
await Laravel.echo.connect();
```

---

## 3. Channel Types

### 3.1 Public Channel
Public channels can be subscribed to by any client without authentication:

```dart
final channel = Laravel.echo.channel('news');

channel.listen('HeadlinePublished', (data) {
  print('New headline: ${data['title']}');
});
```

### 3.2 Private Channel
Private channels require the client to be authenticated. The bridge automatically sends a POST request with the user's Sanctum Bearer token to `/api/flutter/broadcasting/auth`:

```dart
final userChannel = Laravel.echo.private('users.${currentUser.id}');

userChannel.listen('InvoiceGenerated', (data) {
  print('Your invoice #${data['invoice_id']} is ready!');
});
```

### 3.3 Presence Channel
Presence channels allow users to see who else is in the room:

```dart
final chatRoom = Laravel.echo.join('chat.room.42');

chatRoom
  .here((members) {
    print('Currently active participants: $members');
  })
  .joining((member) {
    print('${member['name']} joined the room');
  })
  .leaving((member) {
    print('${member['name']} left the room');
  })
  .listen('MessageSent', (data) {
    print('New message from ${data['sender']}: ${data['text']}');
  });
```

---

## 4. UI Integration with `LaravelRealtimeBuilder`

Bind directly to events in your Flutter widget tree:

```dart
class LiveFeedWidget extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LaravelRealtimeBuilder(
      channel: Laravel.echo.channel('market-ticker'),
      event: 'PriceUpdated',
      initialData: {'price': '0.00'},
      builder: (context, data) {
        return Text(
          'Live Price: \$${data['price']}',
          style: Theme.of(context).textTheme.headlineMedium,
        );
      },
    );
  }
}
```
