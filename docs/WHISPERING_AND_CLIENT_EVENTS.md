# Client Whispering & Ephemeral Events

Whispering (client events) allows mobile clients to transmit lightweight, ephemeral events directly to other connected clients on a private or presence channel without triggering an HTTP request or loading the Laravel database.

Common use cases:
- Real-time typing indicators ("*Alice is typing...*")
- Live user locations on a map
- Collaborative whiteboards and live form focus indicators

---

## 1. Sending Whispers from Flutter

```dart
final channel = Laravel.echo.private('chat.room.42');

// Send whisper: automatically sends as 'client-typing'
channel.whisper('typing', {
  'user_id': currentUser.id,
  'user_name': currentUser.name,
  'is_typing': true,
});
```

---

## 2. Listening to Whispers in Flutter

```dart
channel.listenForWhisper('typing', (data) {
  print('${data['user_name']} is typing a message...');
});
```

---

## 3. UI Integration with `LaravelWhisperBuilder`

The bridge includes a dedicated widget that automatically resets state after inactivity (e.g. 3 seconds after typing stops):

```dart
LaravelWhisperBuilder(
  channel: Laravel.echo.private('chat.room.42'),
  event: 'typing',
  autoResetDuration: const Duration(seconds: 3),
  builder: (context, data, isActive) {
    if (!isActive) return const SizedBox.shrink();
    return Text(
      '${data['user_name']} is typing...',
      style: const TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
    );
  },
);
```

---

## 4. Laravel Reverb / Pusher Requirements

In your Laravel Reverb / Pusher app configuration, ensure **Client Events** are enabled so WebSocket clients are permitted to transmit client frames.
